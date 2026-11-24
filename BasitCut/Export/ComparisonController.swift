import AVFoundation
import Observation
import BasitCutCore
import BasitCutMedia

/// Prepares ten seconds of the first video in both export modes, in the
/// background as soon as a project has a video, so comparing them in the
/// export dialog needs no waiting. A sample is only made again when something
/// that affects it changes (the first video, the crop, the encoder settings).
@MainActor
@Observable
final class ComparisonController {
    /// What decides how one side looks.
    struct Key: Equatable {
        var sample: ComparisonSample
        var plan: ExportPlan
    }

    private struct Side {
        var key: Key
        /// The encoded sample; nil for passthrough, which shows the source.
        var file: URL?
        var passthrough: BuiltComposition?

        @MainActor func makeItem() -> AVPlayerItem? {
            file.map { AVPlayerItem(url: $0) } ?? passthrough?.makePlayerItem()
        }
    }

    private var sides: [ExportMode: Side] = [:]
    private var wanted: [ExportMode: Key] = [:]
    private(set) var isPreparing = false
    private(set) var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let directory = FileManager.default.temporaryDirectory
        .appending(path: "Comparison-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Samples left behind by a quit or crash (a closed window deletes its
    /// own). Runs once per launch, before any new sample is written.
    private static let removeLeftovers: Void = {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix("Comparison-") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }()

    init() { Self.removeLeftovers }

    var isReady: Bool {
        !wanted.isEmpty && ExportMode.allCases.allSatisfy { wanted[$0] != nil && sides[$0]?.key == wanted[$0] }
    }

    func makeItem(_ mode: ExportMode) -> AVPlayerItem? { sides[mode]?.makeItem() }

    func update(project: Project, assets: [MediaSource.ID: AVAsset]) {
        var keys: [ExportMode: Key] = [:]
        if let sample = ComparisonSample(project: project), assets[sample.sourceID] != nil {
            for mode in ExportMode.allCases {
                if let plan = try? ExportPlan.make(for: project, mode: mode) { keys[mode] = Key(sample: sample, plan: plan) }
            }
        }
        guard keys != wanted else { return }
        wanted = keys
        error = nil
        let previous = task
        previous?.cancel()
        guard !keys.isEmpty, !isReady, let sampleProject = keys[.original]?.sample.project(from: project) else {
            isPreparing = false
            task = nil
            return
        }
        isPreparing = true
        // AVAsset is immutable and safe to read from other threads.
        nonisolated(unsafe) let assets = assets
        task = Task(priority: .utility) { [weak self] in
            await previous?.value   // never two encoders at once
            // Quick edits in a row start only one run.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                // Space saving first: it always has to be encoded.
                for mode in [ExportMode.spaceSaving, .original] {
                    guard let key = keys[mode], let self, self.sides[mode]?.key != key else { continue }
                    let side = try await self.prepare(key, project: sampleProject, assets: assets)
                    if Task.isCancelled {
                        if let file = side.file { try? FileManager.default.removeItem(at: file) }
                        return
                    }
                    if let old = self.sides[mode]?.file { try? FileManager.default.removeItem(at: old) }
                    self.sides[mode] = side
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = "The comparison couldn’t be prepared. " + error.localizedDescription
            }
            if !Task.isCancelled { self?.isPreparing = false }
        }
    }

    /// Stops and deletes the samples.
    func close() {
        task?.cancel()
        let running = task
        task = nil
        wanted = [:]
        sides = [:]
        isPreparing = false
        let directory = directory
        Task {
            await running?.value
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func prepare(_ key: Key, project: Project, assets: sending [MediaSource.ID: AVAsset]) async throws -> Side {
        switch key.plan {
        case .passthrough:
            return Side(key: key, passthrough: try await CompositionBuilder.build(project: project, assets: assets))
        case .reencode(let settings):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: UUID().uuidString + ".mov")
            try await Exporter.encodeSample(project: project, assets: assets, settings: settings, to: url)
            return Side(key: key, file: url)
        }
    }
}
