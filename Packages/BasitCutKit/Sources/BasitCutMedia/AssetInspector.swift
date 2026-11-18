import AVFoundation
import BasitCutCore

/// Technical properties of a source video, read with AVFoundation.
public struct SourceInspection: Sendable, Hashable {
    public var duration: RationalTime
    public var frameDuration: RationalTime
    public var naturalSize: Size
    public var transform: Transform2D
    public var codec: VideoCodec
    public var videoBitrate: Int
    public var hasAudio: Bool
    public var creationDate: Date?
}

public enum AssetInspectionError: LocalizedError, Equatable {
    case unreadable(String)
    case noVideoTrack(String)
    case notPlayable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "“\(name)” can’t be opened. It may be damaged or in a format macOS doesn’t support."
        case .noVideoTrack(let name):
            "“\(name)” contains no video. Only video files can be imported."
        case .notPlayable(let name):
            "“\(name)” uses a format macOS can’t play."
        }
    }
}

public enum AssetInspector {
    /// Reads the properties basit-cut needs. Throws `AssetInspectionError` for
    /// files AVFoundation can't open or that contain no playable video.
    public static func inspect(_ url: URL) async throws -> SourceInspection {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let isPlayable: Bool, duration: CMTime, creation: AVMetadataItem?
        let videoTrack: AVAssetTrack?, audioTracks: [AVAssetTrack]
        do {
            (isPlayable, duration, creation) = try await asset.load(.isPlayable, .duration, .creationDate)
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AssetInspectionError.unreadable(name)
        }
        guard let videoTrack else { throw AssetInspectionError.noVideoTrack(name) }
        guard isPlayable, duration.isNumeric, duration > .zero else { throw AssetInspectionError.notPlayable(name) }

        let (size, transform, nominalFrameRate, minFrameDuration, dataRate, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .estimatedDataRate, .formatDescriptions
        )
        let codec = formats.first.map { VideoCodec(rawValue: CMFormatDescriptionGetMediaSubType($0).fourCCString) }
            ?? VideoCodec(rawValue: "unknown")
        let creationDate: Date? = if let creation { try? await creation.load(.dateValue) } else { nil }

        return SourceInspection(
            duration: RationalTime(duration),
            frameDuration: frameDuration(nominalFrameRate: nominalFrameRate, minFrameDuration: minFrameDuration),
            naturalSize: Size(size),
            transform: Transform2D(transform),
            codec: codec,
            videoBitrate: Int(dataRate.rounded()),
            hasAudio: !audioTracks.isEmpty,
            creationDate: creationDate
        )
    }

    /// An exact frame duration. NTSC rates (23.976, 29.97, 59.94) map to
    /// `1001/N000`; other rates close to an integer map to `1/N`.
    static func frameDuration(nominalFrameRate fps: Float, minFrameDuration: CMTime) -> RationalTime {
        let fps = Double(fps)
        if fps > 0 {
            for ntsc in [24.0, 30.0, 48.0, 60.0, 120.0] where abs(fps - ntsc * 1000 / 1001) < 0.01 {
                return RationalTime(value: 1001, timescale: Int32(ntsc * 1000))
            }
            let rounded = fps.rounded()
            if abs(fps - rounded) < 0.01 { return RationalTime(value: 1, timescale: Int32(rounded)) }
        }
        if minFrameDuration.isNumeric, minFrameDuration > .zero { return RationalTime(minFrameDuration) }
        return RationalTime(value: 1, timescale: 30)
    }
}

extension MediaSource {
    /// Creates a source from an inspected file.
    public init(id: UUID = UUID(), url: URL, bookmark: Data, inspection: SourceInspection) {
        self.init(
            id: id,
            bookmark: bookmark,
            lastKnownPath: url.path(percentEncoded: false),
            duration: inspection.duration,
            frameDuration: inspection.frameDuration,
            naturalSize: inspection.naturalSize,
            transform: inspection.transform,
            codec: inspection.codec,
            videoBitrate: inspection.videoBitrate,
            hasAudio: inspection.hasAudio,
            creationDate: inspection.creationDate
        )
    }
}
