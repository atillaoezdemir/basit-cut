import AVFoundation
import Foundation
import Testing
import BasitCutCore
@testable import BasitCutMedia

struct CompositionBuilderTests {
    let directory: URL

    init() throws { directory = try TestVideoGenerator.makeTemporaryDirectory() }

    /// Generates a file, inspects it and returns it as a project source plus asset.
    private func makeSource(_ spec: TestVideoGenerator.Spec) async throws -> (MediaSource, AVAsset) {
        let url = try await TestVideoGenerator.makeVideo(spec, in: directory)
        let source = MediaSource(url: url, bookmark: Data(), inspection: try await AssetInspector.inspect(url))
        return (source, AVURLAsset(url: url))
    }

    @Test func compositionDurationMatchesLayoutAfterEdits() async throws {
        let (a, assetA) = try await makeSource(.init(seconds: 2))
        let (b, assetB) = try await makeSource(.init(seconds: 3))
        var project = Project()
        try TimelineEditor.insertClips(for: [a, b], in: &project)
        try TimelineEditor.split(at: RationalTime(seconds: 1), in: &project)
        try TimelineEditor.trim(clip: project.clips[2].id, edge: .leading, to: RationalTime(seconds: 0.5), in: &project)

        let built = try await CompositionBuilder.build(project: project, assets: [a.id: assetA, b.id: assetB])
        let layout = TimelineLayout(project: project)

        #expect(abs(built.composition.duration.seconds - layout.duration.seconds) < 0.05)
        #expect(built.renderSize == CGSize(width: 320, height: 180))
        #expect(built.videoComposition.instructions.count == 3)
        #expect(built.composition.tracks(withMediaType: .audio).isEmpty == false)
        #expect(built.videoComposition.frameDuration == CMTime(value: 1, timescale: 30))
    }

    @Test func instructionsCoverTimelineWithoutGaps() async throws {
        let (a, asset) = try await makeSource(.init(seconds: 2, withAudio: false))
        var project = Project()
        try TimelineEditor.insertClips(for: [a, a, a], in: &project)
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: .seconds(1)), after: project.clips[0].id, in: &project)

        let built = try await CompositionBuilder.build(project: project, assets: [a.id: asset])
        let ranges = built.videoComposition.instructions.map(\.timeRange)
        #expect(ranges.first?.start == .zero)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.end == next.start)
        }
        #expect(ranges.last?.end == TimelineLayout(project: project).duration.cmTime)
        // A, A+B overlap, B, C
        #expect(ranges.count == 4)
        #expect((built.videoComposition.instructions[1] as? AVVideoCompositionInstruction)?.layerInstructions.count == 2)
    }

    @Test func portraitSourceRendersUpright() async throws {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let (source, asset) = try await makeSource(.init(transform: rotate90, withAudio: false))
        var project = Project()
        try TimelineEditor.insertClips(for: [source], in: &project)

        let built = try await CompositionBuilder.build(project: project, assets: [source.id: asset])
        #expect(built.renderSize == CGSize(width: 180, height: 320))

        let transform = CompositionBuilder.layerTransform(for: source, renderSize: built.renderSize)
        let mapped = CGRect(x: 0, y: 0, width: 320, height: 180).applying(transform)
        #expect(mapped.integral == CGRect(x: 0, y: 0, width: 180, height: 320))
    }

    @Test func mismatchedSourceIsFittedIntoRenderSize() async throws {
        let (small, _) = try await makeSource(.init(width: 160, height: 90, withAudio: false))
        let transform = CompositionBuilder.layerTransform(for: small, renderSize: CGSize(width: 320, height: 320))
        let mapped = CGRect(x: 0, y: 0, width: 160, height: 90).applying(transform)
        #expect(mapped == CGRect(x: 0, y: 70, width: 320, height: 180))
    }

    @Test func emptyOrMissingSourcesThrow() async throws {
        await #expect(throws: CompositionError.emptyTimeline) {
            try await CompositionBuilder.build(project: Project(), assets: [:])
        }
        let (source, _) = try await makeSource(.init(seconds: 0.5, withAudio: false))
        var project = Project()
        try TimelineEditor.insertClips(for: [source], in: &project)
        await #expect(throws: CompositionError.missingSource(source.displayName)) {
            try await CompositionBuilder.build(project: project, assets: [:])
        }
    }
}
