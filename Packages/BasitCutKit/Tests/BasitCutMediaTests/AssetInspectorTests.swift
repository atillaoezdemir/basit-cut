import AVFoundation
import Foundation
import Testing
import BasitCutCore
@testable import BasitCutMedia

struct AssetInspectorTests {
    let directory: URL

    init() throws { directory = try TestVideoGenerator.makeTemporaryDirectory() }

    @Test func readsBasicProperties() async throws {
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        let url = try await TestVideoGenerator.makeVideo(.init(seconds: 2, creationDate: date), in: directory)
        let info = try await AssetInspector.inspect(url)

        #expect(abs(info.duration.seconds - 2) < 0.05)
        #expect(info.frameDuration == RationalTime(value: 1, timescale: 30))
        #expect(info.naturalSize == Size(width: 320, height: 180))
        #expect(info.codec == .h264)
        #expect(info.hasAudio)
        #expect(info.videoBitrate > 0)
        #expect(info.creationDate == date)
    }

    @Test func readsRotationOfPortraitPhoneVideo() async throws {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let url = try await TestVideoGenerator.makeVideo(.init(transform: rotate90, withAudio: false), in: directory)
        let info = try await AssetInspector.inspect(url)

        #expect(info.transform == Transform2D(rotate90))
        #expect(info.transform.applied(to: info.naturalSize) == Size(width: 180, height: 320))
        #expect(!info.hasAudio)
    }

    @Test func readsHEVC() async throws {
        let url = try await TestVideoGenerator.makeVideo(.init(codec: .hevc, withAudio: false), in: directory)
        #expect(try await AssetInspector.inspect(url).codec.family == "HEVC")
    }

    @Test func rejectsNonVideoFiles() async throws {
        let url = directory.appending(path: "notes.mov")
        try Data("not a movie".utf8).write(to: url)
        await #expect(throws: AssetInspectionError.self) { try await AssetInspector.inspect(url) }
    }

    @Test func mapsNTSCFrameRatesExactly() {
        #expect(AssetInspector.frameDuration(nominalFrameRate: 29.97, minFrameDuration: .invalid) == RationalTime(value: 1001, timescale: 30000))
        #expect(AssetInspector.frameDuration(nominalFrameRate: 23.976, minFrameDuration: .invalid) == RationalTime(value: 1001, timescale: 24000))
        #expect(AssetInspector.frameDuration(nominalFrameRate: 25, minFrameDuration: .invalid) == RationalTime(value: 1, timescale: 25))
        #expect(AssetInspector.frameDuration(nominalFrameRate: 0, minFrameDuration: CMTime(value: 1, timescale: 50)) == RationalTime(value: 1, timescale: 50))
    }

    @Test func bookmarkRoundTrip() async throws {
        let url = try await TestVideoGenerator.makeVideo(.init(seconds: 0.5, withAudio: false), in: directory)
        let bookmark = try SecurityScopedBookmark.make(for: url)
        let resolved = try SecurityScopedBookmark.resolve(bookmark)
        #expect(resolved.url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath())
    }
}
