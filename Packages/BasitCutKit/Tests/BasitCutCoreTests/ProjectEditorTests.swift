import Foundation
import Testing
@testable import BasitCutCore

@MainActor
struct ProjectEditorTests {
    private func makeEditor(_ project: Project) -> (ProjectEditor, UndoManager) {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let editor = ProjectEditor(project: project)
        editor.undoManager = undoManager
        return (editor, undoManager)
    }

    private func step(_ undoManager: UndoManager, _ body: () throws -> Void) rethrows {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        try body()
    }

    @Test func undoAndRedoRestoreSnapshots() throws {
        let initial = Fixture.project(clipSeconds: [4, 6])
        let (editor, undoManager) = makeEditor(initial)

        try step(undoManager) { _ = try editor.perform("Split") { try TimelineEditor.split(at: s(2), in: &$0) } }
        let afterSplit = editor.project
        try step(undoManager) { try editor.perform("Delete") { try TimelineEditor.delete(clips: [afterSplit.clips[0].id], in: &$0) } }
        #expect(editor.project.clips.count == 2)
        #expect(undoManager.undoActionName == "Delete")

        undoManager.undo()
        #expect(editor.project == afterSplit)
        undoManager.undo()
        #expect(editor.project == initial)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(editor.project == afterSplit)
        #expect(undoManager.redoActionName == "Delete")
        undoManager.redo()
        #expect(editor.project.clips.count == 2)
    }

    @Test func failedOrNoOpEditsRegisterNothing() {
        let (editor, undoManager) = makeEditor(Fixture.project(clipSeconds: [4]))
        step(undoManager) {
            #expect(throws: TimelineEditError.self) {
                _ = try editor.perform("Split") { try TimelineEditor.split(at: s(99), in: &$0) }
            }
            editor.perform("Nothing") { _ in }
        }
        // The (empty) group itself stays on the stack; what matters is that no
        // undo action was registered inside it.
        #expect(undoManager.undoActionName.isEmpty)
        undoManager.undo()
        #expect(editor.project.clips.count == 1)
    }

    @Test func updateWithoutUndoSkipsUndoStack() {
        let (editor, undoManager) = makeEditor(Fixture.project(clipSeconds: [4]))
        editor.updateWithoutUndo { $0.sources[0].lastKnownPath = "/moved.mov" }
        #expect(editor.project.sources[0].lastKnownPath == "/moved.mov")
        #expect(!undoManager.canUndo)
    }

    @Test func currentSnapshotFollowsEditsAndUndo() async throws {
        let (editor, undoManager) = makeEditor(Fixture.project(clipSeconds: [4, 6]))
        try step(undoManager) { _ = try editor.perform("Split") { try TimelineEditor.split(at: s(2), in: &$0) } }
        // Read from a background task, the way AppKit autosave does.
        let afterSplit = await Task.detached { editor.currentSnapshot }.value
        #expect(afterSplit == editor.project)
        #expect(afterSplit.clips.count == 3)

        undoManager.undo()
        #expect(editor.currentSnapshot == editor.project)
        #expect(editor.currentSnapshot.clips.count == 2)
    }
}
