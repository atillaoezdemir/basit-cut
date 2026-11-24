import Testing
@testable import BasitCutCore

struct ComparisonSampleTests {
    @Test func emptyProjectHasNoSample() {
        #expect(ComparisonSample(project: Project()) == nil)
    }

    @Test func takesTenSecondsFromTheMiddleOfTheFirstSource() throws {
        let project = Fixture.project(clipSeconds: [60, 20])
        let sample = try #require(ComparisonSample(project: project))
        #expect(sample.sourceID == project.clips[0].sourceID)
        #expect(sample.range == TimeRange(start: s(25), end: s(35)))
    }

    @Test func shortSourcesAreUsedWhole() throws {
        let sample = try #require(ComparisonSample(project: Fixture.project(clipSeconds: [4])))
        #expect(sample.range == TimeRange(start: .zero, end: s(4)))
    }

    @Test func cuttingDoesNotChangeTheSampleButCroppingDoes() throws {
        var project = Fixture.project(clipSeconds: [60])
        let before = ComparisonSample(project: project)
        _ = try TimelineEditor.split(at: s(30), in: &project)
        try TimelineEditor.delete(clips: [project.clips[0].id], in: &project)
        #expect(ComparisonSample(project: project) == before)
        project.crop.mode = .ratio9x16
        #expect(ComparisonSample(project: project) != before)
    }

    @Test func sampleProjectIsOneUncutClipWithTheCrop() throws {
        var project = Fixture.project(clipSeconds: [60, 20])
        project.crop.mode = .ratio9x16
        let sample = try #require(ComparisonSample(project: project)?.project(from: project))
        #expect(sample.clips.map(\.duration) == [s(10)])
        #expect(sample.renderSize == project.renderSize)
    }
}
