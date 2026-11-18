import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import BasitCutCore
import BasitCutMedia

/// A message shown in an alert.
struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Imported sources waiting for the user's decision because some of them
/// differ in format from the project.
struct PendingImport: Identifiable {
    let id = UUID()
    var sources: [MediaSource]
    /// The subset of `sources` that matches the project's format.
    var matching: [MediaSource]
    var insertionIndex: Int?
    var message: String
}

/// Everything one open project window needs: the editor (owned by the
/// document), resolved media, playback, selection and UI state.
///
/// Rebuilds the composition whenever the project changes, so the preview
/// always reflects the current edit.
@MainActor
@Observable
final class ProjectSession {
    let editor: ProjectEditor
    let library = MediaLibrary()
    let playback = PlaybackController()
    @ObservationIgnored private(set) lazy var keyboard = KeyboardController(playback: playback)

    var selectedClipID: Clip.ID?
    /// Timeline zoom.
    var pointsPerSecond: Double = 40
    var isImporterPresented = false
    private(set) var isImporting = false
    var alert: AppAlert?
    var pendingImport: PendingImport?
    private(set) var compositionError: String?

    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    static let zoomRange: ClosedRange<Double> = 2...400

    init(editor: ProjectEditor) {
        self.editor = editor
    }

    var project: Project { editor.project }

    // MARK: Lifecycle

    func start() {
        refreshLibrary()
        scheduleRebuild(delay: .zero)
    }

    func close() {
        rebuildTask?.cancel()
        keyboard.detach()
        playback.invalidate()
        library.close()
    }

    func projectDidChange() {
        if let selectedClipID, project.clipIndex(id: selectedClipID) == nil {
            self.selectedClipID = nil
        }
        refreshLibrary()
        scheduleRebuild()
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        var imported: [MediaSource] = []
        var failures: [String] = []
        for url in urls {
            if let existing = project.sources.first(where: { $0.lastKnownPath == url.path(percentEncoded: false) }),
               library.assets[existing.id] != nil {
                imported.append(existing)   // same file again: reuse the source
                continue
            }
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else {
                    throw AssetInspectionError.noVideoTrack(url.lastPathComponent)
                }
                let inspection = try await AssetInspector.inspect(url)
                let bookmark = try SecurityScopedBookmark.make(for: url)
                let source = MediaSource(url: url, bookmark: bookmark, inspection: inspection)
                library.register(source, url: url, accessing: accessing)
                imported.append(source)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                failures.append(error.localizedDescription)
            }
        }

        let insertionIndex = selectedClipID.flatMap { project.clipIndex(id: $0) }.map { $0 + 1 }
        let failureText = failures.joined(separator: "\n\n")
        let (matching, warnings) = formatCheck(for: imported)

        if !warnings.isEmpty {
            // Let the user decide before anything is added to the timeline.
            var message = "All clips in a project should share the same resolution, frame rate and codec.\n\n"
                + warnings.joined(separator: "\n")
            if !failures.isEmpty { message += "\n\nCouldn’t be imported:\n\n" + failureText }
            pendingImport = PendingImport(
                sources: imported, matching: matching, insertionIndex: insertionIndex, message: message
            )
            return
        }

        insert(imported, at: insertionIndex)
        if !failures.isEmpty {
            alert = AppAlert(
                title: failures.count == 1 ? "A file couldn’t be imported" : "\(failures.count) files couldn’t be imported",
                message: failureText
            )
        }
    }

    /// Resolves a pending import: inserts all sources, or only those that match.
    func resolve(_ pending: PendingImport, includeDifferent: Bool) {
        pendingImport = nil
        insert(includeDifferent ? pending.sources : pending.matching, at: pending.insertionIndex)
    }

    private func insert(_ sources: [MediaSource], at index: Int?) {
        guard !sources.isEmpty else { return }
        let ids = editor.perform(sources.count == 1 ? "Import Clip" : "Import Clips") { project in
            (try? TimelineEditor.insertClips(for: sources, at: index, in: &project)) ?? []
        }
        selectedClipID = ids.last
    }

    /// Compares new sources against the project's first clip (or the first new
    /// source). Returns the matching sources and one warning line per different one.
    private func formatCheck(for newSources: [MediaSource]) -> (matching: [MediaSource], warnings: [String]) {
        let reference = project.clips.first.flatMap { project.source(id: $0.sourceID) } ?? newSources.first
        guard let reference else { return (newSources, []) }
        var matching: [MediaSource] = []
        var warnings: [String] = []
        for source in newSources {
            let differences = source.formatDifferences(comparedTo: reference)
            if differences.isEmpty {
                matching.append(source)
            } else {
                warnings.append("• \(source.displayName): " + differences.map(Self.describe).joined(separator: ", "))
            }
        }
        return (matching, warnings)
    }

    private static func describe(_ difference: FormatDifference) -> String {
        switch difference {
        case .resolution(let expected, let actual):
            "\(Int(actual.width))×\(Int(actual.height)) instead of \(Int(expected.width))×\(Int(expected.height))"
        case .frameRate(let expected, let actual):
            String(format: "%.2f fps instead of %.2f fps", actual, expected)
        case .codec(let expected, let actual):
            "\(actual.family) instead of \(expected.family)"
        }
    }

    // MARK: Editing

    var canSplit: Bool {
        TimelineLayout(project: project).item(at: playheadTime) != nil
    }

    func splitAtPlayhead() {
        do {
            try editor.perform("Split Clip") { project in
                _ = try TimelineEditor.split(at: playheadTime, in: &project)
            }
        } catch TimelineEditError.splitTooCloseToEdge {
            NSSound.beep()
        } catch {
            NSSound.beep()
        }
    }

    func deleteSelectedClip() {
        guard let id = selectedClipID, let index = project.clipIndex(id: id) else { return }
        try? editor.perform("Delete Clip") { try TimelineEditor.delete(clips: [id], in: &$0) }
        let clips = project.clips
        selectedClipID = clips.isEmpty ? nil : clips[min(index, clips.count - 1)].id
    }

    func moveClip(_ id: Clip.ID, to destination: Int) {
        try? editor.perform("Move Clip") { try TimelineEditor.move(clip: id, to: destination, in: &$0) }
    }

    func trimClip(_ id: Clip.ID, edge: TimelineEditor.Edge, to sourceTime: RationalTime) {
        try? editor.perform("Trim Clip") { try TimelineEditor.trim(clip: id, edge: edge, to: sourceTime, in: &$0) }
    }

    /// The playhead as exact time (microsecond precision before frame snapping).
    var playheadTime: RationalTime {
        RationalTime(seconds: playback.displayTime, preferredTimescale: 1_000_000)
    }

    // MARK: Zoom

    func zoom(by factor: Double) {
        pointsPerSecond = min(max(pointsPerSecond * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    // MARK: Composition

    private func refreshLibrary() {
        let refreshed = library.resolve(project.sources)
        guard !refreshed.isEmpty else { return }
        editor.updateWithoutUndo { project in
            for index in project.sources.indices {
                if let bookmark = refreshed[project.sources[index].id] {
                    project.sources[index].bookmark = bookmark
                }
            }
        }
    }

    private func scheduleRebuild(delay: Duration = .milliseconds(100)) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        let project = self.project
        guard !project.clips.isEmpty else {
            compositionError = nil
            playback.load(nil)
            return
        }
        let missingNames = project.clips
            .compactMap { project.source(id: $0.sourceID) }
            .filter { library.missing.contains($0.id) }
            .map(\.displayName)
        guard missingNames.isEmpty else {
            compositionError = "Missing source files: " + Set(missingNames).sorted().joined(separator: ", ")
            playback.load(nil)
            return
        }
        let assets: [MediaSource.ID: AVAsset] = library.assets
        do {
            let built = try await CompositionBuilder.build(project: project, assets: assets)
            guard !Task.isCancelled, project == self.project else { return }
            compositionError = nil
            playback.load(built)
        } catch {
            guard !Task.isCancelled else { return }
            compositionError = error.localizedDescription
            playback.load(nil)
        }
    }
}

extension FocusedValues {
    /// The session of the frontmost project window, for menu commands.
    @Entry var projectSession: ProjectSession?
}
