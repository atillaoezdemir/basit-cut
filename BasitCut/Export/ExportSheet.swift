import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BasitCutCore

private struct CoverKey: Equatable {
    var cover: CoverFrame?
    var crop: CropSetting
}

/// The export dialog: mode, summary, output location, progress and cancel.
struct ExportSheet: View {
    @Bindable var session: ProjectSession
    let defaultName: String
    @Environment(\.dismiss) private var dismiss
    @State private var coverThumbnail: CGImage?

    private var export: ExportController { session.export }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())

            switch export.phase {
            case .idle:
                modeSelection
            case .exporting(let progress):
                exporting(progress)
            case .finished(let url):
                finished(url)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(export.isExporting)
        .task(id: CoverKey(cover: session.project.cover, crop: session.project.crop)) {
            coverThumbnail = await session.coverThumbnail()
        }
    }

    // MARK: Phases

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Quality", selection: Bindable(export).mode) {
                Text("Original quality").tag(ExportMode.original)
                Text("Space saving").tag(ExportMode.spaceSaving)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(export.mode == .original
                 ? "Same codec, resolution, frame rate and bitrate as the source."
                 : "HEVC at up to 4000 kbps, at most 1080p. Much smaller files.")
                .foregroundStyle(.secondary)

            framing

            if let summary = export.summary(for: session.project, mode: export.mode) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.lines.filter { !$0.isEmpty }, id: \.self) { Text($0) }
                    if let bytes = summary.estimatedBytes {
                        Text("About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("The recording date and location of the first clip are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.project.clips.isEmpty)
            }
        }
    }

    /// The cover that will be embedded (set from the preview).
    private var framing: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Cover").gridColumnAlignment(.trailing)
                HStack(spacing: 10) {
                    if session.project.cover != nil {
                        Group {
                            if let coverThumbnail {
                                Image(decorative: coverThumbnail, scale: 1).resizable().scaledToFit()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button("Remove") { session.removeCover() }
                    } else {
                        Text("None. Choose a frame with Clip → Set Current Frame as Cover.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func exporting(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: progress) {
                Text("Exporting…")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
            }
            HStack {
                Spacer()
                Button("Cancel Export", role: .cancel) { export.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported “\(url.lastPathComponent)”.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") {
                    export.reset()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The export failed.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") {
                    export.reset()
                    dismiss()
                }
                Button("Try Again") { export.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Output location

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = defaultName + ".mov"
        panel.canCreateDirectories = true
        // Exports usually go to the same place: open where the last one went.
        // (No existence check: the sandbox may hide the folder from the app,
        // and the panel itself falls back if it's gone.)
        panel.directoryURL = ExportController.lastDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ExportController.lastDirectory = url.deletingLastPathComponent()
        session.startExport(to: url)
    }
}
