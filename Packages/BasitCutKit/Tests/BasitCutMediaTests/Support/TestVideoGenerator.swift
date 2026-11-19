import AVFoundation
import Foundation

/// Writes small synthetic test videos (changing gray frames + a sine tone), so
/// media tests never depend on personal files.
enum TestVideoGenerator {
    struct Spec {
        var seconds: Double = 2
        var fps: Int32 = 30
        var width = 320
        var height = 180
        var codec: AVVideoCodecType = .h264
        var transform: CGAffineTransform = .identity
        var withAudio = true
        /// Constant brightness for every frame; `nil` makes it change per frame.
        var gray: UInt8?
        /// Left and right halves in different grays (overrides `gray`).
        var halves: (left: UInt8, right: UInt8)?
        var creationDate: Date?
        /// ISO 6709 location, e.g. "+48.8566+002.3522/".
        var location: String?
        var model: String?
        var fileName = "test-\(UUID().uuidString).mov"
    }

    enum GeneratorError: Error { case setupFailed, timedOut, writeFailed(Error?) }

    static func makeVideo(_ spec: Spec = Spec(), in directory: URL) async throws -> URL {
        let url = directory.appending(path: spec.fileName)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ])
        video.expectsMediaDataInRealTime = false
        video.transform = spec.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
        guard writer.canAdd(video) else { throw GeneratorError.setupFailed }
        writer.add(video)

        let sampleRate = 44_100
        var audio: AVAssetWriterInput?
        if spec.withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw GeneratorError.setupFailed }
            writer.add(input)
            audio = input
        }

        // Written like a phone does: QuickTime metadata keys.
        var metadata: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            metadata.append(item)
        }
        if let date = spec.creationDate {
            add(.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: date))
        }
        if let location = spec.location { add(.quickTimeMetadataLocationISO6709, location) }
        if let model = spec.model { add(.quickTimeMetadataModel, model) }
        writer.metadata = metadata

        guard writer.startWriting() else { throw GeneratorError.writeFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(spec.seconds * Double(spec.fps))
        let totalSamples = Int(spec.seconds * Double(sampleRate))
        let chunk = sampleRate / 10
        var frame = 0, sample = 0

        // Prefer the input that is behind, but write to whichever is ready: the
        // AAC encoder buffers internally, so strict ordering can deadlock.
        var idleIterations = 0
        while frame < frameCount || (audio != nil && sample < totalSamples) {
            let videoTime = frame < frameCount ? Double(frame) / Double(spec.fps) : .infinity
            let audioTime = (audio != nil && sample < totalSamples) ? Double(sample) / Double(sampleRate) : .infinity
            let videoReady = videoTime.isFinite && video.isReadyForMoreMediaData
            let audioReady = audioTime.isFinite && (audio?.isReadyForMoreMediaData ?? false)

            if videoReady && (videoTime <= audioTime || !audioReady) {
                guard let pool = adaptor.pixelBufferPool else { throw GeneratorError.setupFailed }
                let gray = spec.gray ?? UInt8((frame * 8) % 256)
                let buffer = try makeFrame(pool: pool, left: spec.halves?.left ?? gray, right: spec.halves?.right ?? gray)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: spec.fps)) else {
                    throw GeneratorError.writeFailed(writer.error)
                }
                frame += 1
                idleIterations = 0
                if frame == frameCount { video.markAsFinished() }
            } else if audioReady, let audio {
                let count = min(chunk, totalSamples - sample)
                guard audio.append(try makeTone(start: sample, count: count, sampleRate: sampleRate)) else {
                    throw GeneratorError.writeFailed(writer.error)
                }
                sample += count
                idleIterations = 0
                // Finish each input as soon as it's done, or the writer keeps
                // waiting for it to interleave with the other track.
                if sample == totalSamples { audio.markAsFinished() }
            } else {
                idleIterations += 1
                if idleIterations > 10_000 { throw GeneratorError.timedOut }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw GeneratorError.writeFailed(writer.error) }
        return url
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "basitcut-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Private

    private static func makeFrame(pool: CVPixelBufferPool, left: UInt8, right: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw GeneratorError.setupFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw GeneratorError.setupFailed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let line = base.advanced(by: row * bytesPerRow)
            memset(line, Int32(left), width / 2 * 4)
            memset(line.advanced(by: width / 2 * 4), Int32(right), (width - width / 2) * 4)
        }
        return buffer
    }

    private static func makeTone(start: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        let samples = (0..<count).map { i in
            Int16(sin(Double(start + i) * 2 * .pi * 440 / Double(sampleRate)) * 8_000)
        }
        let byteCount = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let block, let description else { throw GeneratorError.setupFailed }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: count,
            presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw GeneratorError.setupFailed }
        return sampleBuffer
    }
}
