import Foundation

public enum RelinkError: LocalizedError, Equatable, Sendable {
    case sourceNotFound
    /// The replacement is shorter than the part of the source the timeline uses.
    case tooShort(fileName: String, needed: RationalTime, actual: RationalTime)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            "The source is no longer part of the project."
        case .tooShort(let name, let needed, let actual):
            String(
                format: "“%@” is %.1f s long, but the timeline uses the first %.1f s of the original file. Choose the same video.",
                name, actual.seconds, needed.seconds
            )
        }
    }
}

/// Pointing a missing source at a file in its new place.
extension TimelineEditor {
    /// How much of the source the project needs: the end of the latest clip
    /// range or cover frame that uses it.
    public static func requiredDuration(of sourceID: MediaSource.ID, in project: Project) -> RationalTime {
        var needed = RationalTime.zero
        for clip in project.clips where clip.sourceID == sourceID {
            needed = max(needed, clip.sourceRange.end)
        }
        if let cover = project.cover, cover.sourceID == sourceID {
            needed = max(needed, cover.time)
        }
        return needed
    }

    /// Replaces the source `sourceID` with `replacement` (a freshly inspected
    /// file), keeping the source's ID so clips and the cover stay attached.
    /// Fails if the file is too short for the clips that use it. Returns how
    /// its format differs from the original, for a warning.
    @discardableResult
    public static func relink(
        source sourceID: MediaSource.ID,
        to replacement: MediaSource,
        in project: inout Project
    ) throws -> [FormatDifference] {
        guard let index = project.sources.firstIndex(where: { $0.id == sourceID }) else {
            throw RelinkError.sourceNotFound
        }
        let needed = requiredDuration(of: sourceID, in: project)
        guard replacement.duration >= needed else {
            throw RelinkError.tooShort(fileName: replacement.displayName, needed: needed, actual: replacement.duration)
        }
        let original = project.sources[index]
        var updated = replacement
        updated.id = sourceID
        project.sources[index] = updated
        return updated.formatDifferences(comparedTo: original)
    }

    /// Missing sources whose file name is among `fileNames` (e.g. the contents
    /// of the folder where another missing file was found), matched by name.
    public static func relinkCandidates(
        for missing: [MediaSource],
        among fileNames: [String]
    ) -> [MediaSource.ID: String] {
        let available = Set(fileNames)
        var matches: [MediaSource.ID: String] = [:]
        for source in missing where available.contains(source.displayName) {
            matches[source.id] = source.displayName
        }
        return matches
    }
}
