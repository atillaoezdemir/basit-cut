import SwiftUI

@main
struct BasitCutApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ProjectWindow(document: file.document)
        }
        .commands { ProjectCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands routed to the frontmost project window.
struct ProjectCommands: Commands {
    @FocusedValue(\.projectSession) private var session

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import Videos…") { session?.isImporterPresented = true }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(session == nil)
        }
        CommandMenu("Clip") {
            Button("Split at Playhead") { session?.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(session?.canSplit != true)
            Button("Delete Clip") { session?.deleteSelectedClip() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(session?.selectedClipID == nil)
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
