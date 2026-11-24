import AVFoundation
import SwiftUI
import BasitCutCore

/// Ten seconds in both export modes in one picture: Original quality left of
/// the divider, Space saving right of it.
struct ComparisonSheet: View {
    let session: ProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var player = ComparisonPlayer()
    @State private var zoom: Double = 1

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                label("Original quality", mode: .original, alignment: .leading)
                Spacer()
                label("Space saving", mode: .spaceSaving, alignment: .trailing)
            }
            ComparisonSurface(left: player.left, right: player.right, zoom: zoom)
                .frame(width: 900, height: 506)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 12) {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlayPause()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.1))
                Picker("Zoom", selection: $zoom) {
                    Text("Fit").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Drag the divider to compare. When zoomed in, scroll to move the picture. The sample is from the middle of the first video; the sizes are for the whole export.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 932)
        .onAppear {
            guard let left = session.comparison.makeItem(.original),
                  let right = session.comparison.makeItem(.spaceSaving),
                  let sample = ComparisonSample(project: session.project)
            else { return }
            player.load(left: left, right: right, duration: sample.range.duration.seconds)
        }
        .onDisappear { player.close() }
    }

    private func label(_ title: String, mode: ExportMode, alignment: HorizontalAlignment) -> some View {
        let summary = session.export.summary(for: session.project, mode: mode)
        let size = summary?.estimatedBytes.map { "about " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.headline)
            Text(([summary?.lines.last] + [size]).compactMap { $0 }.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Two players on top of each other with a draggable divider.
private struct ComparisonSurface: NSViewRepresentable {
    let left: AVPlayer
    let right: AVPlayer
    let zoom: Double

    func makeNSView(context: Context) -> ComparisonSurfaceView { ComparisonSurfaceView(left: left, right: right) }

    func updateNSView(_ view: ComparisonSurfaceView, context: Context) { view.zoom = zoom }
}

private final class ComparisonSurfaceView: NSView {
    private let leftLayer: AVPlayerLayer
    private let rightLayer: AVPlayerLayer
    private let leftClip = CALayer()
    private let divider = CALayer()
    /// Divider position, 0...1.
    private var split: CGFloat = 0.5
    /// Where the zoomed picture is moved to, in points.
    private var pan = CGPoint.zero

    var zoom: Double = 1 {
        didSet { if zoom != oldValue { needsLayout = true } }
    }

    init(left: AVPlayer, right: AVPlayer) {
        leftLayer = AVPlayerLayer(player: left)
        rightLayer = AVPlayerLayer(player: right)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .black
        layer?.masksToBounds = true
        leftClip.masksToBounds = true
        // So the picture below doesn't show through beside the video.
        leftClip.backgroundColor = .black
        leftClip.addSublayer(leftLayer)
        divider.backgroundColor = .white
        divider.shadowOpacity = 0.6
        divider.shadowRadius = 2
        [rightLayer, leftClip, divider].forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let limit = CGPoint(x: bounds.width * (zoom - 1) / 2, y: bounds.height * (zoom - 1) / 2)
        pan = CGPoint(x: min(max(pan.x, -limit.x), limit.x), y: min(max(pan.y, -limit.y), limit.y))
        let picture = bounds.insetBy(dx: -limit.x, dy: -limit.y).offsetBy(dx: pan.x, dy: pan.y)
        let x = (bounds.width * split).rounded()
        rightLayer.frame = picture
        leftClip.frame = CGRect(x: 0, y: 0, width: x, height: bounds.height)
        leftLayer.frame = picture
        divider.frame = CGRect(x: x - 1, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { moveDivider(event) }
    override func mouseDragged(with event: NSEvent) { moveDivider(event) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard zoom > 1 else { return super.scrollWheel(with: event) }
        pan.x += event.scrollingDeltaX
        pan.y -= event.scrollingDeltaY
        needsLayout = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    private func moveDivider(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        split = min(max(convert(event.locationInWindow, from: nil).x / bounds.width, 0), 1)
        needsLayout = true
    }
}
