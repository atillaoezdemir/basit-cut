import Foundation

/// A transition at the cut between two adjacent clips.
public struct Transition: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        /// The clips dissolve into each other; they overlap, so the timeline gets shorter.
        case crossFade
        /// Clip A fades to black over the first half, clip B fades in over the second half.
        case blackFade
    }

    public var kind: Kind
    public var duration: RationalTime

    public init(kind: Kind, duration: RationalTime = Transition.defaultDuration) {
        self.kind = kind
        self.duration = duration
    }

    public static let minimumDuration = RationalTime(value: 1, timescale: 5)   // 0.2 s
    public static let maximumDuration = RationalTime.seconds(5)
    public static let defaultDuration = RationalTime(value: 3, timescale: 2)   // 1.5 s

    /// How much the two clips overlap on the timeline.
    public var overlap: RationalTime {
        kind == .crossFade ? duration : .zero
    }

    /// How much of each adjacent clip the transition uses.
    public var usagePerClip: RationalTime {
        kind == .crossFade ? duration : duration.divided(by: 2)
    }
}
