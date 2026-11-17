import SwiftUI
import UniformTypeIdentifiers
import BasitCutCore

/// Placeholder on-disk representation. Replaced by `BasitCutCore.Project` in Phase 1.
struct ProjectFile: Codable, Equatable, Sendable {
    var formatVersion: Int = BasitCutCore.projectFormatVersion
}

/// A basit-cut project document, stored as a `.basitcut` package.
///
/// The package only holds references to source videos and edit decisions;
/// source files are never written.
final class ProjectDocument: ReferenceFileDocument, @unchecked Sendable {
    static let projectFileName = "project.json"

    static var readableContentTypes: [UTType] { [.basitCutProject] }

    @Published var project: ProjectFile

    init() {
        project = ProjectFile()
    }

    required init(configuration: ReadConfiguration) throws {
        project = try Self.decode(configuration.file)
    }

    func snapshot(contentType: UTType) throws -> ProjectFile {
        project
    }

    func fileWrapper(snapshot: ProjectFile, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.encode(snapshot)
    }

    // MARK: Package I/O

    static func encode(_ project: ProjectFile) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = FileWrapper(regularFileWithContents: try encoder.encode(project))
        return FileWrapper(directoryWithFileWrappers: [projectFileName: json])
    }

    static func decode(_ package: FileWrapper) throws -> ProjectFile {
        guard package.isDirectory,
              let data = package.fileWrappers?[projectFileName]?.regularFileContents
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(ProjectFile.self, from: data)
    }
}
