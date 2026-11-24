import Foundation

/// The two export modes. There are deliberately no other presets.
public enum ExportMode: String, CaseIterable, Codable, Sendable {
    /// Source codec, resolution, frame rate and average bitrate. Lossless
    /// passthrough when nothing needs re-encoding.
    case original
    /// HEVC at up to 4000 kbps (and 60% of the bitrate of H.264 sources), at most 1920×1080 (orientation kept), AAC 128 kbps.
    case spaceSaving
}

/// Concrete encoder settings for a re-encoded export.
public struct ExportSettings: Hashable, Sendable {
    public var codec: VideoCodec
    /// Encoded size in pixels (even numbers, upright orientation).
    public var size: Size
    public var frameDuration: RationalTime
    /// Average video bitrate in bits per second.
    public var videoBitrate: Int
    /// AAC bitrate in bits per second.
    public var audioBitrate: Int

    public init(codec: VideoCodec, size: Size, frameDuration: RationalTime, videoBitrate: Int, audioBitrate: Int) {
        self.codec = codec
        self.size = size
        self.frameDuration = frameDuration
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
    }
}

/// What the exporter should do for a project and mode. Pure and unit-tested;
/// the media layer only carries out the decision.
public enum ExportPlan: Hashable, Sendable {
    /// Copy the compressed samples without re-encoding.
    case passthrough
    /// Render the composition and encode it with these settings.
    case reencode(ExportSettings)

    public static let spaceSavingMaxBitrate = 4_000_000
    /// HEVC needs less data than H.264 for similar quality, so H.264 sources
    /// count with this share of their bitrate. HEVC and other sources have no
    /// such reserve and count fully.
    public static let spaceSavingH264Share = 0.6
    public static let spaceSavingAudioBitrate = 128_000
    public static let originalAudioBitrate = 256_000
    /// Longest edge × shortest edge for space saving; orientation is kept.
    public static let spaceSavingMaxSize = Size(width: 1920, height: 1080)

    public enum PlanError: LocalizedError, Equatable {
        case emptyTimeline

        public var errorDescription: String? {
            switch self {
            case .emptyTimeline: "There is nothing to export. Add clips to the timeline first."
            }
        }
    }

    public static func make(for project: Project, mode: ExportMode) throws -> ExportPlan {
        guard let reference = project.referenceSource, let renderSize = project.renderSize else {
            throw PlanError.emptyTimeline
        }
        let bitrate = averageBitrate(of: project) ?? estimatedBitrate(size: renderSize, frameDuration: reference.frameDuration)

        switch mode {
        case .original:
            if canPassthrough(project) { return .passthrough }
            return .reencode(ExportSettings(
                codec: reencodeCodec(for: reference.codec),
                size: renderSize,
                frameDuration: reference.frameDuration,
                videoBitrate: bitrate,
                audioBitrate: originalAudioBitrate
            ))
        case .spaceSaving:
            return .reencode(ExportSettings(
                codec: .hevc,
                size: fitted(renderSize, within: spaceSavingMaxSize),
                frameDuration: reference.frameDuration,
                videoBitrate: min(spaceSavingMaxBitrate, averageBitrate(of: project, h264Share: spaceSavingH264Share) ?? bitrate),
                audioBitrate: spaceSavingAudioBitrate
            ))
        }
    }

    /// Passthrough copies samples as they are, so it is only possible when
    /// nothing has to be rendered: no transitions, no crop, and every clip has
    /// the reference format and rotation (a single track can't mix them cleanly).
    public static func canPassthrough(_ project: Project) -> Bool {
        guard let reference = project.referenceSource, !project.hasTransitions, project.crop.mode == .original
        else { return false }
        return project.clips.allSatisfy { clip in
            guard let source = project.source(id: clip.sourceID) else { return false }
            return source.naturalSize == reference.naturalSize
                && source.transform == reference.transform
                && source.codec.family == reference.codec.family
                && source.frameDuration == reference.frameDuration
        }
    }

    /// Duration-weighted average of the sources' video bitrates, or nil if none is known.
    /// The bitrate of H.264 sources is multiplied by `h264Share`.
    public static func averageBitrate(of project: Project, h264Share: Double = 1) -> Int? {
        var weighted = 0.0
        var total = 0.0
        for clip in project.clips {
            guard let source = project.source(id: clip.sourceID), source.videoBitrate > 0 else { continue }
            let seconds = clip.duration.seconds
            let share = source.codec.family == VideoCodec.h264.family ? h264Share : 1
            weighted += Double(source.videoBitrate) * share * seconds
            total += seconds
        }
        return total > 0 ? Int((weighted / total).rounded()) : nil
    }

    /// Scales `size` down to fit within `limit` (compared longest edge to
    /// longest edge, so portrait stays portrait). Never scales up.
    public static func fitted(_ size: Size, within limit: Size) -> Size {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        let limitLong = max(limit.width, limit.height), limitShort = min(limit.width, limit.height)
        let scale = min(1, limitLong / long, limitShort / short)
        return Size(width: even(size.width * scale), height: even(size.height * scale))
    }

    /// H.264 stays H.264; everything else (HEVC, and codecs without a bitrate
    /// setting such as ProRes) is encoded as HEVC.
    static func reencodeCodec(for codec: VideoCodec) -> VideoCodec {
        codec.family == VideoCodec.h264.family ? .h264 : .hevc
    }

    /// Fallback when no source reports a bitrate: 0.1 bits per pixel per frame.
    static func estimatedBitrate(size: Size, frameDuration: RationalTime) -> Int {
        Int((size.width * size.height / frameDuration.seconds * 0.1).rounded())
    }

    static func even(_ value: Double) -> Double {
        max(2, (value / 2).rounded() * 2)
    }
}

extension Project {
    /// The source of the first clip. It defines the project's format.
    public var referenceSource: MediaSource? {
        clips.first.flatMap { source(id: $0.sourceID) }
    }

    /// Output frame size: the cropped area of the first clip's upright frame
    /// (the whole frame without a crop), rounded to even numbers.
    public var renderSize: Size? {
        cropRect?.size
    }
}
