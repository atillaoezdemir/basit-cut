import Foundation

/// Project-wide crop / aspect ratio.
public struct CropSetting: Hashable, Codable, Sendable {
    public enum Mode: String, Hashable, Codable, Sendable, CaseIterable {
        case original, ratio16x9, ratio9x16, free

        /// Unknown or retired modes (early projects could use 1:1) are read
        /// as free crop: the stored rect stays valid, only its ratio isn't locked.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .free
        }
    }

    public var mode: Mode
    public var rect: NormalizedRect

    public init(mode: Mode, rect: NormalizedRect = .full) {
        self.mode = mode
        self.rect = rect
    }

    public static let original = CropSetting(mode: .original)
}

/// The frame chosen as cover image. The image itself is stored in the document package.
public struct CoverFrame: Hashable, Codable, Sendable {
    public var sourceID: MediaSource.ID
    public var time: RationalTime

    public init(sourceID: MediaSource.ID, time: RationalTime) {
        self.sourceID = sourceID
        self.time = time
    }
}

/// A basit-cut project: references to source files plus edit decisions.
public struct Project: Hashable, Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var sources: [MediaSource]
    /// Timeline order is array order.
    public var clips: [Clip]
    public var crop: CropSetting
    public var cover: CoverFrame?

    public init(
        sources: [MediaSource] = [],
        clips: [Clip] = [],
        crop: CropSetting = .original,
        cover: CoverFrame? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.sources = sources
        self.clips = clips
        self.crop = crop
        self.cover = cover
    }

    public func source(id: MediaSource.ID) -> MediaSource? {
        sources.first { $0.id == id }
    }

    public func clipIndex(id: Clip.ID) -> Int? {
        clips.firstIndex { $0.id == id }
    }

    public var hasTransitions: Bool {
        clips.contains { $0.outgoingTransition != nil }
    }
}
