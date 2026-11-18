import Foundation

/// A piece of a source video placed on the timeline.
public struct Clip: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sourceID: MediaSource.ID
    /// In and out points in the source.
    public var sourceRange: TimeRange
    /// Transition to the next clip; `nil` means a hard cut.
    public var outgoingTransition: Transition?

    public init(
        id: UUID = UUID(),
        sourceID: MediaSource.ID,
        sourceRange: TimeRange,
        outgoingTransition: Transition? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRange = sourceRange
        self.outgoingTransition = outgoingTransition
    }

    public var duration: RationalTime { sourceRange.duration }
}
