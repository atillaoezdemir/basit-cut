import Foundation

/// A video codec identified by its FourCC (e.g. `avc1`, `hvc1`).
public struct VideoCodec: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let h264 = VideoCodec(rawValue: "avc1")
    public static let hevc = VideoCodec(rawValue: "hvc1")

    /// Codec family: `hvc1` and `hev1` are both HEVC.
    public var family: String {
        switch rawValue {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "ProRes"
        default: rawValue
        }
    }
}

/// A referenced source video file. basit-cut never modifies these files.
public struct MediaSource: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Security-scoped bookmark to the file (survives app restarts).
    public var bookmark: Data
    /// Last known path, for display and relinking.
    public var lastKnownPath: String
    public var duration: RationalTime
    /// Duration of one frame (1 / frame rate).
    public var frameDuration: RationalTime
    /// Encoded size, before applying `transform`.
    public var naturalSize: Size
    /// The track's `preferredTransform` (rotation of phone videos).
    public var transform: Transform2D
    public var codec: VideoCodec
    /// Average video bitrate in bits per second.
    public var videoBitrate: Int
    public var hasAudio: Bool
    public var creationDate: Date?

    public init(
        id: UUID = UUID(),
        bookmark: Data,
        lastKnownPath: String,
        duration: RationalTime,
        frameDuration: RationalTime,
        naturalSize: Size,
        transform: Transform2D = .identity,
        codec: VideoCodec,
        videoBitrate: Int,
        hasAudio: Bool,
        creationDate: Date? = nil
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.duration = duration
        self.frameDuration = frameDuration
        self.naturalSize = naturalSize
        self.transform = transform
        self.codec = codec
        self.videoBitrate = videoBitrate
        self.hasAudio = hasAudio
        self.creationDate = creationDate
    }

    public var displayName: String { URL(fileURLWithPath: lastKnownPath).lastPathComponent }

    /// Display size after applying the rotation metadata.
    public var orientedSize: Size { transform.applied(to: naturalSize) }

    public var frameRate: Double { 1 / frameDuration.seconds }
}

/// How a source differs from the project's reference format.
public enum FormatDifference: Hashable, Sendable {
    case resolution(expected: Size, actual: Size)
    case frameRate(expected: Double, actual: Double)
    case codec(expected: VideoCodec, actual: VideoCodec)
}

extension MediaSource {
    /// Differences in resolution, frame rate and codec compared to `reference`.
    /// All clips in a project are expected to share one format.
    public func formatDifferences(comparedTo reference: MediaSource) -> [FormatDifference] {
        var differences: [FormatDifference] = []
        if orientedSize != reference.orientedSize {
            differences.append(.resolution(expected: reference.orientedSize, actual: orientedSize))
        }
        if abs(frameRate - reference.frameRate) > 0.01 {
            differences.append(.frameRate(expected: reference.frameRate, actual: frameRate))
        }
        if codec.family != reference.codec.family {
            differences.append(.codec(expected: reference.codec, actual: codec))
        }
        return differences
    }
}
