import AppKit

/// Preview keyboard controls for one project window.
///
/// - `Space`: play/pause
/// - hold the fast-forward key (default `L`, see Settings): 2× while held
/// - `←`/`→` jump 5 s, `⇧←`/`⇧→` jump 30 s; holding keeps jumping
/// - `⌘A`: select all clips
///
/// Uses a local `NSEvent` monitor because SwiftUI has no key-up events. Events
/// are only handled while this window is key and no text field has focus;
/// shortcuts with ⌘/⌃/⌥ pass through to the menus.
@MainActor
final class KeyboardController {
    static let fastForwardKeyDefaultsKey = "fastForwardKey"
    static let defaultFastForwardKey = "l"

    /// Jumps per second while an arrow key is held, after an initial delay.
    private static let repeatInterval: TimeInterval = 0.125
    private static let repeatDelay: TimeInterval = 0.3

    private let playback: PlaybackController
    private weak var window: NSWindow?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var jumpTimer: Timer?
    private var jumpDirection: Double = 0
    /// ⌘A outside text fields selects all clips.
    var onSelectAll: (() -> Void)?

    init(playback: PlaybackController) {
        self.playback = playback
    }

    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        detach()
        guard let window else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseHeldKeys() }
        }
    }

    func detach() {
        releaseHeldKeys()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        window = nil
    }

    private var fastForwardKey: String {
        UserDefaults.standard.string(forKey: Self.fastForwardKeyDefaultsKey) ?? Self.defaultFastForwardKey
    }

    /// Returns `nil` for consumed events.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, !(window.firstResponder is NSText) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, modifiers == .command, event.charactersIgnoringModifiers == "a", let onSelectAll {
            onSelectAll()
            return nil
        }
        guard modifiers.subtracting(.shift).isEmpty else { return event }
        let isDown = event.type == .keyDown

        switch event.keyCode {
        case 49: // Space
            if isDown && !event.isARepeat { playback.togglePlayPause() }
            return nil
        case 123, 124: // ← →
            let direction: Double = event.keyCode == 123 ? -1 : 1
            if isDown {
                if !event.isARepeat { startJumping(direction) }
            } else if direction == jumpDirection {
                stopJumping()
            }
            return nil
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == fastForwardKey else { return event }
            if isDown {
                if !event.isARepeat { playback.beginFastPlayback() }
            } else {
                playback.endFastPlayback()
            }
            return nil
        }
    }

    // MARK: Held arrow keys

    private func startJumping(_ direction: Double) {
        jumpTimer?.invalidate()
        jumpDirection = direction
        jumpOnce(exact: true)
        // Own timer instead of the system key repeat: same speed for everyone.
        let timer = Timer(fire: Date(timeIntervalSinceNow: Self.repeatDelay), interval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.jumpOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        jumpTimer = timer
    }

    /// A single press seeks exactly; repeats while held are tolerant (fast)
    /// and end with one exact seek on release.
    private func jumpOnce(exact: Bool = false) {
        // Shift is read live, so pressing/releasing it mid-hold switches the step.
        let step: Double = NSEvent.modifierFlags.contains(.shift) ? 30 : 5
        playback.jump(by: jumpDirection * step, exact: exact)
    }

    private func stopJumping() {
        guard jumpTimer != nil else { return }
        jumpTimer?.invalidate()
        jumpTimer = nil
        jumpDirection = 0
        playback.finishSeeking()
    }

    private func releaseHeldKeys() {
        stopJumping()
        playback.endFastPlayback()
    }
}
