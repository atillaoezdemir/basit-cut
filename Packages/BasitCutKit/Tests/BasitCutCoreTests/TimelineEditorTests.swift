import Foundation
import Testing
@testable import BasitCutCore

struct TimelineEditorTests {
    // MARK: Import

    @Test func insertAddsFullLengthClipsAndSources() throws {
        var project = Project()
        let a = Fixture.source(seconds: 3), b = Fixture.source(seconds: 5)
        let ids = try TimelineEditor.insertClips(for: [a, b], in: &project)
        #expect(project.clips.map(\.id) == ids)
        #expect(project.clips.map(\.sourceRange) == [TimeRange(start: .zero, duration: s(3)), TimeRange(start: .zero, duration: s(5))])
        #expect(project.sources.count == 2)

        try TimelineEditor.insertClips(for: [a], at: 0, in: &project)
        #expect(project.sources.count == 2, "re-importing a known source doesn't duplicate it")
        #expect(project.clips.first?.sourceID == a.id)
    }

    // MARK: Split

    @Test func splitCreatesTwoAdjacentClips() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        let originalID = project.clips[1].id
        let rightID = try TimelineEditor.split(at: s(6.5), in: &project)

        #expect(project.clips.count == 3)
        #expect(project.clips[1].id == originalID)
        #expect(project.clips[2].id == rightID)
        #expect(project.clips[1].sourceRange == TimeRange(start: s(0), end: s(2.5)))
        #expect(project.clips[2].sourceRange == TimeRange(start: s(2.5), end: s(6)))
        #expect(TimelineLayout(project: project).duration == s(10), "split doesn't change duration")
    }

    @Test func splitSnapsToEarlierFrameBoundary() throws {
        var project = Fixture.project(clipSeconds: [4])
        try TimelineEditor.split(at: s(1.05), in: &project)   // 31.5 frames at 30 fps
        #expect(project.clips[0].sourceRange.end == RationalTime(value: 31, timescale: 30))
    }

    @Test func splitRejectsCutsNearEdgesOrOutsideTimeline() {
        var project = Fixture.project(clipSeconds: [4])
        #expect(throws: TimelineEditError.splitTooCloseToEdge) { try TimelineEditor.split(at: s(0.05), in: &project) }
        #expect(throws: TimelineEditError.splitTooCloseToEdge) { try TimelineEditor.split(at: s(3.95), in: &project) }
        #expect(throws: TimelineEditError.nothingAtTime) { try TimelineEditor.split(at: s(4), in: &project) }
    }

    @Test func splitMovesOutgoingTransitionToRightPart() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        let fade = Transition(kind: .blackFade, duration: s(1))
        try TimelineEditor.setTransition(fade, after: project.clips[0].id, in: &project)
        try TimelineEditor.split(at: s(2), in: &project)
        #expect(project.clips[0].outgoingTransition == nil)
        #expect(project.clips[1].outgoingTransition == fade)
    }

    // MARK: Trim

    @Test func trimLeadingAndTrailingEdges() throws {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.clips[0].id
        try TimelineEditor.trim(clip: id, edge: .leading, to: s(2), in: &project)
        try TimelineEditor.trim(clip: id, edge: .trailing, to: s(7), in: &project)
        #expect(project.clips[0].sourceRange == TimeRange(start: s(2), end: s(7)))
    }

    @Test func trimClampsToSourceBoundsAndMinimumDuration() throws {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.clips[0].id
        try TimelineEditor.trim(clip: id, edge: .leading, to: s(-3), in: &project)
        #expect(project.clips[0].sourceRange.start == .zero)
        try TimelineEditor.trim(clip: id, edge: .trailing, to: s(99), in: &project)
        #expect(project.clips[0].sourceRange.end == s(10))
        try TimelineEditor.trim(clip: id, edge: .leading, to: s(10), in: &project)
        #expect(project.clips[0].duration == TimelineEditor.minimumClipDuration)
    }

    @Test func trimSnapsToNearestFrame() throws {
        var project = Fixture.project(clipSeconds: [10])
        try TimelineEditor.trim(clip: project.clips[0].id, edge: .trailing, to: s(5.04), in: &project)
        #expect(project.clips[0].sourceRange.end == RationalTime(value: 151, timescale: 30))
    }

    @Test func trimShortensTransitionThatNoLongerFits() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(3)), after: project.clips[0].id, in: &project)
        try TimelineEditor.trim(clip: project.clips[0].id, edge: .leading, to: s(2), in: &project)   // clip A now 2 s
        #expect(project.clips[0].outgoingTransition?.duration == s(2))
    }

    // MARK: Delete & move

    @Test func deleteRemovesClipAndItsCuts() throws {
        var project = Fixture.project(clipSeconds: [2, 3, 4])
        let ids = project.clips.map(\.id)
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(1)), after: ids[0], in: &project)
        try TimelineEditor.delete(clips: [ids[1]], in: &project)
        #expect(project.clips.map(\.id) == [ids[0], ids[2]])
        #expect(project.clips[0].outgoingTransition == nil, "the A–B cut is gone, A–C is a new hard cut")
        #expect(project.sources.count == 2, "unused source is dropped")
    }

    @Test func deleteReturnsWhereTheTimelineClosesUp() throws {
        func join(deleting indices: Set<Int>, fadeAfterFirst: Bool = false) throws -> RationalTime {
            var project = Fixture.project(clipSeconds: [2, 3, 4, 5])
            let ids = project.clips.map(\.id)
            if fadeAfterFirst {
                try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(1)), after: ids[0], in: &project)
            }
            return try TimelineEditor.delete(clips: Set(indices.map { ids[$0] }), in: &project)
        }
        #expect(try join(deleting: [0]) == .zero)
        #expect(try join(deleting: [1]) == s(2))
        #expect(try join(deleting: [1, 2]) == s(2))
        #expect(try join(deleting: [1, 3]) == s(2), "the first of several gaps")
        #expect(try join(deleting: [3]) == s(9), "the end of the timeline")
        #expect(try join(deleting: [0, 1, 2, 3]) == .zero)
        // Earlier cross fades shorten the timeline; a deleted one doesn't.
        #expect(try join(deleting: [2], fadeAfterFirst: true) == s(4))
        #expect(try join(deleting: [1], fadeAfterFirst: true) == s(2))
    }

    @Test func deleteUnknownClipThrows() {
        var project = Fixture.project(clipSeconds: [2])
        #expect(throws: TimelineEditError.clipNotFound) { try TimelineEditor.delete(clips: [UUID()], in: &project) }
    }

    @Test func moveReordersAndKeepsSurvivingCuts() throws {
        var project = Fixture.project(clipSeconds: [2, 3, 4])
        let ids = project.clips.map(\.id)
        let fade = Transition(kind: .crossFade, duration: s(1))
        try TimelineEditor.setTransition(fade, after: ids[1], in: &project)   // B→C
        try TimelineEditor.move(clip: ids[0], to: 2, in: &project)              // B C A
        #expect(project.clips.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(project.clips[0].outgoingTransition == fade, "B→C still adjacent")
        #expect(project.clips[1].outgoingTransition == nil)

        try TimelineEditor.move(clip: ids[2], to: 0, in: &project)              // C B A
        #expect(project.clips.allSatisfy { $0.outgoingTransition == nil }, "B→C cut disappeared")
    }

    @Test func moveRejectsInvalidDestination() {
        var project = Fixture.project(clipSeconds: [2, 3])
        #expect(throws: TimelineEditError.indexOutOfRange) { try TimelineEditor.move(clip: project.clips[0].id, to: 2, in: &project) }
    }

    // MARK: Transitions

    @Test func transitionDurationIsClampedToNeighbours() throws {
        var project = Fixture.project(clipSeconds: [2, 10])
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(4)), after: project.clips[0].id, in: &project)
        #expect(project.clips[0].outgoingTransition?.duration == s(2))

        // A black fade uses only half its duration of each clip.
        try TimelineEditor.setTransition(Transition(kind: .blackFade, duration: s(5)), after: project.clips[0].id, in: &project)
        #expect(project.clips[0].outgoingTransition?.duration == s(4))
    }

    @Test func transitionsOnBothSidesShareTheClip() throws {
        var project = Fixture.project(clipSeconds: [10, 3, 10])
        let ids = project.clips.map(\.id)
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(2)), after: ids[0], in: &project)
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(2)), after: ids[1], in: &project)
        // Middle clip is 3 s: 2 s incoming leaves 1 s for the outgoing fade.
        #expect(project.clips[1].outgoingTransition?.duration == s(1))
    }

    @Test func transitionIsCappedAtMaximumAndRemovedBelowMinimum() throws {
        var project = Fixture.project(clipSeconds: [20, 20])
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(9)), after: project.clips[0].id, in: &project)
        #expect(project.clips[0].outgoingTransition?.duration == Transition.maximumDuration)

        var tight = Fixture.project(clipSeconds: [10, 10])
        try TimelineEditor.trim(clip: tight.clips[1].id, edge: .trailing, to: s(0.1), in: &tight)
        try TimelineEditor.setTransition(Transition(kind: .crossFade), after: tight.clips[0].id, in: &tight)
        #expect(tight.clips[0].outgoingTransition == nil, "0.1 s clip can't hold a 0.2 s transition")
    }

    @Test func lastClipCannotHaveTransition() {
        var project = Fixture.project(clipSeconds: [2, 3])
        #expect(throws: TimelineEditError.indexOutOfRange) {
            try TimelineEditor.setTransition(Transition(kind: .crossFade), after: project.clips[1].id, in: &project)
        }
    }

    // MARK: Format check

    @Test func formatDifferencesAreReported() {
        let reference = Fixture.source()
        #expect(Fixture.source().formatDifferences(comparedTo: reference).isEmpty)
        #expect(Fixture.source(codec: VideoCodec(rawValue: "avc3")).formatDifferences(comparedTo: reference).isEmpty)

        let other = Fixture.source(
            frameDuration: RationalTime(value: 1, timescale: 25),
            size: Size(width: 3840, height: 2160),
            codec: .hevc
        )
        #expect(other.formatDifferences(comparedTo: reference).count == 3)
    }

    @Test func rotatedSourceHasPortraitOrientedSize() {
        let rotated = Fixture.source(transform: Transform2D(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        #expect(rotated.orientedSize == Size(width: 1080, height: 1920))
    }
}
