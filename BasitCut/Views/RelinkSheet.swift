import AppKit
import SwiftUI
import BasitCutCore

/// Lists the project's missing source files and lets the user find them:
/// one by one, or by choosing a folder that is searched for all of them.
struct RelinkSheet: View {
    let session: ProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var errors: [MediaSource.ID: String] = [:]
    @State private var notes: [String] = []
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "questionmark.folder")
                .font(.headline)
            Text("The project only refers to its videos. If they were moved, renamed or are on a disconnected drive, show basit-cut where they are now. Nothing is lost in the meantime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if missing.isEmpty {
                Label("All files are found.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.vertical, 8)
            } else {
                List(missing) { source in
                    row(for: source)
                }
                .listStyle(.bordered)
                .frame(minHeight: 120, maxHeight: 260)
            }

            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !missing.isEmpty {
                    Button("Search Folder…") { searchFolder() }
                        .help("Choose a folder; files with the same names are relinked")
                }
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button(missing.isEmpty ? "Done" : "Later") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isWorking)
        }
        .padding(20)
        .frame(width: 560)
    }

    private var missing: [MediaSource] { session.missingSources }

    private var title: String {
        switch missing.count {
        case 0: "Files Found"
        case 1: "A Video File Is Missing"
        default: "\(missing.count) Video Files Are Missing"
        }
    }

    private func row(for source: MediaSource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(URL(filePath: source.lastKnownPath).deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = errors[source.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Locate…") { locate(source) }
                .disabled(isWorking)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func locate(_ source: MediaSource) {
        let panel = NSOpenPanel()
        panel.title = "Locate “\(source.displayName)”"
        panel.prompt = "Relink"
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = startDirectory(for: source)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            errors[source.id] = nil
            do {
                if let warning = try await session.relink(source, to: url) { notes.append(warning) }
            } catch {
                errors[source.id] = error.localizedDescription
            }
        }
    }

    private func searchFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Folder with the Missing Videos"
        panel.prompt = "Search"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = missing.first.map(startDirectory(for:))
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run {
            let result = await session.relinkMissing(in: folder)
            notes.append(contentsOf: result.problems)
            if result.relinked == 0 && result.problems.isEmpty {
                notes.append("No files with the missing names were found in “\(folder.lastPathComponent)”.")
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    /// The file's old folder if it still exists, else ~/Movies.
    private func startDirectory(for source: MediaSource) -> URL {
        let folder = URL(filePath: source.lastKnownPath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { return folder }
        // The sandbox reports the container as home; use the real ~/Movies.
        return URL(filePath: "/Users/\(NSUserName())/Movies", directoryHint: .isDirectory)
    }
}
