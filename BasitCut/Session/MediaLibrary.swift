import AVFoundation
import Observation
import BasitCutCore
import BasitCutMedia

/// Resolves the project's source bookmarks to playable assets and keeps
/// security-scoped access open while the project window is open.
@MainActor
@Observable
final class MediaLibrary {
    private(set) var assets: [MediaSource.ID: AVURLAsset] = [:]
    /// Sources whose files can't be found (relinking comes in a later phase).
    private(set) var missing: Set<MediaSource.ID> = []

    @ObservationIgnored private var accessedURLs: [URL] = []

    /// Resolves sources that aren't resolved yet. Returns refreshed bookmark
    /// data for sources whose bookmark was stale.
    func resolve(_ sources: [MediaSource]) -> [MediaSource.ID: Data] {
        var refreshed: [MediaSource.ID: Data] = [:]
        for source in sources where assets[source.id] == nil && !missing.contains(source.id) {
            do {
                let resolved = try SecurityScopedBookmark.resolve(source.bookmark)
                let accessing = resolved.url.startAccessingSecurityScopedResource()
                guard FileManager.default.fileExists(atPath: resolved.url.path(percentEncoded: false)) else {
                    if accessing { resolved.url.stopAccessingSecurityScopedResource() }
                    missing.insert(source.id)
                    continue
                }
                if accessing { accessedURLs.append(resolved.url) }
                assets[source.id] = Self.makeAsset(resolved.url)
                if resolved.isStale, let bookmark = try? SecurityScopedBookmark.make(for: resolved.url) {
                    refreshed[source.id] = bookmark
                }
            } catch {
                missing.insert(source.id)
            }
        }
        return refreshed
    }

    /// Adds a freshly imported source. If `accessing` is true, the library takes
    /// over the security-scoped access started by the importer.
    func register(_ source: MediaSource, url: URL, accessing: Bool) {
        if accessing { accessedURLs.append(url) }
        missing.remove(source.id)
        assets[source.id] = Self.makeAsset(url)
    }

    func close() {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        assets.removeAll()
    }

    private static func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }
}
