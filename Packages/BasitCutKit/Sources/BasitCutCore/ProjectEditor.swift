import Foundation
import Observation

/// The single entry point for edits to a project.
///
/// Each edit applies a `TimelineEditor` operation to a copy of the project and
/// registers the previous snapshot with the `UndoManager`, so every edit can be
/// undone and redone. Registering with the document's undo manager is also what
/// marks the document as edited, which triggers autosave.
@MainActor
public final class ProjectEditor: Observable {
    // Observation is implemented by hand (instead of `@Observable`) so the
    // initializer can stay nonisolated: documents are decoded off the main actor.
    private let registrar = ObservationRegistrar()
    private var storage: Project

    public weak var undoManager: UndoManager?

    public nonisolated init(project: Project = Project()) {
        self.storage = project
    }

    public private(set) var project: Project {
        get {
            registrar.access(self, keyPath: \.project)
            return storage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.project) { storage = newValue }
        }
    }

    /// Applies `edit` as one undoable step named `actionName`. If `edit` throws
    /// or doesn't change anything, nothing is registered.
    @discardableResult
    public func perform<Result>(
        _ actionName: String,
        _ edit: (inout Project) throws -> Result
    ) rethrows -> Result {
        var updated = project
        let result = try edit(&updated)
        if updated != project {
            replace(with: updated, actionName: actionName)
        }
        return result
    }

    /// Replaces the project without an undo step, for bookkeeping that the user
    /// didn't initiate (e.g. refreshing stale bookmarks).
    public func updateWithoutUndo(_ change: (inout Project) -> Void) {
        change(&project)
    }

    private func replace(with newProject: Project, actionName: String) {
        let previous = project
        project = newProject
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                editor.replace(with: previous, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
