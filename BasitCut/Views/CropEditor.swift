import SwiftUI
import BasitCutCore

/// Positions and resizes the crop over the uncropped frame at the playhead.
/// Changes apply to the project (one undo step) when Done is pressed.
struct CropEditor: View {
    let session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    @State private var mode: CropSetting.Mode = .free
    @State private var rect: NormalizedRect = .full
    @State private var frame: CGImage?
    @State private var dragStart: NormalizedRect?

    private static let space = "crop"
    private let handleSize: CGFloat = 14

    private var canvas: Size { session.project.canvasSize ?? Size(width: 16, height: 9) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Crop").font(.title3.bold())
                Spacer()
                Picker("Aspect Ratio", selection: Binding(get: { mode }, set: { changeMode($0) })) {
                    ForEach(CropSetting.Mode.allCases.filter { $0 != .original }, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            ZStack {
                Color.black
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                } else {
                    ProgressView()
                }
                GeometryReader { geometry in
                    overlay(size: geometry.size)
                }
                .coordinateSpace(.named(Self.space))
            }
            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
            .frame(maxWidth: 620, maxHeight: 420)
            .frame(maxWidth: .infinity)

            Text(sizeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset") { rect = CropGeometry.setting(for: mode, canvas: canvas).rect }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    session.setCrop(CropSetting(mode: mode, rect: rect))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            let crop = session.project.crop
            mode = crop.mode == .original ? .free : crop.mode
            rect = CropGeometry.clamped(crop.rect, mode: mode, canvas: canvas)
            frame = await session.uncroppedFrame()
        }
    }

    private var sizeDescription: String {
        var project = session.project
        project.crop = CropSetting(mode: mode, rect: rect)
        guard let size = project.renderSize else { return "" }
        return "Output: \(Int(size.width))×\(Int(size.height))"
    }

    private func changeMode(_ newMode: CropSetting.Mode) {
        mode = newMode
        rect = CropGeometry.setting(for: newMode, canvas: canvas, current: rect).rect
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlay(size: CGSize) -> some View {
        let box = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)

        // Dim everything outside the crop.
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(box)
        }
        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        // Rule of thirds and border.
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
            let point = position(of: corner, in: box)
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .shadow(radius: 1)
                .frame(width: handleSize, height: handleSize)
                .contentShape(Rectangle().inset(by: -6))
                .position(point)
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
