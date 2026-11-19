import Foundation

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

    /// The fades of `item`, following its transitions:
    /// - **Cross fade:** the incoming clip is drawn on top and fades in over the
    ///   overlap; the outgoing one stays opaque underneath. Audio crossfades.
    /// - **Black fade:** the outgoing clip fades to black over its last half,
    ///   the incoming one fades in from black over its first half; the audio
    ///   follows the picture.
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
        if let incoming {
            let length = incoming.usagePerClip
            let ramp = Ramp(range: TimeRange(start: item.start, duration: length), from: 0, to: 1)
            opacityRamps.append(ramp)
            volumeRamps.append(ramp)
        } else if hasPrevious {
            volumeRamps.append(Ramp(range: TimeRange(start: item.start, duration: cutFade), from: 0, to: 1))
        }

        // Fade out.
        if let outgoing {
            let length = outgoing.usagePerClip
            let ramp = Ramp(range: TimeRange(start: item.end - length, end: item.end), from: 1, to: 0)
            // In a cross fade the incoming clip covers this one.
            if outgoing.kind == .blackFade { opacityRamps.append(ramp) }
            volumeRamps.append(ramp)
        } else if hasNext {
            volumeRamps.append(Ramp(range: TimeRange(start: item.end - cutFade, end: item.end), from: 1, to: 0))
        }

        return ClipEnvelopes(
            opacity: Envelope(initialValue: incoming == nil ? 1 : 0, ramps: opacityRamps),
            volume: Envelope(initialValue: hasPrevious ? 0 : 1, ramps: volumeRamps)
        )
    }
}
