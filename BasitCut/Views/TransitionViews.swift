import SwiftUI
import BasitCutCore

/// Where a cut and its transition sit on the timeline, in seconds.
struct CutGeometry {
    /// The clip before the cut (it owns the transition).
    var clipID: Clip.ID
    var transition: Transition?
    /// Centre of the cut or transition.
    var center: Double
    /// Range covered by the transition (empty for a hard cut).
    var range: ClosedRange<Double>

    static func all(in layout: TimelineLayout) -> [CutGeometry] {
        zip(layout.items, layout.items.dropFirst()).map { item, next in
            let cut = item.end.seconds
            switch item.clip.outgoingTransition {
            case .some(let transition) where transition.kind == .crossFade:
                let range = next.start.seconds...cut
                return CutGeometry(clipID: item.clip.id, transition: transition, center: (range.lowerBound + range.upperBound) / 2, range: range)
            case .some(let transition):
                let half = transition.duration.seconds / 2
                return CutGeometry(clipID: item.clip.id, transition: transition, center: cut, range: (cut - half)...(cut + half))
            case .none:
                return CutGeometry(clipID: item.clip.id, transition: nil, center: cut, range: cut...cut)
            }
        }
    }
}

/// Shading over the clips where a transition happens.
struct TransitionRegion: View {
    let kind: Transition.Kind

    var body: some View {
        switch kind {
        case .crossFade:
            LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.45)], startPoint: .leading, endPoint: .trailing)
                .overlay(Rectangle().strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        case .blackFade:
            LinearGradient(colors: [.clear, .black.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// The round button at a cut. A hard cut shows a small "+", a transition its icon.
struct CutBadge: View {
    let transition: Transition?
    let action: () -> Void
    @State private var isHovered = false

    static func symbol(for kind: Transition.Kind?) -> String {
        switch kind {
        case .crossFade: "square.on.square"
        case .blackFade: "circle.lefthalf.filled"
        case nil: "plus"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol(for: transition?.kind))
                .font(.system(size: transition == nil ? 8 : 10, weight: .bold))
                .foregroundStyle(transition == nil ? Color.secondary : Color.white)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(transition == nil ? AnyShapeStyle(.background.opacity(isHovered ? 1 : 0.7)) : AnyShapeStyle(Color.iconInk))
                )
                .overlay(Circle().strokeBorder(transition == nil ? .black.opacity(0.25) : .white.opacity(0.7)))
                .scaleEffect(isHovered ? 1.15 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(transition == nil ? "Add a transition" : "Edit the transition")
    }
}

/// Edits the transition at one cut: kind and duration.
struct TransitionEditor: View {
    let session: ProjectSession
    let clipID: Clip.ID
    /// Slider value while dragging; committed (one undo step) on release.
    @State private var draftDuration: Double?

    private var transition: Transition? {
        session.project.clips.first { $0.id == clipID }?.outgoingTransition
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transition").font(.headline)
            Picker("Transition", selection: Binding(
                get: { transition?.kind },
                set: { session.setTransitionKind($0, after: clipID) }
            )) {
                Text("Cut").tag(Transition.Kind?.none)
                Text("Cross Fade").tag(Transition.Kind?.some(.crossFade))
                Text("Black Fade").tag(Transition.Kind?.some(.blackFade))
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let transition {
                let maximum = max(session.maximumTransitionDuration(transition.kind, after: clipID).seconds, Transition.minimumDuration.seconds + 0.01)
                let value = draftDuration ?? transition.duration.seconds
                HStack {
                    Text("Duration")
                    Slider(
                        value: Binding(get: { value }, set: { draftDuration = ($0 * 10).rounded() / 10 }),
                        in: Transition.minimumDuration.seconds...maximum
                    ) { editing in
                        guard !editing, let draft = draftDuration else { return }
                        draftDuration = nil
                        var changed = transition
                        changed.duration = RationalTime(seconds: draft, preferredTimescale: 600)
                        session.setTransition(changed, after: clipID)
                    }
                    Text(value.formatted(.number.precision(.fractionLength(1))) + " s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Text(transition.kind == .crossFade
                     ? "The clips overlap, so the video gets shorter by the duration."
                     : "Fades to black and back. The video length doesn't change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The clips follow each other directly. The sound gets a tiny fade so it doesn't click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
