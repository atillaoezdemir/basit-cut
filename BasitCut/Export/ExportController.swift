import AVFoundation
import Observation
import BasitCutCore
import BasitCutMedia

/// State of the export dialog for one project window: chosen mode, progress,
/// result. Owns the running export task so it can be cancelled.
@MainActor
@Observable
final class ExportController {
    enum Phase: Equatable {
        case idle
        case exporting(progress: Double)
        case finished(URL)
        case failed(String)
    }

    /// The last used mode is remembered across exports and launches.
    var mode: ExportMode = ExportController.savedMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    private(set) var phase: Phase = .idle

    @ObservationIgnored private var task: Task<Void, Never>?

    var isExporting: Bool {
        if case .exporting = phase { true } else { false }
    }

    /// Describes what `mode` will produce for `project`, for the dialog.
    func summary(for project: Project, mode: ExportMode) -> ExportSummary? {
        guard let plan = try? ExportPlan.make(for: project, mode: mode) else { return nil }
        return ExportSummary(plan: plan, project: project)
    }

    func start(project: Project, assets: [MediaSource.ID: AVAsset], to url: URL) {
        guard !isExporting else { return }
        let mode = self.mode
        phase = .exporting(progress: 0)
        // AVAsset is immutable and safe to read from other threads.
        nonisolated(unsafe) let assets = assets
        task = Task { [weak self] in
            // Security-scoped access to the file the save panel returned.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Exporter.export(project: project, assets: assets, mode: mode, to: url) { value in
                    Task { @MainActor in self?.updateProgress(value) }
                }
                self?.phase = .finished(url)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Remembered choices

    private static let modeKey = "exportMode"
    private static let directoryKey = "lastExportDirectory"

    private static var savedMode: ExportMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(ExportMode.init(rawValue:)) ?? .original
    }

    /// Folder of the last export, where the save panel opens next time.
    static var lastDirectory: URL? {
        get { UserDefaults.standard.url(forKey: directoryKey) }
        set { UserDefaults.standard.set(newValue, forKey: directoryKey) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Back to the mode selection after a finished or failed export.
    func reset() {
        guard !isExporting else { return }
        phase = .idle
    }

    private func updateProgress(_ value: Double) {
        // Late progress callbacks must not overwrite a final state.
        guard case .exporting(let current) = phase, value > current else { return }
        phase = .exporting(progress: value)
    }
}

/// Human-readable facts about an export, derived from its plan.
struct ExportSummary: Equatable {
    var lines: [String]
    /// Rough output size in bytes (nil for passthrough, where it equals the sources).
    var estimatedBytes: Int64?

    init(plan: ExportPlan, project: Project) {
        let duration = TimelineLayout(project: project).duration.seconds
        switch plan {
        case .passthrough:
            let source = project.referenceSource
            lines = [
                "No re-encoding: lossless and fast.",
                source.map { "\($0.codec.family), \(Self.format($0.orientedSize)), \(Self.format(fps: $0.frameRate))" } ?? "",
            ]
            estimatedBytes = ExportPlan.averageBitrate(of: project).map { Int64(Double($0) * duration / 8) }
        case .reencode(let settings):
            lines = [
                "\(settings.codec.family), \(Self.format(settings.size)), \(Self.format(fps: 1 / settings.frameDuration.seconds))",
                "Video \(settings.videoBitrate / 1000) kbps, audio AAC \(settings.audioBitrate / 1000) kbps",
            ]
            estimatedBytes = Int64(Double(settings.videoBitrate + settings.audioBitrate) * duration / 8)
        }
    }

    private static func format(_ size: Size) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    private static func format(fps: Double) -> String {
        let rounded = fps.rounded()
        return abs(fps - rounded) < 0.01 ? "\(Int(rounded)) fps" : String(format: "%.2f fps", fps)
    }
}
