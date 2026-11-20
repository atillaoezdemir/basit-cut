import AppKit
import SwiftUI

/// Reports ⌘ + scroll wheel (or ⌘ + two-finger scroll) over the view it
/// backs, as a zoom factor and the pointer's x position in the view. Those
/// scroll events are consumed, so the scroll view doesn't move as well.
struct ScrollZoomMonitor: NSViewRepresentable {
    let onZoom: (_ factor: Double, _ x: Double) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onZoom = onZoom
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onZoom: ((Double, Double) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true if the event was a zoom over this view.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  event.window === window
            else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            // A mouse wheel reports about one unit per notch; a trackpad
            // reports many small precise deltas.
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return true }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.01 : 0.12
            onZoom?(exp(delta * sensitivity), point.x)
            return true
        }
    }
}
