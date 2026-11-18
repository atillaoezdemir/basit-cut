import Foundation
@testable import BasitCutCore

/// Builds model values for tests; no media files involved.
enum Fixture {
    static let fps30 = RationalTime(value: 1, timescale: 30)

    static func source(
        seconds: Int64 = 10,
        frameDuration: RationalTime = fps30,
        size: Size = Size(width: 1920, height: 1080),
        transform: Transform2D = .identity,
        codec: VideoCodec = .h264
    ) -> MediaSource {
        MediaSource(
            bookmark: Data(),
            lastKnownPath: "/tmp/clip.mov",
            duration: .seconds(seconds),
            frameDuration: frameDuration,
            naturalSize: size,
            transform: transform,
            codec: codec,
            videoBitrate: 10_000_000,
            hasAudio: true
        )
    }

    /// A project with one clip per entry in `seconds`, each from its own source.
    static func project(clipSeconds seconds: [Int64]) -> Project {
        var project = Project()
        try! TimelineEditor.insertClips(for: seconds.map { source(seconds: $0) }, in: &project)
        return project
    }
}

func s(_ seconds: Double) -> RationalTime {
    RationalTime(seconds: seconds, preferredTimescale: 600)
}
