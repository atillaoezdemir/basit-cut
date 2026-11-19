import AVFoundation
import Foundation
import Synchronization
import Testing
import BasitCutCore
@testable import BasitCutMedia

/// End-to-end exports of generated test videos.
struct ExporterTests {
    let directory: URL
    let recordedAt = Date(timeIntervalSince1970: 1_563_100_000)   // 2019-07-14
    let location = "+48.8566+002.3522/"
    let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)

    init() throws { directory = try TestVideoGenerator.makeTemporaryDirectory() }

    private func makeSource(_ spec: TestVideoGenerator.Spec) async throws -> (MediaSource, AVAsset) {
        let url = try await TestVideoGenerator.makeVideo(spec, in: directory)
        let source = MediaSource(url: url, bookmark: Data(), inspection: try await AssetInspector.inspect(url))
        return (source, AVURLAsset(url: url))
    }

    private var outputURL: URL { directory.appending(path: "export-\(UUID().uuidString).mov") }

    /// Facts about an exported file.
    private struct Output {
        var duration: Double
        var videoTrackCount: Int
        var audioTrackCount: Int
        var codec: String
        var naturalSize: CGSize
        var transform: CGAffineTransform
        var orientedSize: CGSize
        var dataRate: Float
        var metadata: [AVMetadataIdentifier: String]
    }

    private func inspectOutput(_ url: URL) async throws -> Output {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try #require(videoTracks.first)
        let (size, transform, formats, dataRate) = try await video.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .estimatedDataRate
        )
        var metadata: [AVMetadataIdentifier: String] = [:]
        for item in try await asset.load(.metadata) {
            if let identifier = item.identifier, let value = try? await item.load(.stringValue) {
                metadata[identifier] = value
            }
        }
        let oriented = CGRect(origin: .zero, size: size).applying(transform).size
        return Output(
            duration: try await asset.load(.duration).seconds,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            codec: formats.first.map { CMFormatDescriptionGetMediaSubType($0).fourCCString } ?? "",
            naturalSize: size,
            transform: transform,
            orientedSize: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            dataRate: dataRate,
            metadata: metadata
        )
    }

    private func expectArchiveMetadata(_ output: Output, url: URL) throws {
        let date = output.metadata[.quickTimeMetadataCreationDate].flatMap { ISO8601DateFormatter().date(from: $0) }
        #expect(date == recordedAt)
        #expect(output.metadata[.quickTimeMetadataLocationISO6709] == location)
        #expect(output.metadata[.quickTimeMetadataModel] == "Test Camera")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.creationDate] as? Date == recordedAt)
    }

    private var archiveSpec: TestVideoGenerator.Spec {
        var spec = TestVideoGenerator.Spec(seconds: 2)
        spec.creationDate = recordedAt
        spec.location = location
        spec.model = "Test Camera"
        return spec
    }

    // MARK: Passthrough

    @Test func passthroughKeepsCodecCutsAndMetadata() async throws {
        let (a, asset) = try await makeSource(archiveSpec)
        var project = Project()
        try TimelineEditor.insertClips(for: [a, a], in: &project)
        try TimelineEditor.trim(clip: project.clips[1].id, edge: .leading, to: RationalTime(seconds: 1), in: &project)
        project.cover = TimelineEditor.coverFrame(at: RationalTime(seconds: 0.5), in: project)
        #expect(try ExportPlan.make(for: project, mode: .original) == .passthrough)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .original, to: url)

        let output = try await inspectOutput(url)
        #expect(abs(output.duration - 3) < 0.1)
        #expect(output.videoTrackCount == 1)
        #expect(output.audioTrackCount == 1)
        #expect(output.codec == "avc1")
        try expectArchiveMetadata(output, url: url)
        let artwork = try await AVURLAsset(url: url).load(.metadata).first { $0.identifier == .quickTimeMetadataArtwork }
        #expect(try await artwork?.load(.dataValue)?.isEmpty == false)
    }

    @Test func passthroughKeepsRotation() async throws {
        let (a, asset) = try await makeSource(.init(seconds: 1, transform: portrait))
        var project = Project()
        try TimelineEditor.insertClips(for: [a], in: &project)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .original, to: url)

        let output = try await inspectOutput(url)
        #expect(output.orientedSize == CGSize(width: 180, height: 320))
    }

    // MARK: Re-encode

    @Test func mixedRotationReencodesUprightWithSourceCodec() async throws {
        let (landscape, landscapeAsset) = try await makeSource(archiveSpec)
        let (upright, uprightAsset) = try await makeSource(.init(seconds: 1, transform: portrait))
        var project = Project()
        try TimelineEditor.insertClips(for: [landscape, upright], in: &project)
        guard case .reencode = try ExportPlan.make(for: project, mode: .original) else {
            Issue.record("expected re-encode"); return
        }

        let url = outputURL
        let progressValues = Mutex<[Double]>([])
        try await Exporter.export(
            project: project,
            assets: [landscape.id: landscapeAsset, upright.id: uprightAsset],
            mode: .original,
            to: url,
            progress: { value in progressValues.withLock { $0.append(value) } }
        )

        let output = try await inspectOutput(url)
        #expect(abs(output.duration - 3) < 0.1)
        #expect(output.videoTrackCount == 1)
        #expect(output.audioTrackCount == 1)
        #expect(output.codec == "avc1")
        // Rendered upright into the first clip's size, no rotation flag left.
        #expect(output.naturalSize == CGSize(width: 320, height: 180))
        #expect(output.transform == .identity)
        try expectArchiveMetadata(output, url: url)

        let values = progressValues.withLock { $0 }
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    @Test func crossFadeExportsShorterTimelineWithSourceCodec() async throws {
        let (a, asset) = try await makeSource(archiveSpec)
        var project = Project()
        try TimelineEditor.insertClips(for: [a, a], in: &project)
        try TimelineEditor.setTransition(Transition(kind: .crossFade, duration: .seconds(1)), after: project.clips[0].id, in: &project)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .original, to: url)

        let output = try await inspectOutput(url)
        #expect(abs(output.duration - 3) < 0.1)
        #expect(output.codec == "avc1")
        #expect(output.audioTrackCount == 1)
        try expectArchiveMetadata(output, url: url)
    }

    @Test func spaceSavingIsHVC1AndDownscalesAbove1080p() async throws {
        var spec = archiveSpec
        spec.seconds = 1
        spec.width = 2560
        spec.height = 1440
        let (a, asset) = try await makeSource(spec)
        var project = Project()
        try TimelineEditor.insertClips(for: [a], in: &project)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .spaceSaving, to: url)

        let output = try await inspectOutput(url)
        #expect(output.codec == "hvc1")
        #expect(output.naturalSize == CGSize(width: 1920, height: 1080))
        #expect(output.audioTrackCount == 1)
        #expect(output.dataRate <= 4_400_000)
        try expectArchiveMetadata(output, url: url)
    }

    @Test func spaceSavingKeepsPortraitOrientation() async throws {
        let (a, asset) = try await makeSource(.init(seconds: 1, transform: portrait))
        var project = Project()
        try TimelineEditor.insertClips(for: [a], in: &project)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .spaceSaving, to: url)

        let output = try await inspectOutput(url)
        #expect(output.orientedSize == CGSize(width: 180, height: 320))
    }

    @Test func missingCreationDateFallsBackToInspectedDate() async throws {
        let (a, asset) = try await makeSource(.init(seconds: 1, withAudio: false))
        var project = Project()
        var source = a
        source.creationDate = recordedAt
        try TimelineEditor.insertClips(for: [source], in: &project)

        let url = outputURL
        try await Exporter.export(project: project, assets: [a.id: asset], mode: .spaceSaving, to: url)

        let output = try await inspectOutput(url)
        #expect(output.audioTrackCount == 0)
        let date = output.metadata[.quickTimeMetadataCreationDate].flatMap { ISO8601DateFormatter().date(from: $0) }
        #expect(date == recordedAt)
    }

    // MARK: Cancel

    @Test(arguments: [ExportMode.original, .spaceSaving])
    func cancellingDeletesThePartialFile(mode: ExportMode) async throws {
        let (a, asset) = try await makeSource(.init(seconds: 6, width: 1920, height: 1080))
        var project = Project()
        try TimelineEditor.insertClips(for: [a, a, a], in: &project)

        // Cancel as soon as the export reports progress, i.e. while it runs.
        // (Passthrough can finish before any report; then it's cancelled right
        // after starting, which must also leave no file behind.)
        let url = outputURL
        let running = Mutex<Task<Void, Error>?>(nil)
        let task = Task {
            try await Exporter.export(project: project, assets: [a.id: asset], mode: mode, to: url) { value in
                if value > 0, value < 1 { running.withLock { $0?.cancel() } }
            }
        }
        running.withLock { $0 = task }
        if mode == .original { task.cancel() }

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
