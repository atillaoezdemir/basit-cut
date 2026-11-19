import Foundation

public enum TimelineEditError: Error, Equatable, Sendable {
    case clipNotFound
    case sourceNotFound
    case nothingAtTime
    /// A split would create a clip shorter than `TimelineEditor.minimumClipDuration`.
    case splitTooCloseToEdge
    case indexOutOfRange
}

/// Pure, validated edit operations on a `Project`.
///
/// Every operation leaves the project in a valid state: clip ranges stay inside
/// their sources and are at least `minimumClipDuration` long, and transitions
/// fit their neighbouring clips (see `normalizeTransitions`).
public enum TimelineEditor {
    /// Shortest clip a split or trim may produce.
    public static let minimumClipDuration = RationalTime(value: 1, timescale: 10)   // 0.1 s

    public enum Edge: Sendable { case leading, trailing }

    // MARK: Import

    /// Adds `sources` (if not present yet) and inserts one full-length clip per
    /// source at `index` (default: end of timeline). Returns the new clip IDs.
    @discardableResult
    public static func insertClips(
        for sources: [MediaSource],
        at index: Int? = nil,
        in project: inout Project
    ) throws -> [Clip.ID] {
        let insertionIndex = index ?? project.clips.count
        guard (0...project.clips.count).contains(insertionIndex) else { throw TimelineEditError.indexOutOfRange }
        for source in sources where project.source(id: source.id) == nil {
            project.sources.append(source)
        }
        let clips = sources.map {
            Clip(sourceID: $0.id, sourceRange: TimeRange(start: .zero, duration: $0.duration))
        }
        preservingTransitions(in: &project) { allClips in
            allClips.insert(contentsOf: clips, at: insertionIndex)
        }
        return clips.map(\.id)
    }

    // MARK: Split

    /// Splits the clip under `time` (timeline time) at the nearest earlier frame
    /// boundary. The left part keeps the clip ID; returns the right part's ID.
    @discardableResult
    public static func split(at time: RationalTime, in project: inout Project) throws -> Clip.ID {
        let layout = TimelineLayout(project: project)
        guard let item = layout.item(at: time) else { throw TimelineEditError.nothingAtTime }
        guard let source = project.source(id: item.clip.sourceID) else { throw TimelineEditError.sourceNotFound }

        let original = item.clip
        let cut = item.sourceTime(at: time).floored(toMultipleOf: source.frameDuration)
        guard cut - original.sourceRange.start >= minimumClipDuration,
              original.sourceRange.end - cut >= minimumClipDuration
        else { throw TimelineEditError.splitTooCloseToEdge }

        var left = original
        left.sourceRange = TimeRange(start: original.sourceRange.start, end: cut)
        left.outgoingTransition = nil
        var right = original
        right.id = UUID()
        right.sourceRange = TimeRange(start: cut, end: original.sourceRange.end)

        project.clips[item.index] = left
        project.clips.insert(right, at: item.index + 1)
        normalizeTransitions(in: &project)
        return right.id
    }

    // MARK: Trim

    /// The source range a trim would produce, clamped to the source bounds and
    /// the minimum clip duration. `sourceTime` is snapped to a frame boundary.
    public static func trimmedRange(
        of clip: Clip,
        source: MediaSource,
        edge: Edge,
        to sourceTime: RationalTime
    ) -> TimeRange {
        let snapped = sourceTime.rounded(toMultipleOf: source.frameDuration)
        let range = clip.sourceRange
        switch edge {
        case .leading:
            let start = min(max(snapped, .zero), range.end - minimumClipDuration)
            return TimeRange(start: start, end: range.end)
        case .trailing:
            let end = max(min(snapped, source.duration), range.start + minimumClipDuration)
            return TimeRange(start: range.start, end: end)
        }
    }

    /// Moves the clip's `edge` to `sourceTime` (a time in the source).
    public static func trim(
        clip clipID: Clip.ID,
        edge: Edge,
        to sourceTime: RationalTime,
        in project: inout Project
    ) throws {
        guard let index = project.clipIndex(id: clipID) else { throw TimelineEditError.clipNotFound }
        let clip = project.clips[index]
        guard let source = project.source(id: clip.sourceID) else { throw TimelineEditError.sourceNotFound }
        project.clips[index].sourceRange = trimmedRange(of: clip, source: source, edge: edge, to: sourceTime)
        normalizeTransitions(in: &project)
    }

    // MARK: Delete & reorder

    public static func delete(clips clipIDs: Set<Clip.ID>, in project: inout Project) throws {
        guard clipIDs.allSatisfy({ project.clipIndex(id: $0) != nil }) else { throw TimelineEditError.clipNotFound }
        preservingTransitions(in: &project) { clips in
            clips.removeAll { clipIDs.contains($0.id) }
        }
        removeUnusedSources(in: &project)
    }

    /// Moves a clip so that it ends up at `destination` in the resulting order.
    public static func move(clip clipID: Clip.ID, to destination: Int, in project: inout Project) throws {
        guard let index = project.clipIndex(id: clipID) else { throw TimelineEditError.clipNotFound }
        guard project.clips.indices.contains(destination) else { throw TimelineEditError.indexOutOfRange }
        preservingTransitions(in: &project) { clips in
            let clip = clips.remove(at: index)
            clips.insert(clip, at: destination)
        }
    }

    // MARK: Transitions

    /// Sets (or with `nil` removes) the transition at the cut after `clipID`.
    /// The duration is clamped to fit the neighbouring clips.
    public static func setTransition(
        _ transition: Transition?,
        after clipID: Clip.ID,
        in project: inout Project
    ) throws {
        guard let index = project.clipIndex(id: clipID) else { throw TimelineEditError.clipNotFound }
        guard index < project.clips.count - 1 else { throw TimelineEditError.indexOutOfRange }
        project.clips[index].outgoingTransition = transition
        normalizeTransitions(in: &project)
    }

    /// Enforces the transition invariants:
    /// - the last clip has no outgoing transition;
    /// - durations stay within `Transition.minimumDuration…maximumDuration`;
    /// - on each clip, incoming + outgoing transition usage ≤ clip duration.
    /// Transitions that would get shorter than the minimum are removed.
    public static func normalizeTransitions(in project: inout Project) {
        var incomingUsage = RationalTime.zero
        for index in project.clips.indices {
            let clip = project.clips[index]
            guard var transition = clip.outgoingTransition, index < project.clips.count - 1 else {
                project.clips[index].outgoingTransition = nil
                incomingUsage = .zero
                continue
            }
            let next = project.clips[index + 1]
            let available = min(clip.duration - incomingUsage, next.duration)
            // usagePerClip is `duration` (cross fade) or `duration / 2` (black fade).
            let maxDuration = transition.kind == .crossFade ? available : available.multiplied(by: 2)
            transition.duration = min(transition.duration, maxDuration, Transition.maximumDuration)
            if transition.duration < Transition.minimumDuration {
                project.clips[index].outgoingTransition = nil
                incomingUsage = .zero
            } else {
                project.clips[index].outgoingTransition = transition
                incomingUsage = transition.usagePerClip
            }
        }
    }

    // MARK: Cover

    /// The source frame shown at `time` on the timeline, as a cover. At the
    /// very end of the timeline, the last frame of the last clip.
    public static func coverFrame(at time: RationalTime, in project: Project) -> CoverFrame? {
        let layout = TimelineLayout(project: project)
        guard let last = layout.items.last else { return nil }
        let item = layout.item(at: time) ?? (time >= layout.duration ? last : nil)
        guard let item, let source = project.source(id: item.clip.sourceID) else { return nil }
        let clamped = min(item.sourceTime(at: time), item.clip.sourceRange.end - source.frameDuration)
        let frame = max(clamped, item.clip.sourceRange.start).floored(toMultipleOf: source.frameDuration)
        return CoverFrame(sourceID: source.id, time: frame)
    }

    // MARK: Helpers

    /// Runs `change` on the clip list and keeps a transition only if the same
    /// two clips are still adjacent afterwards (a cut that disappears loses its transition).
    private static func preservingTransitions(
        in project: inout Project,
        _ change: (inout [Clip]) throws -> Void
    ) rethrows {
        var transitionsByCut: [CutKey: Transition] = [:]
        for (clip, next) in zip(project.clips, project.clips.dropFirst()) {
            if let transition = clip.outgoingTransition {
                transitionsByCut[CutKey(from: clip.id, to: next.id)] = transition
            }
        }
        try change(&project.clips)
        for index in project.clips.indices {
            let next = index + 1 < project.clips.count ? project.clips[index + 1].id : nil
            project.clips[index].outgoingTransition = next.flatMap {
                transitionsByCut[CutKey(from: project.clips[index].id, to: $0)]
            }
        }
        normalizeTransitions(in: &project)
    }

    private struct CutKey: Hashable {
        let from: Clip.ID
        let to: Clip.ID
    }

    /// Drops sources that are neither used by a clip nor by the cover.
    private static func removeUnusedSources(in project: inout Project) {
        var used = Set(project.clips.map(\.sourceID))
        if let cover = project.cover { used.insert(cover.sourceID) }
        project.sources.removeAll { !used.contains($0.id) }
    }
}
