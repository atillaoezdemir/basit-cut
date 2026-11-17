import UniformTypeIdentifiers

extension UTType {
    /// A basit-cut project: a package containing `project.json` and an optional cover image.
    /// Declared as an exported type in Info.plist.
    static let basitCutProject = UTType(exportedAs: "io.github.atillaoezdemir.basitcut.project")
}
