import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import BasitCutCore
@testable import BasitCutMedia

struct CropAndCoverTests {
    let directory: URL
    let canvas = Size(width: 320, height: 180)

    init() throws { directory = try TestVideoGenerator.makeTemporaryDirectory() }

    /// A 320×180 source: dark left half, bright right half.
    private func makeSplitSource() async throws -> (MediaSource, AVAsset) {
        var spec = TestVideoGenerator.Spec(seconds: 1)
        spec.halves = (left: 30, right: 220)
        let url = try await TestVideoGenerator.makeVideo(spec, in: directory)
        let source = MediaSource(url: url, bookmark: Data(), inspection: try await AssetInspector.inspect(url))
        return (source, AVURLAsset(url: url))
    }

    /// A 9:16 crop pushed to the left or right edge.
    private func project(_ source: MediaSource, cropAtLeft: Bool) throws -> Project {
        var project = Project()
        try TimelineEditor.insertClips(for: [source], in: &project)
        var crop = CropGeometry.setting(for: .ratio9x16, canvas: canvas)
        crop.rect = CropGeometry.moved(crop.rect, dx: cropAtLeft ? -1 : 1, dy: 0)
        project.crop = crop
        project.cover = TimelineEditor.coverFrame(at: RationalTime(seconds: 0.5), in: project)
        return project
    }

    private func brightness(of image: CGImage) throws -> Double {
        let size = 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = try #require(CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }.reduce(0, +) / Double(size * size * 3)
    }

    private func frame(_ built: BuiltComposition) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        return try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }

    @Test(arguments: [true, false])
    func cropCutsTheChosenPartOfTheFrame(atLeft: Bool) async throws {
        let (source, asset) = try await makeSplitSource()
        let project = try project(source, cropAtLeft: atLeft)
        let built = try await CompositionBuilder.build(project: project, assets: [source.id: asset])

        #expect(built.renderSize == CGSize(width: 102, height: 180))   // 180 × 9/16 = 101.25 → even
        let value = try brightness(of: try await frame(built))
        #expect(atLeft ? value < 60 : value > 190)
    }

    @Test func coverIsRenderedWithTheCrop() async throws {
        let (source, asset) = try await makeSplitSource()
        let image = try #require(try await CoverImage.render(project: try project(source, cropAtLeft: false), assets: [source.id: asset]))
        #expect(image.width == 102 && image.height == 180)
        #expect(try brightness(of: image) > 190)
    }

    @Test func noCoverRendersNothing() async throws {
        let (source, asset) = try await makeSplitSource()
        var project = try project(source, cropAtLeft: true)
        project.cover = nil
        #expect(try await CoverImage.render(project: project, assets: [source.id: asset]) == nil)
    }

    @Test(arguments: [ExportMode.original, .spaceSaving])
    func exportIsCroppedAndCarriesTheCover(mode: ExportMode) async throws {
        let (source, asset) = try await makeSplitSource()
        let project = try project(source, cropAtLeft: false)
        let url = directory.appending(path: "cropped-\(UUID().uuidString).mov")
        try await Exporter.export(project: project, assets: [source.id: asset], mode: mode, to: url)

        let exported = AVURLAsset(url: url)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 102, height: 180))

        let metadata = try await exported.load(.metadata)
        let artwork = try #require(metadata.first { $0.identifier == .quickTimeMetadataArtwork })
        let data = try #require(try await artwork.load(.dataValue))
        let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == 102)
        #expect(try brightness(of: image) > 190)
    }
}
