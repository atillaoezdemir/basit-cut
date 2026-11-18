import SwiftUI
import BasitCutCore

/// Root view of a project window: preview, transport bar and timeline.
struct ProjectWindow: View {
    let document: ProjectDocument
    /// Document name, used as the default export file name.
    let name: String
    @State private var session: ProjectSession
    @Environment(\.undoManager) private var undoManager

    init(document: ProjectDocument, name: String) {
        self.document = document
        self.name = name
        _session = State(initialValue: ProjectSession(editor: document.editor))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.compositionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.yellow.opacity(0.25))
            }
            preview
            // An empty project shows only the import prompt.
            if !session.project.clips.isEmpty {
                Divider()
                TransportBar(session: session)
                Divider()
                TimelineView(session: session)
                    .frame(height: 130)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await session.importFiles(urls) }
            return true
        }
        .fileImporter(
            isPresented: $session.isImporterPresented,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await session.importFiles(urls) }
            }
        }
        .alert(
            session.alert?.title ?? "",
            isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } }),
            presenting: session.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .sheet(isPresented: $session.isExportPresented) {
            ExportSheet(session: session, defaultName: name)
        }
        .alert(
            "Different video format",
            isPresented: Binding(get: { session.pendingImport != nil }, set: { if !$0 { session.pendingImport = nil } }),
            presenting: session.pendingImport
        ) { pending in
            Button("Import All") { session.resolve(pending, includeDifferent: true) }
            if !pending.matching.isEmpty {
                Button("Skip Different Clips") { session.resolve(pending, includeDifferent: false) }
            }
            Button("Cancel", role: .cancel) { session.pendingImport = nil }
        } message: { pending in
            Text(pending.message)
        }
        .background(WindowAccessor { session.keyboard.attach(to: $0) })
        .focusedSceneValue(\.projectSession, session)
        .onAppear {
            document.editor.undoManager = undoManager
            session.start()
        }
        .onChange(of: undoManager) { _, newValue in document.editor.undoManager = newValue }
        .onChange(of: session.project) { session.projectDidChange() }
        .onDisappear { session.close() }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Color.black
            if session.project.clips.isEmpty {
                ContentUnavailableView {
                    Label("No Clips Yet", systemImage: "film.stack")
                } description: {
                    Text("Import videos or drop them here.")
                } actions: {
                    Button("Import Videos…") { session.isImporterPresented = true }
                }
                .colorScheme(.dark)
            } else {
                PlayerView(player: session.playback.player)
            }
            if session.isImporting {
                ProgressView("Importing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
