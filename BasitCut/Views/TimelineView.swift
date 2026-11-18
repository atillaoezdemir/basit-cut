import SwiftUI
import BasitCutCore

/// The single-track timeline: ruler, clips, playhead.
///
/// Only the visible part of the timeline is rendered (clips are sliced to the
/// visible range), so long projects at high zoom never create huge views.
struct TimelineView: View {
    @Bindable var session: ProjectSession

    @State private var visible: ClosedRange<Double> = 0...2000
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var reorder: ReorderDrag?
    @State private var trim: TrimDrag?
    @State private var magnifyStart: Double?

    private static let space = "timeline"
    private let rulerHeight: Double = 22
    private let trackTop: Double = 30
    private let trackHeight: Double = 64

    private struct ReorderDrag {
        var clipID: Clip.ID
        var translation: Double
    }

    private struct TrimDrag {
        var clipID: Clip.ID
        var edge: TimelineEditor.Edge
        var translation: Double
    }

    var body: some View {
        let layout = TimelineLayout(project: displayedProject)
        let pps = session.pointsPerSecond
        let contentWidth = max(layout.duration.seconds * pps + 400, visible.upperBound - visible.lowerBound)
        let height = trackTop + trackHeight + 10

        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: contentWidth, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                        session.selectedClipID = nil
                        session.playback.seek(to: location.x / pps, exact: true)
                    }

                ruler(pps: pps, duration: layout.duration.seconds)

                ForEach(layout.items, id: \.clip.id) { item in
                    clipSlice(item, layout: layout, pps: pps)
                }

                if let marker = insertionMarkerX(layout: layout, pps: pps) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: 3, height: trackHeight + 8)
                        .offset(x: marker - 1.5, y: trackTop - 4)
                        .allowsHitTesting(false)
                }

                playhead(pps: pps, height: height)
            }
            .coordinateSpace(.named(Self.space))
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ClosedRange<Double>.self) { geometry in
            geometry.contentOffset.x...(geometry.contentOffset.x + geometry.containerSize.width)
        } action: { _, newValue in
            visible = newValue
        }
        .onChange(of: session.playback.displayTime) { _, time in
            keepPlayheadVisible(x: time * pps)
        }
        .onChange(of: session.pointsPerSecond) { _, newValue in
            let width = visible.upperBound - visible.lowerBound
            scrollPosition.scrollTo(x: max(0, session.playback.displayTime * newValue - width / 2))
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = magnifyStart ?? session.pointsPerSecond
                    magnifyStart = start
                    session.pointsPerSecond = min(max(start * value.magnification, ProjectSession.zoomRange.lowerBound), ProjectSession.zoomRange.upperBound)
                }
                .onEnded { _ in magnifyStart = nil }
        )
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Project shown while dragging

    /// The project with an in-progress trim applied, so the timeline previews it live.
    private var displayedProject: Project {
        let project = session.project
        guard let trim, let clip = project.clips.first(where: { $0.id == trim.clipID }) else { return project }
        var preview = project
        try? TimelineEditor.trim(clip: trim.clipID, edge: trim.edge, to: trimTarget(trim, clip: clip), in: &preview)
        return preview
    }

    private func trimTarget(_ trim: TrimDrag, clip: Clip) -> RationalTime {
        let base = trim.edge == .leading ? clip.sourceRange.start : clip.sourceRange.end
        return base + RationalTime(seconds: trim.translation / session.pointsPerSecond, preferredTimescale: 1_000_000)
    }

    // MARK: Pieces

    private func ruler(pps: Double, duration: Double) -> some View {
        let start = max(0, visible.lowerBound)
        let width = max(1, visible.upperBound - start)
        return RulerView(startX: start, pointsPerSecond: pps, duration: duration)
            .frame(width: width, height: rulerHeight)
            .offset(x: start)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { session.playback.seek(to: $0.location.x / pps, exact: false) }
                    .onEnded { session.playback.seek(to: $0.location.x / pps, exact: true) }
            )
    }

    @ViewBuilder
    private func clipSlice(_ item: TimelineLayout.Item, layout: TimelineLayout, pps: Double) -> some View {
        let clipX = item.start.seconds * pps
        let clipWidth = max(2, item.clip.duration.seconds * pps)
        let dragOffset = reorder?.clipID == item.clip.id ? reorder!.translation : 0
        // Render only the visible part (with some margin).
        let margin = 400.0
        let sliceStart = max(clipX, visible.lowerBound - margin - dragOffset)
        let sliceEnd = min(clipX + clipWidth, visible.upperBound + margin - dragOffset)

        if sliceEnd > sliceStart {
            let source = session.project.source(id: item.clip.sourceID)
            ClipView(
                name: source?.displayName ?? "Missing",
                duration: item.clip.duration.seconds,
                isSelected: session.selectedClipID == item.clip.id,
                isMissing: source.map { session.library.missing.contains($0.id) } ?? true,
                colorIndex: item.index,
                showsLeadingHandle: sliceStart <= clipX,
                showsTrailingHandle: sliceEnd >= clipX + clipWidth,
                onTrimChanged: { edge, translation in
                    session.selectedClipID = item.clip.id
                    trim = TrimDrag(clipID: item.clip.id, edge: edge, translation: translation)
                },
                onTrimEnded: { edge, translation in
                    let committed = TrimDrag(clipID: item.clip.id, edge: edge, translation: translation)
                    if let clip = session.project.clips.first(where: { $0.id == item.clip.id }) {
                        session.trimClip(item.clip.id, edge: edge, to: trimTarget(committed, clip: clip))
                    }
                    trim = nil
                }
            )
            .frame(width: sliceEnd - sliceStart, height: trackHeight)
            .offset(x: sliceStart + dragOffset, y: trackTop)
            .opacity(dragOffset != 0 ? 0.8 : 1)
            .zIndex(dragOffset != 0 ? 1 : 0)
            .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                session.selectedClipID = item.clip.id
                session.playback.seek(to: location.x / pps, exact: true)
            }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        session.selectedClipID = item.clip.id
                        reorder = ReorderDrag(clipID: item.clip.id, translation: value.translation.width)
                    }
                    .onEnded { value in
                        let drag = ReorderDrag(clipID: item.clip.id, translation: value.translation.width)
                        if let destination = destinationIndex(for: drag, layout: layout, pps: pps),
                           destination != item.index {
                            session.moveClip(item.clip.id, to: destination)
                        }
                        reorder = nil
                    }
            )
        }
    }

    private func playhead(pps: Double, height: Double) -> some View {
        let x = session.playback.displayTime * pps
        return ZStack(alignment: .top) {
            Rectangle().fill(.red).frame(width: 1.5, height: height)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .offset(y: -2)
        }
        .frame(width: 12)
        .offset(x: x - 6)
        .allowsHitTesting(false)
    }

    // MARK: Reorder geometry

    /// Final index of the dragged clip: how many other clips have their centre
    /// left of the dragged clip's centre.
    private func destinationIndex(for drag: ReorderDrag, layout: TimelineLayout, pps: Double) -> Int? {
        guard let item = layout.item(id: drag.clipID) else { return nil }
        let center = (item.start.seconds + item.clip.duration.seconds / 2) * pps + drag.translation
        return layout.items
            .filter { $0.clip.id != drag.clipID }
            .filter { ($0.start.seconds + $0.clip.duration.seconds / 2) * pps < center }
            .count
    }

    private func insertionMarkerX(layout: TimelineLayout, pps: Double) -> Double? {
        guard let reorder, let item = layout.item(id: reorder.clipID),
              let destination = destinationIndex(for: reorder, layout: layout, pps: pps),
              destination != item.index
        else { return nil }
        let others = layout.items.filter { $0.clip.id != reorder.clipID }
        // Position in a layout where the dragged clip is removed.
        let remaining = TimelineLayout(clips: others.map(\.clip))
        return destination < remaining.items.count
            ? remaining.items[destination].start.seconds * pps
            : remaining.duration.seconds * pps
    }

    private func keepPlayheadVisible(x: Double) {
        guard reorder == nil, trim == nil else { return }
        let width = visible.upperBound - visible.lowerBound
        guard width > 0 else { return }
        if x > visible.upperBound - 20 {
            scrollPosition.scrollTo(x: max(0, x - 40))
        } else if x < visible.lowerBound {
            scrollPosition.scrollTo(x: max(0, x - width + 40))
        }
    }
}
