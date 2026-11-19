import Foundation
import BasitCutCore

/// A project package found in the projects folder.
struct ProjectEntry: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var modificationDate: Date

    var id: URL { url }
}

/// File-system rules for the projects folder: what counts as a project,
/// how new projects are named and created. No UI, no sandbox handling.
enum ProjectListing {
    static let fileExtension = "basitcut"
    static let defaultName = "Untitled"

    /// Projects directly inside `folder`, most recently changed first.
    static func entries(in folder: URL) throws -> [ProjectEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { return nil }
                return ProjectEntry(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    modificationDate: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { ($0.modificationDate, $1.name) > ($1.modificationDate, $0.name) }
    }

    /// A file-name-safe version of a user-typed project name.
    static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would make the project hidden.
        let visible = String(cleaned.drop { $0 == "." })
        return visible.isEmpty ? defaultName : visible
    }

    /// `name`, or `name 2`, `name 3`… — the first one not taken in `folder`.
    static func availableName(_ name: String, in folder: URL) -> String {
        let base = sanitized(name)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: url(for: candidate, in: folder).path(percentEncoded: false)) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// Writes an empty project named after `name` (made unique) into `folder`,
    /// with the chosen aspect ratio.
    static func createProject(named name: String, crop: CropSetting.Mode = .original, in folder: URL) throws -> URL {
        let url = url(for: availableName(name, in: folder), in: folder)
        // The crop area is centred once the first clip defines the frame.
        try ProjectDocument.encode(Project(crop: CropSetting(mode: crop))).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    static func url(for name: String, in folder: URL) -> URL {
        folder.appending(path: name, directoryHint: .isDirectory).appendingPathExtension(fileExtension)
    }
}
