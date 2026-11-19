import SwiftUI
import BasitCutCore

/// The crop rectangle drawn over the uncropped preview: drag inside to move,
/// drag a corner to resize (fixed ratios stay locked).
struct CropOverlay: View {
    @Binding var rect: NormalizedRect
    let mode: CropSetting.Mode
    let canvas: Size

    @State private var dragStart: NormalizedRect?
    private static let space = "cropOverlay"
    private let handleSize: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            content(size: geometry.size)
        }
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let box = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)

        // Dim everything outside the crop.
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(box)
        }
        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        // Rule of thirds.
        Path { path in
            for i in 1...2 {
                let x = box.minX + box.width * Double(i) / 3, y = box.minY + box.height * Double(i) / 3
                path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 0.5)
        .allowsHitTesting(false)

        Rectangle()
            .strokeBorder(.white, lineWidth: 1.5)
            .contentShape(Rectangle())
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let start = dragStart ?? rect
                        dragStart = start
                        rect = CropGeometry.moved(start, dx: value.translation.width / size.width, dy: value.translation.height / size.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )

        ForEach(CropGeometry.Corner.allCases, id: \.self) { corner in
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .shadow(radius: 1)
                .frame(width: handleSize, height: handleSize)
                .contentShape(Rectangle().inset(by: -6))
                .position(position(of: corner, in: box))
                .pointerStyle(.frameResize(position: framePosition(corner)))
                .gesture(
                    DragGesture(coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            let start = dragStart ?? rect
                            dragStart = start
                            rect = CropGeometry.resized(
                                start, corner: corner,
                                to: (x: value.location.x / size.width, y: value.location.y / size.height),
                                mode: mode, canvas: canvas
                            )
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
    }

    private func position(of corner: CropGeometry.Corner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeading: CGPoint(x: box.minX, y: box.minY)
        case .topTrailing: CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeading: CGPoint(x: box.minX, y: box.maxY)
        case .bottomTrailing: CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    private func framePosition(_ corner: CropGeometry.Corner) -> FrameResizePosition {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/// The bar above the preview while cropping: ratio, output size, Done/Cancel.
struct CropBar: View {
    let session: ProjectSession

    var body: some View {
        if let draft = session.cropDraft {
            HStack(spacing: 12) {
                Label("Crop", systemImage: "crop").font(.headline)
                Picker("Aspect Ratio", selection: Binding(
                    get: { draft.mode },
                    set: { session.beginCropEditing($0) }
                )) {
                    ForEach(CropSetting.Mode.allCases.filter { $0 != .original }, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let size = session.cropDraftOutputSize {
                    Text("\(Int(size.width))×\(Int(size.height))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { session.resetCropDraft() }
                Button("Cancel", role: .cancel) { session.finishCropEditing(apply: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { session.finishCropEditing(apply: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
