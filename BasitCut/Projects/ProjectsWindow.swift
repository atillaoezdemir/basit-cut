import AppKit
import SwiftUI
import BasitCutCore

/// The launch window: lists the projects in the projects folder and creates
/// new ones there, so no location ever has to be picked per project.
struct ProjectsWindow: View {
    static let id = "projects"

    @State private var folder = ProjectsFolder.shared
    @State private var selection: ProjectEntry.ID?
    @State private var isNamingNewProject = false
    @State private var newName = ""
    @State private var newAspectRatio: CropSetting.Mode = .original
    @State private var pendingTrash: ProjectEntry?
    @State private var errorMessage: String?
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if folder.url == nil {
                chooseFolderPrompt
            } else {
                projectList
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { folder.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            folder.refresh()
        }
        .onChange(of: folder.isNewProjectRequested, initial: true) { _, requested in
            guard requested else { return }
            folder.isNewProjectRequested = false
            startNewProject()
        }
        .sheet(isPresented: $isNamingNewProject) { newProjectSheet }
        .confirmationDialog(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingTrash { perform { try folder.moveToTrash(entry) } }
            }
        } message: {
            Text("Only the project is removed. Your video files are not touched.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: No folder yet

    private var chooseFolderPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Where should basit-cut keep your projects?")
                .font(.title3.bold())
            Text("Choose a folder once. New projects are created there and listed here. Projects only reference your videos; they don't copy them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Choose Folder…") { folder.choose() }
                .keyboardShortcut(.defaultAction)
            Button("Open a Project Elsewhere…") { NSDocumentController.shared.openDocument(nil) }
                .buttonStyle(.link)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Project list

    private var projectList: some View {
        VStack(spacing: 0) {
            if folder.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects Yet", systemImage: "film.stack")
                } description: {
                    Text("Create a project, then drop videos into its window.")
                } actions: {
                    Button("New Project…") { startNewProject() }
                }
            } else {
                List(folder.projects, selection: $selection) { entry in
                    ProjectRow(entry: entry) { pendingTrash = entry }
                }
                .contextMenu(forSelectionType: ProjectEntry.ID.self) { ids in
                    if let entry = entry(ids.first) {
                        Button("Open") { open(entry.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Divider()
                        Button("Move to Trash…") { pendingTrash = entry }
                    }
                } primaryAction: { ids in
                    // Double-click or Return.
                    if let entry = entry(ids.first) { open(entry.url) }
                }
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let url = folder.url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(url.lastPathComponent, systemImage: "folder")
                }
                .buttonStyle(.link)
                .help(url.path(percentEncoded: false))
            }
            Spacer()
            Button("Open Other…") { NSDocumentController.shared.openDocument(nil) }
            Button("New Project…") { startNewProject() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.title3.bold())
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createProject)
            VStack(alignment: .leading, spacing: 6) {
                Text("Aspect ratio")
                Picker("Aspect ratio", selection: $newAspectRatio) {
                    ForEach(CropSetting.Mode.allCases.filter { $0 != .free }, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Can be changed and positioned later with the Crop button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isNamingNewProject = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createProject)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: Actions

    private func entry(_ id: ProjectEntry.ID?) -> ProjectEntry? {
        folder.projects.first { $0.id == id }
    }

    private func startNewProject() {
        guard folder.url != nil || folder.choose() else { return }
        newName = folder.suggestedName()
        isNamingNewProject = true
    }

    private func createProject() {
        isNamingNewProject = false
        perform { open(try folder.createProject(named: newName, crop: newAspectRatio)) }
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: Self.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// One project in the list; a trash button appears while the pointer is over it.
private struct ProjectRow: View {
    let entry: ProjectEntry
    let onTrash: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            Image(systemName: "film.stack").foregroundStyle(.secondary)
            Text(entry.name)
            Spacer()
            Text(entry.modificationDate, format: .relative(presentation: .named))
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Move to Trash", systemImage: "trash", action: onTrash)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Move to Trash")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
