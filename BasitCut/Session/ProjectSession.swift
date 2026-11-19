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
    let export = ExportController()
    @ObservationIgnored private(set) lazy var keyboard: KeyboardController = {
        let keyboard = KeyboardController(playback: playback)
        keyboard.onSelectAll = { [weak self] in self?.selectAllClips() }
        return keyboard
    }()

    /// Selected clips. A click selects one, ⌘-click adds or removes, ⌘A selects all.
    var selection: Set<Clip.ID> = []

    /// The selected clip when exactly one is selected.
    var selectedClipID: Clip.ID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    /// Timeline zoom.
    var pointsPerSecond: Double = 40
    var isImporterPresented = false
    var isExportPresented = false
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
        export.cancel()
        keyboard.detach()
        playback.invalidate()
        library.close()
    }

    func projectDidChange() {
        let existing = Set(project.clips.map(\.id))
        if !selection.isSubset(of: existing) {
            selection.formIntersection(existing)
        }
        refreshLibrary()
        scheduleRebuild()
    }

    // MARK: Export

    var canExport: Bool { !project.clips.isEmpty }

    func showExport() {
        guard canExport else { return }
        playback.pause()
        isExportPresented = true
    }

    /// Exports the current project. Missing source files are reported before
    /// anything is written.
    func startExport(to url: URL) {
        let missingNames = project.sources
            .filter { source in project.clips.contains { $0.sourceID == source.id } && library.assets[source.id] == nil }
            .map(\.displayName)
        guard missingNames.isEmpty else {
            isExportPresented = false
            alert = AppAlert(
                title: "Missing source files",
                message: "These files can’t be found, so the project can’t be exported:\n\n"
                    + missingNames.joined(separator: "\n")
            )
            return
        }
        export.start(project: project, assets: library.assets, to: url)
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

        // After the last selected clip, or at the end.
        let insertionIndex = project.clips.lastIndex { selection.contains($0.id) }.map { $0 + 1 }
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

    func deleteSelectedClips() {
        guard let index = project.clips.firstIndex(where: { selection.contains($0.id) }) else { return }
        let ids = selection
        try? editor.perform(ids.count == 1 ? "Delete Clip" : "Delete Clips") { try TimelineEditor.delete(clips: ids, in: &$0) }
        let clips = project.clips
        selectedClipID = clips.isEmpty ? nil : clips[min(index, clips.count - 1)].id
    }

    func selectAllClips() {
        selection = Set(project.clips.map(\.id))
    }

    /// ⌘-click: adds the clip to the selection or removes it.
    func toggleSelection(_ id: Clip.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func moveClip(_ id: Clip.ID, to destination: Int) {
        try? editor.perform("Move Clip") { try TimelineEditor.move(clip: id, to: destination, in: &$0) }
    }

    func trimClip(_ id: Clip.ID, edge: TimelineEditor.Edge, to sourceTime: RationalTime) {
        try? editor.perform("Trim Clip") { try TimelineEditor.trim(clip: id, edge: edge, to: sourceTime, in: &$0) }
    }

    // MARK: Transitions

    /// Sets or (with `nil`) removes the transition at the cut after `clipID`.
    /// Its duration is clamped to what the neighbouring clips allow.
    func setTransition(_ transition: Transition?, after clipID: Clip.ID) {
        try? editor.perform(transition == nil ? "Remove Transition" : "Set Transition") {
            try TimelineEditor.setTransition(transition, after: clipID, in: &$0)
        }
    }

    /// Changes the kind of the transition after `clipID`, keeping its duration.
    func setTransitionKind(_ kind: Transition.Kind?, after clipID: Clip.ID) {
        let current = project.clips.first { $0.id == clipID }?.outgoingTransition
        setTransition(kind.map { Transition(kind: $0, duration: current?.duration ?? Transition.defaultDuration) }, after: clipID)
    }

    /// Longest transition of `kind` that fits the cut after `clipID`.
    func maximumTransitionDuration(_ kind: Transition.Kind, after clipID: Clip.ID) -> RationalTime {
        var trial = project
        try? TimelineEditor.setTransition(Transition(kind: kind, duration: Transition.maximumDuration), after: clipID, in: &trial)
        return trial.clips.first { $0.id == clipID }?.outgoingTransition?.duration ?? Transition.minimumDuration
    }

    /// The cuts the transition commands act on, each named by the clip before it:
    /// with one clip selected, the cut after it; with several, every cut
    /// between two selected clips (⌘A then ⌘T fills the whole timeline).
    var selectedCuts: [Clip.ID] {
        let clips = project.clips
        guard clips.count > 1 else { return [] }
        if let id = selectedClipID {
            guard let index = project.clipIndex(id: id), index < clips.count - 1 else { return [] }
            return [id]
        }
        return zip(clips, clips.dropFirst())
            .filter { selection.contains($0.id) && selection.contains($1.id) }
            .map(\.0.id)
    }

    /// Whether any of `selectedCuts` has a transition.
    var selectedCutsHaveTransition: Bool {
        let cuts = Set(selectedCuts)
        return project.clips.contains { cuts.contains($0.id) && $0.outgoingTransition != nil }
    }

    /// Sets the transition kind at every selected cut, in one undo step.
    /// Existing durations are kept; new transitions get the default duration.
    func setTransitionKindForSelectedCuts(_ kind: Transition.Kind?) {
        let cuts = selectedCuts
        guard !cuts.isEmpty else { return }
        let name = kind == nil
            ? (cuts.count == 1 ? "Remove Transition" : "Remove Transitions")
            : (cuts.count == 1 ? "Set Transition" : "Set Transitions")
        try? editor.perform(name) { project in
            for id in cuts {
                let current = project.clips.first { $0.id == id }?.outgoingTransition
                let transition = kind.map { Transition(kind: $0, duration: current?.duration ?? Transition.defaultDuration) }
                try TimelineEditor.setTransition(transition, after: id, in: &project)
            }
        }
    }

    // MARK: Crop

    /// Switches the crop mode. Fixed ratios start as the largest centered
    /// area; free crop starts from the current area.
    func setCropMode(_ mode: CropSetting.Mode) {
        guard mode != project.crop.mode else { return }
        editor.perform("Change Aspect Ratio") { project in
            project.crop = project.canvasSize.map {
                CropGeometry.setting(for: mode, canvas: $0, current: project.crop.rect)
            } ?? CropSetting(mode: mode)
        }
    }

    func setCrop(_ crop: CropSetting) {
        guard crop != project.crop else { return }
        editor.perform("Change Crop") { $0.crop = crop }
    }

    /// The frame at the playhead without the crop, for the crop editor.
    func uncroppedFrame() async -> CGImage? {
        var uncropped = project
        uncropped.crop = .original
        let assets: [MediaSource.ID: AVAsset] = library.assets
        guard let built = try? await CompositionBuilder.build(project: uncropped, assets: assets) else { return nil }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = CMTime(seconds: min(playback.displayTime, max(0, built.layout.duration.seconds - 0.05)), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    // MARK: Cover

    /// Shown briefly over the preview (e.g. "Cover set").
    private(set) var flashMessage: String?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    func setCoverAtPlayhead() {
        guard let cover = TimelineEditor.coverFrame(at: playheadTime, in: project) else { return }
        editor.perform("Set Cover") { $0.cover = cover }
        flash("Cover set to this frame")
    }

    func removeCover() {
        guard project.cover != nil else { return }
        editor.perform("Remove Cover") { $0.cover = nil }
    }

    /// The cover as it will be embedded (with the crop), small, for display.
    func coverThumbnail() async -> CGImage? {
        let assets: [MediaSource.ID: AVAsset] = library.assets
        return try? await CoverImage.render(project: project, assets: assets, maxDimension: 320)
    }

    private func flash(_ message: String) {
        flashMessage = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.flashMessage = nil
        }
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
