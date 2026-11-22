import Testing
@testable import BasitCutCore

struct EnvelopeTests {
    private func envelopes(_ project: Project) -> [ClipEnvelopes] {
        let layout = TimelineLayout(project: project)
        return layout.items.map { layout.envelopes(for: $0) }
    }

    private func project(_ seconds: [Int64], transitions: [Transition?]) throws -> Project {
        var project = Fixture.project(clipSeconds: seconds)
        for (index, transition) in transitions.enumerated() {
            try TimelineEditor.setTransition(transition, after: project.clips[index].id, in: &project)
        }
        return project
    }

    @Test func singleClipHasNoFades() throws {
        let clip = envelopes(Fixture.project(clipSeconds: [5]))[0]
        #expect(clip.opacity == Envelope())
        #expect(clip.volume == Envelope())
    }

    @Test func hardCutFadesOnlyTheAudioBriefly() throws {
        let clips = envelopes(Fixture.project(clipSeconds: [4, 6]))
        #expect(clips[0].opacity.ramps.isEmpty)
        #expect(clips[1].opacity.ramps.isEmpty)
        #expect(clips[1].opacity.initialValue == 1)

        let fade = TimelineLayout.hardCutAudioFade
        #expect(clips[0].volume.ramps == [Ramp(range: TimeRange(start: s(4) - fade, end: s(4)), from: 1, to: 0)])
        #expect(clips[1].volume.ramps == [Ramp(range: TimeRange(start: s(4), duration: fade), from: 0, to: 1)])
        #expect(clips[1].volume.value(at: s(4)) == 0)
        #expect(clips[1].volume.value(at: s(5)) == 1)
    }

    @Test func crossFadeDissolvesTheIncomingClipOverTheOutgoing() throws {
        let clips = envelopes(try project([4, 6], transitions: [Transition(kind: .crossFade, duration: s(1))]))
        let overlap = TimeRange(start: s(3), end: s(4))
        // Outgoing stays opaque underneath, incoming fades in on top.
        #expect(clips[0].opacity.ramps.isEmpty)
        #expect(clips[1].opacity.ramps == Ramp.smooth(over: overlap, from: 0, to: 1))
        #expect(clips[1].opacity.value(at: s(3)) == 0)
        #expect(clips[1].opacity.value(at: s(3.5)) == 0.5)
        #expect(clips[1].opacity.value(at: s(4)) == 1)
        // Ease in-out: slower than linear near the ends.
        #expect(clips[1].opacity.value(at: s(3.125)) < 0.125)
        // Audio crossfades over the same range.
        #expect(clips[0].volume.ramps == Ramp.equalPower(over: overlap, fadeIn: false))
        #expect(clips[1].volume.ramps == Ramp.equalPower(over: overlap, fadeIn: true))
        // Equal power: no loudness dip in the middle (gains squared sum to 1).
        for t in stride(from: 3.0, through: 4.0, by: 0.125) {
            let a = clips[0].volume.value(at: s(t)), b = clips[1].volume.value(at: s(t))
            let power = a * a + b * b
            #expect(abs(power - 1) < 1e-9)
        }
        #expect(clips[0].volume.value(at: s(4)) == 0)
        #expect(clips[1].volume.value(at: s(4)) == 1)
    }

    @Test func blackFadeSplitsItsDurationBetweenTheClips() throws {
        let clips = envelopes(try project([4, 6], transitions: [Transition(kind: .blackFade, duration: s(2))]))
        let out = TimeRange(start: s(3), end: s(4))
        let into = TimeRange(start: s(4), end: s(5))
        let floor = TimelineLayout.blackFadeFloor
        #expect(clips[0].opacity.ramps == Ramp.smooth(over: out, from: 1, to: floor))
        #expect(clips[0].volume.ramps == Ramp.equalPower(over: out, fadeIn: false))
        #expect(clips[1].opacity.initialValue == floor)
        #expect(clips[1].opacity.ramps == Ramp.smooth(over: into, from: floor, to: 1))
        #expect(clips[1].volume.ramps == Ramp.equalPower(over: into, fadeIn: true))
        // At the cut the picture is dimmed (not black) and the sound silent.
        #expect(abs(clips[0].opacity.value(at: s(4)) - floor) < 1e-9)
        #expect(abs(clips[1].opacity.value(at: s(4)) - floor) < 1e-9)
        #expect(clips[1].volume.value(at: s(4)) == 0)
    }

    @Test func blackFadeCrossfadesTheSoundWhenTheSourcesReachAcrossTheCut() throws {
        // One 10 s source split at 4 s: both clips have material beyond the cut.
        var project = Fixture.project(clipSeconds: [10])
        _ = try TimelineEditor.split(at: s(4), in: &project)
        try TimelineEditor.setTransition(Transition(kind: .blackFade, duration: s(2)), after: project.clips[0].id, in: &project)
        let layout = TimelineLayout(project: project)
        #expect(layout.items[0].audioTail == s(1))
        #expect(layout.items[1].audioLeadIn == s(1))
        #expect(layout.items[0].audioRange == TimeRange(start: s(0), end: s(5)))
        #expect(layout.items[1].audioSourceRange == TimeRange(start: s(3), end: s(10)))
        #expect(layout.duration == s(10))   // the picture timing doesn't change

        let clips = layout.items.map { layout.envelopes(for: $0) }
        let both = TimeRange(start: s(3), end: s(5))
        #expect(clips[0].volume.ramps == Ramp.equalPower(over: both, fadeIn: false))
        #expect(clips[1].volume.ramps == Ramp.equalPower(over: both, fadeIn: true))
        // No silence at the cut: equal power across the whole transition.
        for t in stride(from: 3.0, through: 5.0, by: 0.25) {
            let a = clips[0].volume.value(at: s(t)), b = clips[1].volume.value(at: s(t))
            #expect(abs(a * a + b * b - 1) < 1e-9)
        }
        // The picture still dips to the floor at the cut.
        #expect(abs(clips[1].opacity.value(at: s(4)) - TimelineLayout.blackFadeFloor) < 1e-9)
    }

    @Test func blackFadeUsesOnlyTheSourceMaterialThereIs() throws {
        // Clip A ends 0.4 s before its source does; clip B starts at its source's start.
        var project = Fixture.project(clipSeconds: [10, 6])
        _ = try TimelineEditor.split(at: s(9.6), in: &project)
        try TimelineEditor.delete(clips: [project.clips[1].id], in: &project)
        try TimelineEditor.setTransition(Transition(kind: .blackFade, duration: s(2)), after: project.clips[0].id, in: &project)
        let layout = TimelineLayout(project: project)
        #expect(layout.items[0].audioTail == s(0.4))
        #expect(layout.items[1].audioLeadIn == .zero)
        let clips = layout.items.map { layout.envelopes(for: $0) }
        #expect(clips[0].volume.ramps == Ramp.equalPower(over: TimeRange(start: s(8.6), end: s(10)), fadeIn: false))
        #expect(clips[1].volume.ramps == Ramp.equalPower(over: TimeRange(start: s(9.6), end: s(10.6)), fadeIn: true))
    }

    @Test func middleClipFadesInAndOut() throws {
        let clips = envelopes(try project([4, 4, 4], transitions: [
            Transition(kind: .crossFade, duration: s(1)),
            Transition(kind: .blackFade, duration: s(1)),
        ]))
        let middle = clips[1]
        #expect(middle.opacity.initialValue == 0)
        #expect(middle.opacity.value(at: s(5)) == 1)
        #expect(middle.opacity.value(at: s(6.75)) < 1)   // dims towards the black fade
        // Ramps are sorted and don't overlap.
        for ramps in [middle.opacity.ramps, middle.volume.ramps] {
            for (a, b) in zip(ramps, ramps.dropFirst()) { #expect(a.range.end <= b.range.start) }
        }
    }

    @Test func rampsAreCutToAWindowWithInterpolatedValues() {
        let envelope = Envelope(initialValue: 0, ramps: [Ramp(range: TimeRange(start: s(0), end: s(2)), from: 0, to: 1)])
        let cut = envelope.ramps(in: TimeRange(start: s(1), end: s(5)))
        #expect(cut == [Ramp(range: TimeRange(start: s(1), end: s(2)), from: 0.5, to: 1)])
        #expect(envelope.ramps(in: TimeRange(start: s(3), end: s(4))).isEmpty)
        #expect(envelope.value(at: s(3)) == 1)
    }
}
