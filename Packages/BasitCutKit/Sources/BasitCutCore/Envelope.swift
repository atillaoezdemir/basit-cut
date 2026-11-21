import Foundation

extension Ramp {
    /// An ease-in-out change from `from` to `to` over `range` (smoothstep),
    /// as linear pieces: starts and ends gently, which looks softer than one
    /// straight line.
    public static func smooth(over range: TimeRange, from: Double, to: Double, pieces: Int = 8) -> [Ramp] {
        curve(over: range, pieces: pieces) { t in from + (to - from) * (t * t * (3 - 2 * t)) }
    }

    /// An equal-power audio fade over `range`, as linear pieces: a fade in
    /// follows sin(t·π/2), a fade out cos(t·π/2). Two of them overlapping keep
    /// the combined loudness steady (sin² + cos² = 1), the way music players
    /// crossfade songs; a single one keeps the sound up longer and lets it go
    /// gently, instead of thinning it out early.
    public static func equalPower(over range: TimeRange, fadeIn: Bool, pieces: Int = 8) -> [Ramp] {
        curve(over: range, pieces: pieces) { t in
            // Exact end points: cos(π/2) isn't exactly 0 in floating point.
            if t <= 0 { return fadeIn ? 0 : 1 }
            if t >= 1 { return fadeIn ? 1 : 0 }
            return fadeIn ? sin(t * .pi / 2) : cos(t * .pi / 2)
        }
    }

    /// `value(t)` for t in 0...1 over `range`, as `pieces` linear ramps.
    private static func curve(over range: TimeRange, pieces: Int, value: (Double) -> Double) -> [Ramp] {
        func v(_ i: Int) -> Double { value(Double(i) / Double(pieces)) }
        guard range.duration > .zero, pieces > 1 else { return [Ramp(range: range, from: value(0), to: value(1))] }
        func time(_ i: Int) -> RationalTime {
            i == pieces ? range.end : range.start + range.duration.multiplied(by: Int64(i)).divided(by: Int32(pieces))
        }
        return (0..<pieces).map { i in
            Ramp(range: TimeRange(start: time(i), end: time(i + 1)), from: v(i), to: v(i + 1))
        }
    }
}

/// A linear change of a value (opacity or volume) over a timeline range.
public struct Ramp: Hashable, Sendable {
    public var range: TimeRange
    public var from: Double
    public var to: Double

    public init(range: TimeRange, from: Double, to: Double) {
        self.range = range
        self.from = from
        self.to = to
    }

    public func value(at time: RationalTime) -> Double {
        guard range.duration > .zero else { return to }
        if time <= range.start { return from }
        if time >= range.end { return to }
        let fraction = (time - range.start).seconds / range.duration.seconds
        return from + (to - from) * fraction
    }
}

/// A value over time: `initialValue` until the first ramp, then each ramp,
/// holding its end value until the next one. Ramps are sorted and don't overlap.
public struct Envelope: Hashable, Sendable {
    public var initialValue: Double
    public var ramps: [Ramp]

    public init(initialValue: Double = 1, ramps: [Ramp] = []) {
        self.initialValue = initialValue
        self.ramps = ramps
    }

    public func value(at time: RationalTime) -> Double {
        guard let ramp = ramps.last(where: { $0.range.start <= time }) else { return initialValue }
        return ramp.value(at: time)
    }

    /// The ramps cut to `window`, with values interpolated at the cut points.
    public func ramps(in window: TimeRange) -> [Ramp] {
        ramps.compactMap { ramp in
            let start = max(ramp.range.start, window.start)
            let end = min(ramp.range.end, window.end)
            guard end > start else { return nil }
            return Ramp(range: TimeRange(start: start, end: end), from: ramp.value(at: start), to: ramp.value(at: end))
        }
    }
}

/// How one clip's picture and sound fade in and out on the timeline.
public struct ClipEnvelopes: Hashable, Sendable {
    public var opacity: Envelope
    public var volume: Envelope
}

extension TimelineLayout {
    /// Fade applied to the audio at a hard cut, so it doesn't click.
    public static let hardCutAudioFade = RationalTime(value: 3, timescale: 200)   // 15 ms

    /// How bright the picture stays at the middle of a black fade (0 would be
    /// fully black): a dip, not a blackout.
    public static let blackFadeFloor = 0.3

    /// The fades of `item`, following its transitions:
    /// - **Cross fade:** the incoming clip is drawn on top and fades in over the
    ///   overlap; the outgoing one stays opaque underneath. Audio crossfades.
    /// - **Black fade:** the outgoing clip dims to `blackFadeFloor` over its last
    ///   half, the incoming one brightens from it over its first half; the
    ///   audio fades out and in.
    /// Picture fades are ease-in-out curves (`Ramp.smooth`); audio fades are
    /// equal-power curves (`Ramp.equalPower`), so a cross fade keeps the
    /// loudness steady instead of dipping in the middle.
    /// - **Hard cut:** the picture cuts; the audio fades out and in over
    ///   `hardCutAudioFade` on both sides.
    public func envelopes(for item: Item) -> ClipEnvelopes {
        let incoming = item.index > 0 ? items[item.index - 1].clip.outgoingTransition : nil
        let hasPrevious = item.index > 0
        let hasNext = item.index < items.count - 1
        let outgoing = hasNext ? item.clip.outgoingTransition : nil
        // Hard-cut audio fades may use at most half the clip on each side.
        let cutFade = min(Self.hardCutAudioFade, item.clip.duration.divided(by: 2))

        var opacityRamps: [Ramp] = []
        var volumeRamps: [Ramp] = []

        // Fade in.
        var initialOpacity = 1.0
        if let incoming {
            let range = TimeRange(start: item.start, duration: incoming.usagePerClip)
            initialOpacity = incoming.kind == .blackFade ? Self.blackFadeFloor : 0
            opacityRamps += Ramp.smooth(over: range, from: initialOpacity, to: 1)
            volumeRamps += Ramp.equalPower(over: range, fadeIn: true)
        } else if hasPrevious {
            volumeRamps.append(Ramp(range: TimeRange(start: item.start, duration: cutFade), from: 0, to: 1))
        }

        // Fade out.
        if let outgoing {
            let range = TimeRange(start: item.end - outgoing.usagePerClip, end: item.end)
            // In a cross fade the incoming clip covers this one.
            if outgoing.kind == .blackFade { opacityRamps += Ramp.smooth(over: range, from: 1, to: Self.blackFadeFloor) }
            volumeRamps += Ramp.equalPower(over: range, fadeIn: false)
        } else if hasNext {
            volumeRamps.append(Ramp(range: TimeRange(start: item.end - cutFade, end: item.end), from: 1, to: 0))
        }

        return ClipEnvelopes(
            opacity: Envelope(initialValue: initialOpacity, ramps: opacityRamps),
            volume: Envelope(initialValue: hasPrevious ? 0 : 1, ramps: volumeRamps)
        )
    }
}
