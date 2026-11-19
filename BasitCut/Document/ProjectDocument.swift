import SwiftUI
import UniformTypeIdentifiers
import BasitCutCore

/// A basit-cut project document, stored as a `.basitcut` package.
///
/// The package only holds references to source videos and edit decisions;
/// source files are never written. All edits go through `editor`, whose undo
/// registrations mark the document as edited and trigger autosave.
@MainActor
final class ProjectDocument: ReferenceFileDocument {
    nonisolated static let projectFileName = "project.json"

    nonisolated static var readableContentTypes: [UTType] { [.basitCutProject] }

    let editor: ProjectEditor

    nonisolated init() {
        editor = ProjectEditor()
    }

    nonisolated required init(configuration: ReadConfiguration) throws {
        editor = ProjectEditor(project: try Self.decode(configuration.file))
    }

    // Called on a background queue during autosave, so it must not touch
    // main-actor state.
    nonisolated func snapshot(contentType: UTType) throws -> Project {
        editor.currentSnapshot
    }

    nonisolated func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.encode(snapshot)
    }

    // MARK: Package I/O

    nonisolated static func encode(_ project: Project) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = FileWrapper(regularFileWithContents: try encoder.encode(project))
        return FileWrapper(directoryWithFileWrappers: [projectFileName: json])
    }

    nonisolated static func decode(_ package: FileWrapper) throws -> Project {
        guard package.isDirectory,
              let data = package.fileWrappers?[projectFileName]?.regularFileContents
        else {
            throw ProjectFileError.damaged
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Check the version first: a newer format may not decode at all.
        if let header = try? decoder.decode(FormatHeader.self, from: data),
           header.formatVersion > Project.currentFormatVersion {
            throw ProjectFileError.newerFormat
        }
        do {
            return try decoder.decode(Project.self, from: data)
        } catch {
            throw ProjectFileError.damaged
        }
    }

    private struct FormatHeader: Decodable {
        var formatVersion: Int
    }
}

/// Why a project file can't be opened.
enum ProjectFileError: LocalizedError, Equatable {
    case damaged
    case newerFormat

    var errorDescription: String? {
        switch self {
        case .damaged: "The project file is damaged or isn’t a basit-cut project."
        case .newerFormat: "This project was saved by a newer version of basit-cut."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .damaged: "The source videos aren’t affected. Create a new project and import them again."
        case .newerFormat: "Update basit-cut to open it."
        }
    }
}
