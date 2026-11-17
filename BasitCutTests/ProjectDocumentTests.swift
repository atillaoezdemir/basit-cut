import Testing
@testable import BasitCut

@Test func packageRoundTrip() throws {
    let original = ProjectFile()
    let wrapper = try ProjectDocument.encode(original)
    #expect(wrapper.fileWrappers?[ProjectDocument.projectFileName] != nil)
    #expect(try ProjectDocument.decode(wrapper) == original)
}
