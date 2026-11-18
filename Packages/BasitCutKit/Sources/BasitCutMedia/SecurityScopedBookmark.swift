import Foundation

/// Creates and resolves app-scoped security-scoped bookmarks, so access to
/// source videos survives app restarts in the sandbox.
public enum SecurityScopedBookmark {
    public struct Resolved: Sendable {
        public var url: URL
        /// The bookmark should be recreated (e.g. the file was moved).
        public var isStale: Bool
    }

    /// `url` must be accessible right now (e.g. picked by the user, or with
    /// `startAccessingSecurityScopedResource()` active).
    public static func make(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark. Throws if the file can't be found.
    public static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }
}
