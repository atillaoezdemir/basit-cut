import SwiftUI
import BasitCutCore

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

    private var color: Color {
        if isMissing { return .gray }
        return colorIndex.isMultiple(of: 2) ? .blue : .indigo
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.gradient)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.yellow : Color.black.opacity(0.3), lineWidth: isSelected ? 2 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.weight(.medium))
                Text(Timecode.string(duration)).font(.caption2).opacity(0.75)
            }
            .lineLimit(1)
            .foregroundStyle(.white)
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
