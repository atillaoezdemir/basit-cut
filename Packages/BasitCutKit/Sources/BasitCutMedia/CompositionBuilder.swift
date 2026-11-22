import AVFoundation
import BasitCutCore

/// The AVFoundation objects for a project. The same value drives both the
/// preview (`makePlayerItem()`) and the export, so they always match.
///
/// Immutable after construction, hence `@unchecked Sendable`.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let renderSize: CGSize
    public let layout: TimelineLayout

    @MainActor
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum CompositionError: LocalizedError, Equatable {
    case emptyTimeline
    case missingSource(String)
    case noVideoTrack(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline is empty."
        case .missingSource(let name): "The source file “\(name)” is not available."
        case .noVideoTrack(let name): "“\(name)” contains no video track."
        }
    }
}

/// Builds the composition from the project model.
///
/// Clips alternate between two video tracks (A/B) and two audio tracks, so an
/// overlapping cross fade is just two tracks playing at once. The video
/// composition gets one instruction per segment between clip boundaries, with
/// the opacity ramps of `TimelineLayout.envelopes(for:)`; the audio mix applies
/// the matching volume ramps.
public enum CompositionBuilder {
    public static func build(
        project: Project,
        assets: [MediaSource.ID: AVAsset]
    ) async throws -> BuiltComposition {
        let layout = TimelineLayout(project: project)
        guard let firstClip = layout.items.first?.clip,
              let firstSource = project.source(id: firstClip.sourceID)
        else { throw CompositionError.emptyTimeline }

        let composition = AVMutableComposition()
        let videoTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let audioTracks = (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        // Every clip is fitted into the canvas (the first clip's upright frame),
        // then the crop is cut out of it.
        let canvas = (project.canvasSize ?? firstSource.orientedSize).cgSize
        let crop = project.cropRect ?? PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let renderSize = crop.size.cgSize
        let cropShift = CGAffineTransform(translationX: -crop.x, y: -crop.y)

        // Insert media.
        var transforms: [Clip.ID: CGAffineTransform] = [:]
        for item in layout.items {
            guard let source = project.source(id: item.clip.sourceID) else {
                throw CompositionError.missingSource("unknown")
            }
            guard let asset = assets[source.id] else { throw CompositionError.missingSource(source.displayName) }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.noVideoTrack(source.displayName)
            }
            let range = try await clamped(item.clip.sourceRange.cmTimeRange, to: sourceVideo)
            let at = item.start.cmTime
            try videoTracks[item.index % 2].insertTimeRange(range, of: sourceVideo, at: at)

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                // The sound can reach past the picture at black fades.
                let wanted = item.audioSourceRange.cmTimeRange
                let audioRange = try await clamped(wanted, to: sourceAudio)
                // If the audio track starts later than asked, keep it in sync.
                let audioAt = item.audioRange.start.cmTime + (audioRange.start - wanted.start)
                try audioTracks[item.index % 2].insertTimeRange(audioRange, of: sourceAudio, at: audioAt)
            }
            transforms[item.clip.id] = layerTransform(for: source, renderSize: canvas).concatenating(cropShift)
        }
        let envelopes = Dictionary(uniqueKeysWithValues: layout.items.map { ($0.clip.id, layout.envelopes(for: $0)) })

        // Audio: each track gets the volume ramps of its clips (transitions and
        // the short fades at hard cuts). Clips on one track never overlap, and
        // neither do their ramps.
        var audioParameters: [AVAudioMixInputParameters] = []
        for (trackIndex, track) in audioTracks.enumerated() {
            guard !track.segments.isEmpty else {
                composition.removeTrack(track)
                continue
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let items = layout.items.filter { $0.index % 2 == trackIndex }
            // Without an explicit start volume the mixer plays at 1.0 until the
            // first ramp is reached, which it only notices at its next buffer:
            // the start of a fade-in would be audible at full volume.
            if let first = items.first, let initial = envelopes[first.clip.id]?.volume.initialValue {
                parameters.setVolume(Float(initial), at: .zero)
            }
            let ramps = items
                .flatMap { envelopes[$0.clip.id]?.volume.ramps ?? [] }
                .sorted { $0.range.start < $1.range.start }
            for ramp in ramps {
                parameters.setVolumeRamp(fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to), timeRange: ramp.range.cmTimeRange)
            }
            audioParameters.append(parameters)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters

        // Video: one instruction per segment between clip boundaries. Later
        // clips are drawn on top; fades are opacity ramps over the black
        // background.
        let boundaries = Set(layout.items.flatMap { [$0.start, $0.end] }).sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (segmentStart, segmentEnd) in zip(boundaries, boundaries.dropFirst()) {
            let active = layout.items.filter { $0.start < segmentEnd && $0.end > segmentStart }
            guard !active.isEmpty else { continue }
            let segment = TimeRange(start: segmentStart, end: segmentEnd)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment.cmTimeRange
            instruction.layerInstructions = active.reversed().map { item in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[item.index % 2])
                layer.setTransform(transforms[item.clip.id] ?? .identity, at: segmentStart.cmTime)
                if let opacity = envelopes[item.clip.id]?.opacity {
                    layer.setOpacity(Float(opacity.value(at: segmentStart)), at: segmentStart.cmTime)
                    for ramp in opacity.ramps(in: segment) {
                        layer.setOpacityRamp(fromStartOpacity: Float(ramp.from), toEndOpacity: Float(ramp.to), timeRange: ramp.range.cmTimeRange)
                    }
                }
                return layer
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = firstSource.frameDuration.cmTime
        videoComposition.instructions = instructions

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioParameters.isEmpty ? nil : audioMix,
            renderSize: renderSize,
            layout: layout
        )
    }

    /// A plain composition for passthrough export: one video and one audio
    /// track, clips back to back, and the shared rotation stored as the track's
    /// `preferredTransform` (nothing is rendered, so no video composition).
    /// Only valid when `ExportPlan.canPassthrough(project)` is true.
    public static func buildPassthrough(
        project: Project,
        assets: [MediaSource.ID: AVAsset]
    ) async throws -> AVComposition {
        let layout = TimelineLayout(project: project)
        guard let reference = project.referenceSource else { throw CompositionError.emptyTimeline }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.emptyTimeline }
        video.preferredTransform = reference.transform.cgAffineTransform

        for item in layout.items {
            guard let source = project.source(id: item.clip.sourceID), let asset = assets[source.id] else {
                throw CompositionError.missingSource(project.source(id: item.clip.sourceID)?.displayName ?? "unknown")
            }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.noVideoTrack(source.displayName)
            }
            let at = item.start.cmTime
            try video.insertTimeRange(try await clamped(item.clip.sourceRange.cmTimeRange, to: sourceVideo), of: sourceVideo, at: at)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(try await clamped(item.clip.sourceRange.cmTimeRange, to: sourceAudio), of: sourceAudio, at: at)
            }
        }
        if audio.segments.isEmpty { composition.removeTrack(audio) }
        return composition
    }

    /// Rotates a source upright (`preferredTransform`) and fits it centered
    /// into `renderSize`, keeping its aspect ratio.
    static func layerTransform(for source: MediaSource, renderSize: CGSize) -> CGAffineTransform {
        let preferred = source.transform.cgAffineTransform
        let oriented = CGRect(origin: .zero, size: source.naturalSize.cgSize).applying(preferred)
        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (renderSize.width - oriented.width * scale) / 2,
                y: (renderSize.height - oriented.height * scale) / 2
            ))
    }

    /// Keeps `range` inside the track; a track can be a few ms shorter than the asset.
    private static func clamped(_ range: CMTimeRange, to track: AVAssetTrack) async throws -> CMTimeRange {
        let trackRange = try await track.load(.timeRange)
        let intersection = range.intersection(trackRange)
        return intersection.isEmpty ? range : intersection
    }
}
