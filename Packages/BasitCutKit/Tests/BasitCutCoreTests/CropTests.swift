import Testing
@testable import BasitCutCore

struct CropTests {
    let landscape = Size(width: 1920, height: 1080)

    private func pixelRatio(_ rect: NormalizedRect, _ canvas: Size) -> Double {
        rect.width * canvas.width / (rect.height * canvas.height)
    }

    @Test func fixedRatiosGetTheLargestCenteredRect() {
        let square = CropGeometry.setting(for: .ratio1x1, canvas: landscape).rect
        #expect(abs(pixelRatio(square, landscape) - 1) < 1e-9)
        #expect(square.height == 1)
        #expect(abs(square.midX - 0.5) < 1e-9)

        let portrait = CropGeometry.setting(for: .ratio9x16, canvas: landscape).rect
        #expect(abs(pixelRatio(portrait, landscape) - 9.0 / 16) < 1e-9)
        #expect(portrait.height == 1)

        // 16:9 on a portrait canvas is limited by the width.
        let canvas = Size(width: 1080, height: 1920)
        let wide = CropGeometry.setting(for: .ratio16x9, canvas: canvas).rect
        #expect(wide.width == 1)
        #expect(abs(pixelRatio(wide, canvas) - 16.0 / 9) < 1e-9)
        #expect(abs(wide.midY - 0.5) < 1e-9)
    }

    @Test func movingStaysInsideTheFrame() {
        let rect = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        #expect(CropGeometry.moved(rect, dx: 1, dy: -1) == NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test func resizingKeepsTheOppositeCornerAndTheRatio() {
        let start = CropGeometry.setting(for: .ratio1x1, canvas: landscape).rect
        let resized = CropGeometry.resized(start, corner: .bottomTrailing, to: (x: 0.5, y: 0.5), mode: .ratio1x1, canvas: landscape)
        #expect(resized.x == start.x && resized.y == start.y)
        #expect(abs(pixelRatio(resized, landscape) - 1) < 1e-9)
        #expect(resized.maxX <= 1 && resized.maxY <= 1)
    }

    @Test func freeResizeIsClampedToFrameAndMinimum() {
        let rect = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let bigger = CropGeometry.resized(rect, corner: .bottomTrailing, to: (x: 2, y: 0.9), mode: .free, canvas: landscape)
        #expect(bigger == NormalizedRect(x: 0.2, y: 0.2, width: 0.8, height: 0.7))
        let tiny = CropGeometry.resized(rect, corner: .topLeading, to: (x: 0.69, y: 0.69), mode: .free, canvas: landscape)
        #expect(abs(tiny.width - CropGeometry.minimumSide) < 1e-9)
        #expect(abs(tiny.maxX - 0.7) < 1e-9)
    }

    @Test func renderSizeFollowsTheCropWithEvenPixels() {
        var project = Fixture.project(clipSeconds: [5])
        #expect(project.renderSize == Size(width: 1920, height: 1080))
        project.crop = CropGeometry.setting(for: .ratio9x16, canvas: landscape)
        let size = try! #require(project.renderSize)
        #expect(size.height == 1080)
        #expect(size.width == 608)   // 1080 × 9/16 = 607.5 → even
        let rect = try! #require(project.cropRect)
        #expect(rect.x + rect.width <= 1920)
    }

    @Test func modeChosenBeforeAnyClipAdaptsToTheFirstClip() {
        // A new project may get 1:1 before it has clips; the rect is then .full.
        var project = Fixture.project(clipSeconds: [5])
        project.crop = CropSetting(mode: .ratio1x1)
        #expect(project.renderSize == Size(width: 1080, height: 1080))
    }

    @Test func cropDisablesPassthrough() {
        var project = Fixture.project(clipSeconds: [5])
        #expect(ExportPlan.canPassthrough(project))
        project.crop = CropGeometry.setting(for: .ratio1x1, canvas: landscape)
        #expect(!ExportPlan.canPassthrough(project))
    }

    @Test func coverFrameIsTheSourceFrameAtTheTime() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        try TimelineEditor.trim(clip: project.clips[1].id, edge: .leading, to: s(1), in: &project)
        let cover = try #require(TimelineEditor.coverFrame(at: s(5.5), in: project))
        #expect(cover.sourceID == project.clips[1].sourceID)
        #expect(cover.time == s(2.5))
        // At the end of the timeline: the last frame.
        let end = try #require(TimelineEditor.coverFrame(at: TimelineLayout(project: project).duration, in: project))
        #expect(end.time == s(6) - Fixture.fps30)
    }
}
