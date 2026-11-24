import Foundation
import Testing
@testable import BasitCutCore

struct ExportPlanTests {
    private let portrait = Transform2D(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    private func project(_ sources: [MediaSource]) -> Project {
        var project = Project()
        try! TimelineEditor.insertClips(for: sources, in: &project)
        return project
    }

    @Test func emptyProjectThrows() {
        #expect(throws: ExportPlan.PlanError.emptyTimeline) {
            try ExportPlan.make(for: Project(), mode: .original)
        }
    }

    // MARK: Original

    @Test func originalWithoutTransitionsOrCropIsPassthrough() throws {
        let project = Fixture.project(clipSeconds: [4, 6])
        #expect(try ExportPlan.make(for: project, mode: .original) == .passthrough)
    }

    @Test func transitionForcesReencodeWithSourceSettings() throws {
        var project = project([Fixture.source(bitrate: 12_000_000), Fixture.source(bitrate: 12_000_000)])
        try TimelineEditor.setTransition(
            Transition(kind: .crossFade, duration: .seconds(1)), after: project.clips[0].id, in: &project
        )
        let plan = try ExportPlan.make(for: project, mode: .original)
        #expect(plan == .reencode(ExportSettings(
            codec: .h264,
            size: Size(width: 1920, height: 1080),
            frameDuration: Fixture.fps30,
            videoBitrate: 12_000_000,
            audioBitrate: ExportPlan.originalAudioBitrate
        )))
    }

    @Test func cropForcesReencode() throws {
        var project = Fixture.project(clipSeconds: [4])
        project.crop = CropSetting(mode: .free, rect: NormalizedRect(x: 0.2, y: 0, width: 0.6, height: 1))
        guard case .reencode = try ExportPlan.make(for: project, mode: .original) else {
            Issue.record("expected re-encode"); return
        }
    }

    @Test func mixedFormatsOrRotationsForceReencode() throws {
        let mixedSize = project([Fixture.source(), Fixture.source(size: Size(width: 1280, height: 720))])
        let mixedRotation = project([Fixture.source(), Fixture.source(transform: portrait)])
        let mixedRate = project([Fixture.source(), Fixture.source(frameDuration: RationalTime(value: 1, timescale: 25))])
        for project in [mixedSize, mixedRotation, mixedRate] {
            #expect(!ExportPlan.canPassthrough(project))
        }
    }

    @Test func originalKeepsHEVCAndMapsOtherCodecsToHEVC() throws {
        var hevc = project([Fixture.source(codec: .hevc)])
        hevc.crop.mode = .ratio16x9
        var prores = project([Fixture.source(codec: VideoCodec(rawValue: "apcn"))])
        prores.crop.mode = .ratio16x9
        for project in [hevc, prores] {
            guard case .reencode(let settings) = try ExportPlan.make(for: project, mode: .original) else {
                Issue.record("expected re-encode"); continue
            }
            #expect(settings.codec == .hevc)
        }
    }

    @Test func bitrateIsDurationWeighted() {
        // 30 s at 10 Mbps + 10 s at 2 Mbps = 8 Mbps average.
        let project = project([
            Fixture.source(seconds: 30, bitrate: 10_000_000),
            Fixture.source(seconds: 10, bitrate: 2_000_000),
        ])
        #expect(ExportPlan.averageBitrate(of: project) == 8_000_000)
    }

    @Test func unknownBitrateFallsBackToEstimate() throws {
        var project = project([Fixture.source(bitrate: 0)])
        project.crop.mode = .ratio16x9
        guard case .reencode(let settings) = try ExportPlan.make(for: project, mode: .original) else {
            Issue.record("expected re-encode"); return
        }
        // 1920 × 1080 × 30 fps × 0.1 bits per pixel.
        #expect(settings.videoBitrate == 6_220_800)
    }

    // MARK: Space saving

    @Test func spaceSavingIsHEVCWithCappedBitrate() throws {
        let plan = try ExportPlan.make(for: Fixture.project(clipSeconds: [4]), mode: .spaceSaving)
        #expect(plan == .reencode(ExportSettings(
            codec: .hevc,
            size: Size(width: 1920, height: 1080),
            frameDuration: Fixture.fps30,
            videoBitrate: 4_000_000,
            audioBitrate: 128_000
        )))
    }

    @Test func spaceSavingUsesLessForH264AndKeepsLowerHEVCBitrates() throws {
        func bitrate(_ sources: [MediaSource]) throws -> Int? {
            guard case .reencode(let settings) = try ExportPlan.make(for: project(sources), mode: .spaceSaving) else { return nil }
            return settings.videoBitrate
        }
        let h264 = Fixture.source(seconds: 10, bitrate: 2_500_000)
        let hevc = Fixture.source(seconds: 10, codec: .hevc, bitrate: 2_500_000)
        #expect(try bitrate([h264]) == 1_500_000)
        #expect(try bitrate([hevc]) == 2_500_000)
        #expect(try bitrate([h264, hevc]) == 2_000_000, "each source by its own codec")
        #expect(try bitrate([Fixture.source(bitrate: 6_000_000)]) == 3_600_000)
        #expect(try bitrate([Fixture.source(bitrate: 50_000_000)]) == 4_000_000, "still capped")
    }

    @Test func originalModeKeepsTheH264Bitrate() throws {
        var project = project([Fixture.source(bitrate: 2_500_000)])
        project.crop.mode = .ratio9x16
        guard case .reencode(let settings) = try ExportPlan.make(for: project, mode: .original) else {
            Issue.record("expected re-encode"); return
        }
        #expect(settings.videoBitrate == 2_500_000)
    }

    @Test func spaceSavingDownscales4KAndKeepsOrientation() throws {
        let landscape4K = project([Fixture.source(size: Size(width: 3840, height: 2160))])
        let portrait4K = project([Fixture.source(size: Size(width: 3840, height: 2160), transform: portrait)])
        let small = project([Fixture.source(size: Size(width: 1280, height: 720), transform: portrait)])

        func size(_ project: Project) throws -> Size? {
            guard case .reencode(let settings) = try ExportPlan.make(for: project, mode: .spaceSaving) else { return nil }
            return settings.size
        }
        #expect(try size(landscape4K) == Size(width: 1920, height: 1080))
        #expect(try size(portrait4K) == Size(width: 1080, height: 1920))
        #expect(try size(small) == Size(width: 720, height: 1280))
    }

    @Test func fittingKeepsEvenDimensions() {
        // 4:3 at 2880×2160 → limited by the short edge to 1440×1080.
        #expect(ExportPlan.fitted(Size(width: 2880, height: 2160), within: ExportPlan.spaceSavingMaxSize)
            == Size(width: 1440, height: 1080))
        // An odd result is rounded to even.
        #expect(ExportPlan.fitted(Size(width: 3000, height: 1999), within: ExportPlan.spaceSavingMaxSize)
            == Size(width: 1620, height: 1080))
    }
}
