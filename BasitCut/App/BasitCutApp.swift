import SwiftUI

@main
struct BasitCutApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ProjectWindow(document: file.document)
        }
    }
}
