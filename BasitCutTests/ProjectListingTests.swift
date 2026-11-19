import Foundation
import Testing
import BasitCutCore
@testable import BasitCut

struct ProjectListingTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "ProjectListingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func createsAnEmptyProjectThatOpens() throws {
        let url = try ProjectListing.createProject(named: "Trip", in: folder)
        #expect(url.lastPathComponent == "Trip.basitcut")
        let wrapper = try FileWrapper(url: url)
        #expect(try ProjectDocument.decode(wrapper) == Project())
    }

    @Test func newProjectKeepsTheChosenAspectRatio() throws {
        let url = try ProjectListing.createProject(named: "Reel", crop: .ratio9x16, in: folder)
        let project = try ProjectDocument.decode(try FileWrapper(url: url))
        #expect(project.crop.mode == .ratio9x16)
    }

    @Test func newNamesNeverOverwrite() throws {
        _ = try ProjectListing.createProject(named: "Trip", in: folder)
        _ = try ProjectListing.createProject(named: "Trip", in: folder)
        let third = try ProjectListing.createProject(named: "Trip", in: folder)
        #expect(third.lastPathComponent == "Trip 3.basitcut")
    }

    @Test func sanitizesNames() {
        #expect(ProjectListing.sanitized("  Paris/Rome: 2019 ") == "Paris-Rome- 2019")
        #expect(ProjectListing.sanitized(".hidden") == "hidden")
        #expect(ProjectListing.sanitized("   ") == "Untitled")
    }

    @Test func listsOnlyProjectsNewestFirst() throws {
        let old = try ProjectListing.createProject(named: "Old", in: folder)
        let new = try ProjectListing.createProject(named: "New", in: folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)
        try Data().write(to: folder.appending(path: "notes.txt"))
        try Data().write(to: folder.appending(path: "fake.basitcut"))   // a file, not a package

        let entries = try ProjectListing.entries(in: folder)
        #expect(entries.map(\.name) == ["New", "Old"])
    }
}
