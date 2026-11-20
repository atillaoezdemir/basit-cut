import Foundation
import Testing
import BasitCutCore
@testable import BasitCut

@MainActor
struct ZoomTests {
    private func session(clips: Int) throws -> ProjectSession {
        var project = Project()
        let source = MediaSource(
            bookmark: Data(), lastKnownPath: "/Videos/clip.mov", duration: .seconds(10),
            frameDuration: RationalTime(value: 1, timescale: 30), naturalSize: Size(width: 1920, height: 1080),
            codec: .h264, videoBitrate: 10_000_000, hasAudio: true
        )
        try TimelineEditor.insertClips(for: Array(repeating: source, count: clips), in: &project)
        return ProjectSession(editor: ProjectEditor(project: project))
    }

    @Test func lowestZoomFitsTheWholeTimeline() throws {
        let session = try session(clips: 10)          // 100 s
        session.setTimelineWidth(816)
        session.setZoom(0)
        #expect(abs(session.pointsPerSecond * 100 - 800) < 0.001)
    }

    @Test func fittedZoomFollowsTheWidthAndLength() throws {
        let session = try session(clips: 10)
        session.setTimelineWidth(816)
        session.setZoom(0)
        session.setTimelineWidth(416)
        #expect(abs(session.pointsPerSecond * 100 - 400) < 0.001)

        session.selectedClipID = session.project.clips[0].id
        session.deleteSelectedClips()                   // 90 s
        session.projectDidChange()
        #expect(abs(session.pointsPerSecond * 90 - 400) < 0.001)
    }

    @Test func otherZoomsStayPut() throws {
        let session = try session(clips: 10)
        session.setTimelineWidth(816)
        session.setZoom(50)
        session.setTimelineWidth(1200)
        #expect(session.pointsPerSecond == 50)
    }
}
