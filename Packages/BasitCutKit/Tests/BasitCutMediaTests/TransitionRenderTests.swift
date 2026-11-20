import AVFoundation
import CoreGraphics
import Foundation
import Testing
import BasitCutCore
@testable import BasitCutMedia

/// Renders frames and audio of compositions with transitions and checks the
/// fades actually happen.
struct TransitionRenderTests {
    let directory: URL

    init() throws { directory = try TestVideoGenerator.makeTemporaryDirectory() }

    private func makeSource(gray: UInt8, seconds: Double = 2) async throws -> (MediaSource, AVAsset) {
        var spec = TestVideoGenerator.Spec(seconds: seconds)
        spec.gray = gray
        let url = try await TestVideoGenerator.makeVideo(spec, in: directory)
        let source = MediaSource(url: url, bookmark: Data(), inspection: try await AssetInspector.inspect(url))
        return (source, AVURLAsset(url: url))
    }

    private func build(_ transition: Transition, grays: (UInt8, UInt8)) async throws -> BuiltComposition {
        let (a, assetA) = try await makeSource(gray: grays.0)
        let (b, assetB) = try await makeSource(gray: grays.1)
        var project = Project()
        try TimelineEditor.insertClips(for: [a, b], in: &project)
        try TimelineEditor.setTransition(transition, after: project.clips[0].id, in: &project)
        return try await CompositionBuilder.build(project: project, assets: [a.id: assetA, b.id: assetB])
    }

    /// Brightness (0–255) of the rendered frame at `seconds`.
    private func brightness(_ built: BuiltComposition, at seconds: Double) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))

        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = try #require(CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let center = (size / 2 * size + size / 2) * 4
        return (Double(pixels[center]) + Double(pixels[center + 1]) + Double(pixels[center + 2])) / 3
    }

    /// Peak sample level of the mixed audio between `start` and `end` (seconds).
    /// The whole timeline is read, as playback does, and samples are picked by time.
    private func audioPeak(_ built: BuiltComposition, from start: Double, to end: Double) async throws -> Float {
        let sampleRate = 48_000.0
        let reader = try AVAssetReader(asset: built.composition)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        output.audioMix = built.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            let bufferStart = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    let time = bufferStart + Double(i) / sampleRate
                    if time >= start && time < end { peak = max(peak, abs(samples[i])) }
                }
            }
        }
        return peak
    }

    @Test func blackFadeDipsTowardsBlack() async throws {
        let built = try await build(Transition(kind: .blackFade, duration: .seconds(1)), grays: (200, 200))
        // A dims over 1.5–2.0 s, B brightens over 2.0–2.5 s; at the cut the
        // picture is at `blackFadeFloor` (0.3), not black.
        #expect(try await brightness(built, at: 1.0) > 150)
        let dimmest = try await brightness(built, at: 2.0)
        #expect(dimmest > 35 && dimmest < 90)
        let halfway = try await brightness(built, at: 1.75)
        #expect(halfway > dimmest + 20 && halfway < 175)
        #expect(try await brightness(built, at: 3.0) > 150)

        // The audio follows: silent around the cut, full in the middle of a clip.
        let atCut = try await audioPeak(built, from: 1.98, to: 2.02)
        let middle = try await audioPeak(built, from: 0.9, to: 1.1)
        #expect(middle > 0.1)
        #expect(atCut < middle * 0.1)
    }

    @Test func crossFadeBlendsBothClips() async throws {
        let built = try await build(Transition(kind: .crossFade, duration: .seconds(1)), grays: (40, 220))
        // Overlap: 1.0–2.0 s on a 3 s timeline.
        #expect(abs(built.composition.duration.seconds - 3) < 0.05)
        #expect(try await brightness(built, at: 0.5) < 70)
        let mid = try await brightness(built, at: 1.5)
        #expect(mid > 100 && mid < 160)
        #expect(try await brightness(built, at: 2.5) > 190)

        // Audio crossfades: one tone fading out while the other fades in, so
        // the level stays up instead of dropping to silence.
        let overlap = try await audioPeak(built, from: 1.45, to: 1.55)
        #expect(overlap > 0.1)
    }

    @Test func hardCutHasShortAudioFade() async throws {
        let (a, asset) = try await makeSource(gray: 128)
        var project = Project()
        try TimelineEditor.insertClips(for: [a, a], in: &project)
        let built = try await CompositionBuilder.build(project: project, assets: [a.id: asset])

        let mix = try #require(built.audioMix)
        var startVolume: Float = 1, endVolume: Float = 1, range = CMTimeRange.zero
        let fadeOut = mix.inputParameters[0].getVolumeRamp(
            for: CMTime(seconds: 1.995, preferredTimescale: 600), startVolume: &startVolume, endVolume: &endVolume, timeRange: &range
        )
        #expect(fadeOut)
        #expect(startVolume == 1 && endVolume == 0)
        #expect(abs(range.duration.seconds - 0.015) < 0.001)
        #expect(range.end == CMTime(value: 2, timescale: 1))
        // The picture just cuts.
        #expect(try await brightness(built, at: 1.99) > 100)
    }
}
