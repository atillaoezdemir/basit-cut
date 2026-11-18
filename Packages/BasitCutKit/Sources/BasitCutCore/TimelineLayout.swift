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

        public var start: RationalTime { range.start }
        public var end: RationalTime { range.end }

        /// Converts a timeline time inside this item to a time in the source.
        public func sourceTime(at timelineTime: RationalTime) -> RationalTime {
            clip.sourceRange.start + (timelineTime - range.start)
        }
    }

    public let items: [Item]
    public let duration: RationalTime

    public init(project: Project) {
        self.init(clips: project.clips)
    }

    public init(clips: [Clip]) {
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
