import Foundation
import Testing
@testable import BasitCutCore

struct RelinkTests {
    @Test func relinkKeepsTheSourceIDAndClips() throws {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.sources[0].id
        var replacement = Fixture.source(seconds: 10)
        replacement.lastKnownPath = "/Volumes/Archive/clip.mov"

        let differences = try TimelineEditor.relink(source: id, to: replacement, in: &project)

        #expect(differences.isEmpty)
        #expect(project.sources.count == 1)
        #expect(project.sources[0].id == id)
        #expect(project.sources[0].lastKnownPath == "/Volumes/Archive/clip.mov")
        #expect(project.clips[0].sourceID == id)
    }

    @Test func rejectsAFileShorterThanTheUsedPart() throws {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.sources[0].id
        try TimelineEditor.trim(clip: project.clips[0].id, edge: .trailing, to: .seconds(6), in: &project)
        let before = project

        #expect(throws: RelinkError.self) {
            try TimelineEditor.relink(source: id, to: Fixture.source(seconds: 5), in: &project)
        }
        #expect(project == before)
        // Longer than the used part is fine (the end was trimmed away).
        try TimelineEditor.relink(source: id, to: Fixture.source(seconds: 7), in: &project)
    }

    @Test func coverFrameCountsAsUsed() {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.sources[0].id
        project.clips[0].sourceRange = TimeRange(start: .zero, duration: .seconds(2))
        project.cover = CoverFrame(sourceID: id, time: .seconds(8))
        #expect(TimelineEditor.requiredDuration(of: id, in: project) == .seconds(8))
    }

    @Test func reportsFormatDifferences() throws {
        var project = Fixture.project(clipSeconds: [10])
        let id = project.sources[0].id
        let differences = try TimelineEditor.relink(
            source: id, to: Fixture.source(seconds: 10, size: Size(width: 1280, height: 720)), in: &project
        )
        #expect(differences.count == 1)
    }

    @Test func matchesOtherMissingFilesByName() {
        var a = Fixture.source(); a.lastKnownPath = "/old/a.mov"
        var b = Fixture.source(); b.lastKnownPath = "/old/b.mov"
        let matches = TimelineEditor.relinkCandidates(for: [a, b], among: ["b.mov", "c.mov"])
        #expect(matches == [b.id: "b.mov"])
    }
}
