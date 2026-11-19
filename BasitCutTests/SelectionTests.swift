import Foundation
import Testing
import BasitCutCore
@testable import BasitCut

@MainActor
struct SelectionTests {
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

    @Test func oneSelectedClipTargetsTheCutAfterIt() throws {
        let session = try session(clips: 3)
        session.selectedClipID = session.project.clips[1].id
        #expect(session.selectedCuts == [session.project.clips[1].id])
        session.selectedClipID = session.project.clips[2].id
        #expect(session.selectedCuts.isEmpty, "the last clip has no cut after it")
    }

    @Test func selectAllThenCrossFadeFillsEveryCutInOneUndoStep() throws {
        let session = try session(clips: 4)
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.editor.undoManager = undo
        session.selectAllClips()
        undo.beginUndoGrouping()
        session.setTransitionKindForSelectedCuts(.crossFade)
        undo.endUndoGrouping()

        let transitions = session.project.clips.map(\.outgoingTransition?.kind)
        #expect(transitions == [.crossFade, .crossFade, .crossFade, nil])
        #expect(session.selectedCutsHaveTransition)

        undo.undo()
        #expect(session.project.clips.allSatisfy { $0.outgoingTransition == nil })
    }

    @Test func onlyCutsBetweenSelectedClipsAreTargeted() throws {
        let session = try session(clips: 4)
        let ids = session.project.clips.map(\.id)
        session.selection = [ids[0], ids[1], ids[3]]
        #expect(session.selectedCuts == [ids[0]])
    }
}
