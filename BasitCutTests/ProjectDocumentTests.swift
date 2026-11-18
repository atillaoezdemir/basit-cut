import Foundation
import Testing
import BasitCutCore
@testable import BasitCut

struct ProjectDocumentTests {
    @Test func packageRoundTrip() throws {
        var project = Project()
        let source = MediaSource(
            bookmark: Data([1, 2, 3]),
            lastKnownPath: "/Videos/trip.mov",
            duration: .seconds(12),
            frameDuration: RationalTime(value: 1001, timescale: 30000),
            naturalSize: Size(width: 1920, height: 1080),
            codec: .hevc,
            videoBitrate: 20_000_000,
            hasAudio: true,
            creationDate: Date(timeIntervalSince1970: 1_600_000_000)
        )
        try TimelineEditor.insertClips(for: [source, source], in: &project)

        let wrapper = try ProjectDocument.encode(project)
        #expect(wrapper.fileWrappers?[ProjectDocument.projectFileName] != nil)
        #expect(try ProjectDocument.decode(wrapper) == project)
    }

    @Test func rejectsNewerFormatVersion() throws {
        let json = #"{"formatVersion":99,"sources":[],"clips":[],"crop":{"mode":"original","rect":{"x":0,"y":0,"width":1,"height":1}}}"#
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            ProjectDocument.projectFileName: FileWrapper(regularFileWithContents: Data(json.utf8)),
        ])
        #expect(throws: CocoaError.self) { try ProjectDocument.decode(wrapper) }
    }
}
