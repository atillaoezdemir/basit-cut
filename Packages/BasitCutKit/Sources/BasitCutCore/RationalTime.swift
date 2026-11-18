import Foundation

/// An exact rational time value (`value / timescale` seconds).
///
/// Mirrors `CMTime` without depending on CoreMedia, so the timeline model stays
/// free of AVFoundation. Arithmetic is exact whenever the common timescale fits
/// into `Int32`; equality and ordering compare the rational values, so
/// `1/2 == 300/600`.
public struct RationalTime: Sendable, Codable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    /// Creates a time from seconds, rounded to the nearest tick of `preferredTimescale`.
    public init(seconds: Double, preferredTimescale: Int32 = 600) {
        self.init(value: Int64((seconds * Double(preferredTimescale)).rounded()), timescale: preferredTimescale)
    }

    public static let zero = RationalTime(value: 0, timescale: 1)

    public static func seconds(_ seconds: Int64) -> RationalTime {
        RationalTime(value: seconds, timescale: 1)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    /// The same value with the smallest possible timescale.
    public var reduced: RationalTime {
        let divisor = gcd(abs(value), Int64(timescale))
        guard divisor > 1 else { return self }
        return RationalTime(value: value / divisor, timescale: Int32(Int64(timescale) / divisor))
    }

    /// The largest multiple of `step` that is `<= self`.
    public func floored(toMultipleOf step: RationalTime) -> RationalTime {
        precondition(step.value > 0, "step must be positive")
        let numerator = Int128(value) * Int128(step.timescale)
        let denominator = Int128(step.value) * Int128(timescale)
        var multiple = numerator / denominator
        if numerator % denominator != 0 && numerator < 0 { multiple -= 1 }
        return step.multiplied(by: Int64(multiple))
    }

    /// The multiple of `step` nearest to `self` (ties round up).
    public func rounded(toMultipleOf step: RationalTime) -> RationalTime {
        let lower = floored(toMultipleOf: step)
        let upper = lower + step
        return (self - lower) < (upper - self) ? lower : upper
    }

    public func multiplied(by factor: Int64) -> RationalTime {
        RationalTime(value: value * factor, timescale: timescale)
    }

    public func divided(by divisor: Int32) -> RationalTime {
        precondition(divisor > 0, "divisor must be positive")
        let reduced = self.reduced
        if value % Int64(divisor) == 0 {
            return RationalTime(value: value / Int64(divisor), timescale: timescale)
        }
        let (scale, overflow) = reduced.timescale.multipliedReportingOverflow(by: divisor)
        if !overflow { return RationalTime(value: reduced.value, timescale: scale) }
        return RationalTime(seconds: seconds / Double(divisor), preferredTimescale: reduced.timescale)
    }

    /// Converts to `timescale`, rounding toward negative infinity.
    public func converted(toTimescale newTimescale: Int32) -> RationalTime {
        if newTimescale == timescale { return self }
        let numerator = Int128(value) * Int128(newTimescale)
        var newValue = numerator / Int128(timescale)
        if numerator % Int128(timescale) != 0 && numerator < 0 { newValue -= 1 }
        return RationalTime(value: Int64(newValue), timescale: newTimescale)
    }
}

// MARK: - Arithmetic

extension RationalTime {
    /// A timescale both values can be expressed in exactly, or the larger one if
    /// the exact common timescale would overflow `Int32` (then rounding occurs).
    private static func commonTimescale(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        if lhs == rhs { return lhs }
        let lcm = Int64(lhs) / gcd(Int64(lhs), Int64(rhs)) * Int64(rhs)
        return lcm <= Int64(Int32.max) ? Int32(lcm) : max(lhs, rhs)
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let scale = commonTimescale(lhs.timescale, rhs.timescale)
        return RationalTime(
            value: lhs.converted(toTimescale: scale).value + rhs.converted(toTimescale: scale).value,
            timescale: scale
        )
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        lhs + (-rhs)
    }

    public static prefix func - (time: RationalTime) -> RationalTime {
        RationalTime(value: -time.value, timescale: time.timescale)
    }

    public static func += (lhs: inout RationalTime, rhs: RationalTime) { lhs = lhs + rhs }
    public static func -= (lhs: inout RationalTime, rhs: RationalTime) { lhs = lhs - rhs }
}

// MARK: - Equality & ordering (by rational value)

extension RationalTime: Comparable, Hashable {
    public static func == (lhs: RationalTime, rhs: RationalTime) -> Bool {
        Int128(lhs.value) * Int128(rhs.timescale) == Int128(rhs.value) * Int128(lhs.timescale)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        Int128(lhs.value) * Int128(rhs.timescale) < Int128(rhs.value) * Int128(lhs.timescale)
    }

    public func hash(into hasher: inout Hasher) {
        let reduced = self.reduced
        hasher.combine(reduced.value)
        hasher.combine(reduced.timescale)
    }
}

extension RationalTime: CustomStringConvertible {
    public var description: String { "\(value)/\(timescale) (\(String(format: "%.3f", seconds)) s)" }
}

private func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}
