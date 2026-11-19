import SwiftUI

struct SettingsView: View {
    @AppStorage(KeyboardController.fastForwardKeyDefaultsKey)
    private var fastForwardKey = KeyboardController.defaultFastForwardKey

    @State private var projects = ProjectsFolder.shared

    private let keys = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    var body: some View {
        Form {
            LabeledContent("Projects folder:") {
                HStack {
                    Text(projects.url?.path(percentEncoded: false) ?? "Not chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(projects.url == nil ? .secondary : .primary)
                    Button("Change…") { projects.choose() }
                }
            }
            Text("New projects are created here, and the Projects window lists the projects in it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Picker("Hold for 2× playback:", selection: $fastForwardKey) {
                ForEach(keys, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            Text("While this key is held, the preview plays at double speed. Export is not affected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}
