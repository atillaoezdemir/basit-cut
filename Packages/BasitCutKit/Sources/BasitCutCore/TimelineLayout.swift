import Foundation

/// Where each clip sits on the timeline.
///
/// `start(0) = 0`, `start(i+1) = start(i) + duration(i) − overlap(i)`, where the
/// overlap is the cross-fade duration (black fades and hard cuts don't overlap).
public struct TimelineLayout: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var clip: Clip
        public var index: Int
        /// Position on the timeline.
        public var range: TimeRange
        /// Overlap with the previous clip (cross fade).
        public var incomingOverlap: RationalTime
        /// Overlap with the next clip (cross fade).
        public var outgoingOverlap: RationalTime
        /// How long the sound starts before the picture: at an incoming black
        /// fade, source audio from before the clip's in point plays under the
        /// end of the previous clip, so the two sounds crossfade.
        public var audioLeadIn: RationalTime = .zero
        /// How long the sound continues after the picture, the same way at an
        /// outgoing black fade.
        public var audioTail: RationalTime = .zero

        /// Where the clip's sound plays on the timeline.
        public var audioRange: TimeRange {
            TimeRange(start: range.start - audioLeadIn, end: range.end + audioTail)
        }

        /// The source range of the clip's sound (`audioRange` in the source).
        public var audioSourceRange: TimeRange {
            TimeRange(start: clip.sourceRange.start - audioLeadIn, end: clip.sourceRange.end + audioTail)
        }

        public var start: RationalTime { range.start }
        public var end: RationalTime { range.end }

        /// Converts a timeline time inside this item to a time in the source.
        public func sourceTime(at timelineTime: RationalTime) -> RationalTime {
            clip.sourceRange.start + (timelineTime - range.start)
        }
    }

    public let items: [Item]
    public let duration: RationalTime

    /// With the project's sources, black fades crossfade the sound across the
    /// cut where the sources have material beyond the clips (see `audioTail`).
    public init(project: Project) {
        self.init(clips: project.clips, sourceDurations: Dictionary(
            project.sources.map { ($0.id, $0.duration) }, uniquingKeysWith: { a, _ in a }
        ))
    }

    /// Without source durations no extra source material is used, so black
    /// fades dip the sound to silence at the cut.
    public init(clips: [Clip], sourceDurations: [MediaSource.ID: RationalTime] = [:]) {
        var items: [Item] = []
        var cursor = RationalTime.zero
        var incoming = RationalTime.zero
        for (index, clip) in clips.enumerated() {
            let isLast = index == clips.count - 1
            let outgoing = isLast ? .zero : (clip.outgoingTransition?.overlap ?? .zero)
            items.append(Item(
                clip: clip,
                index: index,
                range: TimeRange(start: cursor, duration: clip.duration),
                incomingOverlap: incoming,
                outgoingOverlap: outgoing
            ))
            cursor = cursor + clip.duration - outgoing
            incoming = outgoing
        }
        // Black fades: each side's sound reaches across the cut by up to the
        // half of the transition the other clip uses, as far as its source allows.
        for index in items.indices.dropLast() {
            guard let transition = items[index].clip.outgoingTransition, transition.kind == .blackFade,
                  let available = sourceDurations[items[index].clip.sourceID],
                  sourceDurations[items[index + 1].clip.sourceID] != nil
            else { continue }
            let half = transition.usagePerClip
            let outgoing = items[index].clip.sourceRange, incoming = items[index + 1].clip.sourceRange
            items[index].audioTail = max(.zero, min(half, available - outgoing.end))
            items[index + 1].audioLeadIn = max(.zero, min(half, incoming.start))
        }
        self.items = items
        self.duration = items.last?.end ?? .zero
    }

    /// The clip shown at `time`. During a cross fade overlap the incoming
    /// (later) clip wins.
    public func item(at time: RationalTime) -> Item? {
        items.last { $0.range.contains(time) }
    }

    public func item(id: Clip.ID) -> Item? {
        items.first { $0.clip.id == id }
    }
}
