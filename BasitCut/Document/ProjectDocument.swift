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

    nonisolated func snapshot(contentType: UTType) throws -> Project {
        MainActor.assumeIsolated { editor.project }
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
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        guard project.formatVersion <= Project.currentFormatVersion else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return project
    }
}
