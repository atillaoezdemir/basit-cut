import AppKit
import SwiftUI

/// Reports the `NSWindow` hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        view.onChange = onChange
    }

    final class WindowObservingView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
