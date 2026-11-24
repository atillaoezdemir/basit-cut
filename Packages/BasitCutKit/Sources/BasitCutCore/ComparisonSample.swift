import Foundation

/// A short, uncut piece of the project's first source, used to show what the
/// export modes do to the picture before exporting.
public struct ComparisonSample: Hashable, Sendable {
    public static let maximumDuration = RationalTime.seconds(10)

    public var sourceID: MediaSource.ID
    /// Up to ten seconds from the middle of the whole source.
    public var range: TimeRange
    public var crop: CropSetting

    /// Doesn't depend on how the clips are cut, so edits rarely invalidate it.
    public init?(project: Project) {
        guard let source = project.referenceSource, source.duration > .zero else { return nil }
        let duration = min(Self.maximumDuration, source.duration)
        let middle = (source.duration - duration).divided(by: 2)
        sourceID = source.id
        range = TimeRange(start: middle.floored(toMultipleOf: source.frameDuration), duration: duration)
        crop = project.crop
    }

    /// The sample as a one-clip project with the original's crop.
    public func project(from original: Project) -> Project? {
        guard let source = original.source(id: sourceID) else { return nil }
        return Project(sources: [source], clips: [Clip(id: sourceID, sourceID: sourceID, sourceRange: range)], crop: crop)
    }
}
