import SwiftUI
import BasitCutCore

extension Color {
    /// The dark blue of the app icon's playhead.
    static let iconInk = Color(red: 0.106, green: 0.125, blue: 0.188)
}

/// One clip (or the visible slice of it) on the timeline, with trim handles.
struct ClipView: View {
    let name: String
    let duration: Double
    let isSelected: Bool
    let isMissing: Bool
    let colorIndex: Int
    let showsLeadingHandle: Bool
    let showsTrailingHandle: Bool
    /// Translation in points while dragging a handle.
    let onTrimChanged: (TimelineEditor.Edge, Double) -> Void
    let onTrimEnded: (TimelineEditor.Edge, Double) -> Void

    private var isBlue: Bool { colorIndex.isMultiple(of: 2) }

    /// Neighbouring clips alternate between the app icon's two colors.
    private var fill: LinearGradient {
        let colors: [Color] = if isMissing { [.gray, .gray.opacity(0.8)] }
        else if isBlue { [Color(red: 0.298, green: 0.553, blue: 1), Color(red: 0.141, green: 0.388, blue: 0.922)] }
        else { [Color(red: 1, green: 0.761, blue: 0.294), Color(red: 1, green: 0.604, blue: 0.122)] }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// Dark on the light amber clips, where white would be hard to read.
    private var textColor: Color {
        isMissing || isBlue ? .white : .iconInk
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.primary : Color.black.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.weight(.medium))
                Text(Timecode.string(duration)).font(.caption2).opacity(0.75)
            }
            .lineLimit(1)
            .foregroundStyle(textColor)
            .padding(.horizontal, 10)

            HStack(spacing: 0) {
                if showsLeadingHandle { handle(.leading) }
                Spacer(minLength: 0)
                if showsTrailingHandle { handle(.trailing) }
            }
        }
        .clipped()
    }

    private func handle(_ edge: TimelineEditor.Edge) -> some View {
        TrimHandle(isSelected: isSelected)
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onTrimChanged(edge, $0.translation.width) }
                    .onEnded { onTrimEnded(edge, $0.translation.width) }
            )
    }
}

private struct TrimHandle: View {
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(isHovered || isSelected ? 0.35 : 0.001))
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
