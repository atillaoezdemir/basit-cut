import SwiftUI
import BasitCutCore

/// Play/pause, time display, edit buttons and timeline zoom.
struct TransportBar: View {
    @Bindable var session: ProjectSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let playback = session.playback
        HStack(spacing: 12) {
            Button("Projects", systemImage: "rectangle.stack") { openWindow(id: ProjectsWindow.id) }
                .help("Show Projects (⇧⌘P)")

            Divider().frame(height: 18)

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .help("Play/Pause (Space)")
            .disabled(playback.duration == 0)

            Text("\(Timecode.string(playback.displayTime)) / \(Timecode.string(playback.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if playback.isFastForwarding {
                Text("2×").font(.caption.bold()).foregroundStyle(.orange)
            }

            Spacer()

            Button("Split", systemImage: "scissors") { session.splitAtPlayhead() }
                .help("Split at Playhead (⌘B)")
                .disabled(!session.canSplit)

            Button("Crop", systemImage: "crop") { session.beginCropEditing() }
                .help("Aspect Ratio and Crop")
                .disabled(!session.canCrop)

            Button("Cover", systemImage: session.project.cover == nil ? "photo" : "photo.fill") { session.setCoverAtPlayhead() }
                .help("Set Current Frame as Cover (⇧⌘K)")

            Button("Export", systemImage: "square.and.arrow.up") { session.showExport() }
                .help("Export (⌘E)")
                .disabled(!session.canExport)

            Divider().frame(height: 18)

            Button("Zoom Out", systemImage: "minus.magnifyingglass") { session.zoom(by: 1 / 1.5) }
                .help("Zoom Out (⌘−)")
                .disabled(session.pointsPerSecond <= session.zoomRange.lowerBound * 1.0001)
            Slider(
                value: Binding(
                    get: { log(session.pointsPerSecond) },
                    set: { session.setZoom(exp($0)) }
                ),
                in: log(session.zoomRange.lowerBound)...log(session.zoomRange.upperBound)
            )
            .frame(width: 120)
            .help("Timeline Zoom (⌘+ / ⌘−); all the way left shows the whole timeline")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { session.zoom(by: 1.5) }
                .help("Zoom In (⌘+)")
                .disabled(session.pointsPerSecond >= session.zoomRange.upperBound * 0.9999)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
