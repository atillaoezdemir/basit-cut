import Testing
@testable import BasitCutCore

struct TimelineLayoutTests {
    @Test func hardCutsPlaceClipsBackToBack() {
        let layout = TimelineLayout(project: Fixture.project(clipSeconds: [4, 6, 2]))
        #expect(layout.items.map(\.start) == [s(0), s(4), s(10)])
        #expect(layout.duration == s(12))
    }

    @Test func emptyProjectHasZeroDuration() {
        let layout = TimelineLayout(project: Project())
        #expect(layout.items.isEmpty)
        #expect(layout.duration == .zero)
        #expect(layout.item(at: .zero) == nil)
    }

    @Test func crossFadeOverlapsAndShortensTimeline() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(1)), after: project.clips[0].id, in: &project)
        let layout = TimelineLayout(project: project)
        #expect(layout.items[1].start == s(3))
        #expect(layout.items[0].outgoingOverlap == s(1))
        #expect(layout.items[1].incomingOverlap == s(1))
        #expect(layout.duration == s(9))
    }

    @Test func blackFadeKeepsTotalDuration() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        try TimelineEditor.setTransition(Transition(kind: .blackFade, duration: s(1)), after: project.clips[0].id, in: &project)
        let layout = TimelineLayout(project: project)
        #expect(layout.items[1].start == s(4))
        #expect(layout.duration == s(10))
    }

    @Test func itemLookup() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        let layout = TimelineLayout(project: project)
        #expect(layout.item(at: s(3.99))?.index == 0)
        #expect(layout.item(at: s(4))?.index == 1)
        #expect(layout.item(at: s(10)) == nil)
        #expect(layout.items[1].sourceTime(at: s(5.5)) == s(1.5))

        // During a cross fade the later clip wins.
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: s(1)), after: project.clips[0].id, in: &project)
        #expect(TimelineLayout(project: project).item(at: s(3.5))?.index == 1)
    }
}
