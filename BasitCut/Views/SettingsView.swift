import SwiftUI

struct SettingsView: View {
    @AppStorage(KeyboardController.fastForwardKeyDefaultsKey)
    private var fastForwardKey = KeyboardController.defaultFastForwardKey

    private let keys = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    var body: some View {
        Form {
            Picker("Hold for 2× playback:", selection: $fastForwardKey) {
                ForEach(keys, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            Text("While this key is held, the preview plays at double speed. Export is not affected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
