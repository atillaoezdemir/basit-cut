import Testing
@testable import BasitCutMedia

@Test func importableTypesIncludeQuickTime() {
    #expect(BasitCutMedia.importableTypeIdentifiers.contains("com.apple.quicktime-movie"))
}
