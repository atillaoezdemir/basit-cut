import Foundation

/// A half-open time range `[start, start + duration)`.
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: RationalTime
    public var duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: RationalTime, end: RationalTime) {
        self.init(start: start, duration: end - start)
    }

    public var end: RationalTime { start + duration }

    public func contains(_ time: RationalTime) -> Bool {
        time >= start && time < end
    }
}
