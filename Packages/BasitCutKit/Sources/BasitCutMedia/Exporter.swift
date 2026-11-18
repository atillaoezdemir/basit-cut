import AVFoundation
import VideoToolbox
import BasitCutCore

public enum ExportError: LocalizedError {
    case cannotCreateSession
    case readerFailed(Error?)
    case writerFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateSession:
            "The export couldn’t be started."
        case .readerFailed(let error):
            "Reading the source videos failed." + Self.detail(error)
        case .writerFailed(let error):
            "Writing the exported file failed." + Self.detail(error)
        }
    }

    private static func detail(_ error: Error?) -> String {
        error.map { " (\($0.localizedDescription))" } ?? ""
    }
}

/// Exports a project to a QuickTime movie, following an `ExportPlan`.
///
/// - Passthrough copies the compressed samples with `AVAssetExportSession`.
/// - Re-encoding reads the same composition as the preview (video composition
///   and audio mix included) with `AVAssetReader` and encodes it with
///   `AVAssetWriter`, which allows exact bitrate settings.
///
/// Metadata (date, location, camera) comes from the first clip. Cancelling
/// the calling task stops the export and deletes the partial file.
public enum Exporter {
    public static func export(
        project: Project,
        assets: [MediaSource.ID: AVAsset],
        mode: ExportMode,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let plan = try ExportPlan.make(for: project, mode: mode)
        guard let reference = project.referenceSource, let referenceAsset = assets[reference.id] else {
            throw CompositionError.emptyTimeline
        }
        let metadata = await ArchiveMetadata.items(from: referenceAsset, fallbackCreationDate: reference.creationDate)

        try? FileManager.default.removeItem(at: url)
        do {
            switch plan {
            case .passthrough:
                let composition = try await CompositionBuilder.buildPassthrough(project: project, assets: assets)
                try await exportPassthrough(composition, metadata: metadata, to: url, progress: progress)
            case .reencode(let settings):
                let built = try await CompositionBuilder.build(project: project, assets: assets)
                let job = try await ReencodeJob(built: built, settings: settings, metadata: metadata, url: url)
                try await job.run(progress: progress)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        // Finder shows file dates; give the file the recording date too.
        if let date = reference.creationDate {
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        progress(1)
    }

    // MARK: Passthrough

    private static func exportPassthrough(
        _ composition: AVComposition,
        metadata: [AVMetadataItem],
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotCreateSession
        }
        session.metadata = metadata
        // The session is only observed from the monitor task.
        let observed = UncheckedBox(session)
        let monitor = Task {
            for await state in observed.value.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        // Cancelling the calling task cancels the export.
        try await session.export(to: url, as: .mov)
    }
}

/// Hands a non-Sendable object to another task that only reads from it.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Re-encode

/// Reader → writer pipeline for one re-encoded export.
///
/// AVFoundation's reader and writer aren't Sendable; all their use after setup
/// happens on `queue`, hence `@unchecked Sendable`.
private final class ReencodeJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let pumps: [Pump]
    private let duration: CMTime
    private let queue = DispatchQueue(label: "io.github.atillaoezdemir.basitcut.export")

    init(built: BuiltComposition, settings: ExportSettings, metadata: [AVMetadataItem], url: URL) async throws {
        let composition = built.composition
        reader = try AVAssetReader(asset: composition)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        duration = try await composition.load(.duration)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)

        // Video: the preview's video composition, encoded with the plan's settings.
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(settings))
        videoInput.expectsMediaDataInRealTime = false

        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw ExportError.cannotCreateSession }
        reader.add(videoOutput)
        writer.add(videoInput)
        var pumps = [Pump(output: videoOutput, input: videoInput, reportsProgress: true)]

        // Audio: the composition's tracks mixed to stereo AAC.
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            audioOutput.audioMix = built.audioMix
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitrate,
            ])
            audioInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { throw ExportError.cannotCreateSession }
            reader.add(audioOutput)
            writer.add(audioInput)
            pumps.append(Pump(output: audioOutput, input: audioInput, reportsProgress: false))
        }
        self.pumps = pumps
    }

    static let audioSampleRate = 48_000

    static func videoSettings(_ settings: ExportSettings) -> [String: Any] {
        let isHEVC = settings.codec == .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: 1 / settings.frameDuration.seconds,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoProfileLevelKey] = isHEVC
            ? kVTProfileLevel_HEVC_Main_AutoLevel as String
            : AVVideoProfileLevelH264HighAutoLevel
        return [
            AVVideoCodecKey: isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(settings.size.width),
            AVVideoHeightKey: Int(settings.size.height),
            // Frames come at the composition's render size; the encoder scales
            // them to the output size (space saving), keeping the aspect ratio.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async { self.start(progress: progress, continuation: continuation) }
                }
            } onCancel: {
                queue.async { self.cancel() }
            }
        } catch {
            // Reader/writer errors caused by cancelling are reported as cancellation.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
    }

    /// Stops reading and writing. A cancelled writer stops asking for data, so
    /// the pumps are finished here; otherwise the export would never complete.
    private func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
        pumps.forEach { $0.finishIfStarted() }
    }

    private func start(progress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<Void, Error>) {
        guard reader.startReading() else { return continuation.resume(throwing: ExportError.readerFailed(reader.error)) }
        guard writer.startWriting() else {
            reader.cancelReading()
            return continuation.resume(throwing: ExportError.writerFailed(writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let total = duration.seconds
        for pump in pumps {
            group.enter()
            pump.start(onFinished: { group.leave() })
            pump.input.requestMediaDataWhenReady(on: queue) { [self] in
                pump.drain(reader: reader, writer: writer) { time in
                    if total > 0 { progress(min(0.99, time.seconds / total)) }
                }
            }
        }

        group.notify(queue: queue) { [self] in
            if writer.status == .cancelled || reader.status == .cancelled {
                return continuation.resume(throwing: CancellationError())
            }
            if reader.status == .failed {
                writer.cancelWriting()
                return continuation.resume(throwing: ExportError.readerFailed(reader.error))
            }
            if writer.status == .failed {
                reader.cancelReading()
                return continuation.resume(throwing: ExportError.writerFailed(writer.error))
            }
            writer.finishWriting { [self] in
                if writer.status == .completed {
                    continuation.resume()
                } else if writer.status == .cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: ExportError.writerFailed(writer.error))
                }
            }
        }
    }
}

/// Moves samples from one reader output to one writer input. Used only on the
/// job's serial queue.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let reportsProgress: Bool
    private var isFinished = false
    private var onFinished: (() -> Void)?

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool) {
        self.output = output
        self.input = input
        self.reportsProgress = reportsProgress
    }

    func start(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    /// Appends samples while the input accepts them, and finishes once the
    /// output is exhausted or reading/writing stopped.
    func drain(reader: AVAssetReader, writer: AVAssetWriter, progress: (CMTime) -> Void) {
        while !isFinished && input.isReadyForMoreMediaData {
            guard reader.status == .reading, writer.status == .writing,
                  let sample = output.copyNextSampleBuffer(),
                  input.append(sample)
            else {
                if writer.status == .writing { input.markAsFinished() }
                finishIfStarted()
                return
            }
            if reportsProgress { progress(CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
    }

    /// Reports completion exactly once.
    func finishIfStarted() {
        guard !isFinished, let onFinished else { return }
        isFinished = true
        self.onFinished = nil
        onFinished()
    }
}
