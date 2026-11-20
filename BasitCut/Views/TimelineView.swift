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
    /// The time to keep under the pointer when zooming with ⌘ + scroll wheel
    /// (otherwise zoom keeps the playhead centred).
    @State private var zoomAnchor: (time: Double, x: Double)?
    /// The cut (identified by the clip before it) whose transition editor is open.
    @State private var editedCut: Clip.ID?

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
                // The background spans the whole content, so dragging anywhere
                // that isn't a clip (ruler, gaps, empty track) scrubs.
                Color.clear
                    .frame(width: contentWidth, height: height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                            .onChanged { session.playback.seek(to: $0.location.x / pps, exact: false) }
                            .onEnded { session.playback.seek(to: $0.location.x / pps, exact: true) }
                    )

                ruler(pps: pps, duration: layout.duration.seconds)

                ForEach(layout.items, id: \.clip.id) { item in
                    clipSlice(item, layout: layout, pps: pps)
                }

                cuts(layout: layout, pps: pps)

                if let marker = insertionMarkerX(layout: layout, pps: pps) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: 3, height: trackHeight + 8)
                        .offset(x: marker - 1.5, y: trackTop - 4)
                        .allowsHitTesting(false)
                }

                playhead(pps: pps, height: height)
            }
            .coordinateSpace(.named(Self.space))
            // One click handler for the whole timeline, so a click seeks no
            // matter what it lands on (clip body, trim handle, empty track).
            // It runs alongside the drag gestures and fails if the mouse moves.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                    handleClick(at: value.location, layout: layout, pps: pps)
                }
            )
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ClosedRange<Double>.self) { geometry in
            geometry.contentOffset.x...(geometry.contentOffset.x + geometry.containerSize.width)
        } action: { _, newValue in
            visible = newValue
            session.setTimelineWidth(newValue.upperBound - newValue.lowerBound)
        }
        .onChange(of: session.playback.displayTime) { _, time in
            keepPlayheadVisible(x: time * pps)
        }
        .onChange(of: session.pointsPerSecond) { _, newValue in
            if newValue <= session.zoomRange.lowerBound * 1.0001 {
                zoomAnchor = nil
                scrollPosition.scrollTo(x: 0)   // the whole timeline
            } else if let anchor = zoomAnchor {
                zoomAnchor = nil
                scrollPosition.scrollTo(x: max(0, anchor.time * newValue - anchor.x))
            } else {
                let width = visible.upperBound - visible.lowerBound
                scrollPosition.scrollTo(x: max(0, session.playback.displayTime * newValue - width / 2))
            }
        }
        .background(ScrollZoomMonitor { factor, x in
            let pps = session.pointsPerSecond
            zoomAnchor = (time: (visible.lowerBound + x) / pps, x: x)
            session.zoom(by: factor)
            if session.pointsPerSecond == pps { zoomAnchor = nil }   // at a zoom limit
        })
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = magnifyStart ?? session.pointsPerSecond
                    magnifyStart = start
                    session.setZoom(start * value.magnification)
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
            // Drawing only. Its hit area wouldn't follow `.offset`, so
            // scrubbing is handled by the full-width background instead.
            .allowsHitTesting(false)
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
                isSelected: session.selection.contains(item.clip.id),
                isMissing: source.map { session.library.missing.contains($0.id) } ?? true,
                colorIndex: item.index,
                showsLeadingHandle: sliceStart <= clipX,
                showsTrailingHandle: sliceEnd >= clipX + clipWidth,
                onTrimChanged: { edge, translation in
                    if !session.selection.contains(item.clip.id) { session.selectedClipID = item.clip.id }
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
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if !session.selection.contains(item.clip.id) { session.selectedClipID = item.clip.id }
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

    /// Transition shading and the button at every cut. Hidden while dragging.
    @ViewBuilder
    private func cuts(layout: TimelineLayout, pps: Double) -> some View {
        if reorder == nil {
            let margin = 40.0
            ForEach(CutGeometry.all(in: layout).filter {
                $0.range.upperBound * pps >= visible.lowerBound - margin && $0.range.lowerBound * pps <= visible.upperBound + margin
            }, id: \.clipID) { cut in
                if let transition = cut.transition {
                    TransitionRegion(kind: transition.kind)
                        .frame(width: max(2, (cut.range.upperBound - cut.range.lowerBound) * pps), height: trackHeight)
                        .offset(x: cut.range.lowerBound * pps, y: trackTop)
                        .allowsHitTesting(false)
                }
                if trim == nil {
                    CutBadge(transition: cut.transition) { editedCut = cut.clipID }
                        .popover(isPresented: Binding(
                            get: { editedCut == cut.clipID },
                            set: { if !$0 { editedCut = nil } }
                        ), arrowEdge: .bottom) {
                            TransitionEditor(session: session, clipID: cut.clipID)
                        }
                        .offset(x: cut.center * pps - 10, y: trackTop + trackHeight - 24)
                }
            }
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

    // MARK: Clicks

    private func handleClick(at location: CGPoint, layout: TimelineLayout, pps: Double) {
        let time = max(0, location.x / pps)
        if location.y >= trackTop, location.y <= trackTop + trackHeight {
            let rational = RationalTime(seconds: time, preferredTimescale: 1_000_000)
            let clicked = layout.item(at: rational)?.clip.id
            if NSEvent.modifierFlags.contains(.command) {
                if let clicked { session.toggleSelection(clicked) }
                return   // ⌘-click only changes the selection
            }
            session.selectedClipID = clicked
        } else if location.y > trackTop + trackHeight {
            session.selection = []
        }
        // A quick tolerant seek shows a nearby frame at once; the exact seek
        // queued behind it lands on the precise frame.
        session.playback.seek(to: time, exact: false)
        session.playback.seek(to: time, exact: true)
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

    /// Scrolls only when the playhead leaves the visible area (playback, arrow
    /// keys), never for a click inside the view, so the timeline doesn't jump
    /// under the mouse.
    private func keepPlayheadVisible(x: Double) {
        guard reorder == nil, trim == nil else { return }
        let width = visible.upperBound - visible.lowerBound
        guard width > 0 else { return }
        if x > visible.upperBound - 20 || x < visible.lowerBound {
            if session.playback.isPlaying {
                // Page along with playback.
                scrollPosition.scrollTo(x: max(0, x - 40))
            } else {
                // A jump: centre the playhead so it's easy to find.
                scrollPosition.scrollTo(x: max(0, x - width / 2))
            }
        }
    }
}
