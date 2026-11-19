import AppKit
import Observation
import BasitCutCore
import BasitCutMedia

/// The folder where all projects live, chosen once by the user (and changeable
/// in Settings). Its security-scoped bookmark is kept in the user defaults and
/// access stays open for the app's lifetime, so projects inside it can be
/// created, opened and saved without asking for a location.
@MainActor
@Observable
final class ProjectsFolder {
    static let shared = ProjectsFolder()

    private(set) var url: URL?
    private(set) var projects: [ProjectEntry] = []
    /// Set by the File menu to ask the Projects window for a new project.
    var isNewProjectRequested = false

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    private static let bookmarkKey = "projectsFolderBookmark"

    private init() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let resolved = try? SecurityScopedBookmark.resolve(bookmark)
        else { return }
        use(resolved.url)
        if resolved.isStale { saveBookmark(for: resolved.url) }
    }

    /// Lets the user pick (or create) the projects folder.
    @discardableResult
    func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Projects Folder"
        panel.message = "basit-cut creates new projects here and lists the projects in it."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // The sandbox reports the container as home; start in the real ~/Movies.
        panel.directoryURL = url ?? URL(filePath: "/Users/\(NSUserName())/Movies", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        use(chosen)
        saveBookmark(for: chosen)
        return true
    }

    func refresh() {
        guard let url else { projects = []; return }
        projects = (try? ProjectListing.entries(in: url)) ?? []
    }

    /// Creates an empty project in the folder and returns its URL.
    func createProject(named name: String, crop: CropSetting.Mode) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let created = try ProjectListing.createProject(named: name, crop: crop, in: url)
        refresh()
        return created
    }

    func suggestedName() -> String {
        url.map { ProjectListing.availableName(ProjectListing.defaultName, in: $0) } ?? ProjectListing.defaultName
    }

    func moveToTrash(_ entry: ProjectEntry) throws {
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        refresh()
    }

    // MARK: Access

    private func use(_ newURL: URL) {
        if let url { url.stopAccessingSecurityScopedResource() }
        _ = newURL.startAccessingSecurityScopedResource()
        url = newURL
        watch(newURL)
        refresh()
    }

    private func saveBookmark(for url: URL) {
        guard let bookmark = try? SecurityScopedBookmark.make(for: url) else { return }
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
    }

    /// Refreshes the list when projects are added, removed or renamed in Finder.
    private func watch(_ url: URL) {
        watcher?.cancel()
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
