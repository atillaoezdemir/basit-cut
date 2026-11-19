import SwiftUI
import BasitCutCore

@main
struct BasitCutApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Projects are created from the Projects window, inside the projects
        // folder, so no untitled document or open panel appears at launch.
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ProjectWindow(
                document: file.document,
                name: file.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
            )
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            ProjectCommands()
            FileCommands()
        }

        Window("Projects", id: ProjectsWindow.id) {
            ProjectsWindow()
        }
        .defaultSize(width: 520, height: 420)
        .defaultLaunchBehavior(.presented)

        Settings {
            SettingsView()
        }
    }
}

/// Shows the Projects window instead of an untitled document or an open
/// panel when the Dock icon is clicked with no windows open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `FileCommands`, which has access to SwiftUI's `openWindow`.
    @MainActor static var showProjects: (() -> Void)?

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showProjects?() }
        return false
    }
}

/// File menu: new projects go into the projects folder.
struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let showProjects = { openWindow(id: ProjectsWindow.id) }
        let _ = (AppDelegate.showProjects = showProjects)
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                showProjects()
                ProjectsFolder.shared.isNewProjectRequested = true
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Show Projects") { showProjects() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

/// Menu commands routed to the frontmost project window.
struct ProjectCommands: Commands {
    @FocusedValue(\.projectSession) private var session

    private func setTransition(_ kind: Transition.Kind?) {
        guard let session, let id = session.clipBeforeSelectedCut else { return }
        session.setTransitionKind(kind, after: id)
    }

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import Videos…") { session?.isImporterPresented = true }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(session == nil)
            Button("Export…") { session?.showExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session?.canExport != true)
        }
        CommandMenu("Clip") {
            Button("Split at Playhead") { session?.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(session?.canSplit != true)
            Button("Delete Clip") { session?.deleteSelectedClip() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(session?.selectedClipID == nil)
            Divider()
            // These act on the cut after the selected clip.
            Button("Cross Fade to Next Clip") { setTransition(.crossFade) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.clipBeforeSelectedCut == nil)
            Button("Black Fade to Next Clip") { setTransition(.blackFade) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(session?.clipBeforeSelectedCut == nil)
            Button("Remove Transition") { setTransition(nil) }
                .disabled(session?.clipBeforeSelectedCut.flatMap { id in
                    session?.project.clips.first { $0.id == id }?.outgoingTransition
                } == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { session?.zoom(by: 1.5) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { session?.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Divider()
        }
    }
}
