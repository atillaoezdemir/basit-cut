import SwiftUI

/// Play/pause, time display, edit buttons and timeline zoom.
struct TransportBar: View {
    @Bindable var session: ProjectSession

    var body: some View {
        let playback = session.playback
        HStack(spacing: 12) {
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

            Button("Import", systemImage: "plus") { session.isImporterPresented = true }
                .help("Import Videos (⌘I)")
            Button("Split", systemImage: "scissors") { session.splitAtPlayhead() }
                .help("Split at Playhead (⌘B)")
                .disabled(!session.canSplit)
            Button("Delete", systemImage: "trash") { session.deleteSelectedClips() }
                .help("Delete Selected Clips (⌫)")
                .disabled(session.selection.isEmpty)

            Button("Cover", systemImage: session.project.cover == nil ? "photo" : "photo.fill") { session.setCoverAtPlayhead() }
                .help("Set Current Frame as Cover (⇧⌘K)")

            Button("Export", systemImage: "square.and.arrow.up") { session.showExport() }
                .help("Export (⌘E)")
                .disabled(!session.canExport)

            Divider().frame(height: 18)

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { log(session.pointsPerSecond) },
                    set: { session.pointsPerSecond = exp($0) }
                ),
                in: log(ProjectSession.zoomRange.lowerBound)...log(ProjectSession.zoomRange.upperBound)
            )
            .frame(width: 120)
            .help("Timeline Zoom (⌘+ / ⌘−)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
