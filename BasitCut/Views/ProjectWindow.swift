import SwiftUI

/// Root view of a project window. Preview and timeline arrive in Phase 1.
struct ProjectWindow: View {
    @ObservedObject var document: ProjectDocument

    var body: some View {
        ContentUnavailableView(
            "No Clips Yet",
            systemImage: "film.stack",
            description: Text("Import videos to start editing.")
        )
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    ProjectWindow(document: ProjectDocument())
}
