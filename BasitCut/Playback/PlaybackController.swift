import AVFoundation
import Observation
import BasitCutMedia

/// Wraps `AVPlayer` for the preview: play/pause, hold-for-2× and responsive seeking.
///
/// Seeking keeps at most one seek in flight; newer requests replace the queued
/// one. While a key is held, seeks are tolerant (fast, lands near a keyframe);
/// `finishSeeking()` does one exact seek at the end.
@MainActor
@Observable
final class PlaybackController {
    @ObservationIgnored let player = AVPlayer()

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isFastForwarding = false
    /// Why the current composition can't be played (e.g. a source file became
    /// unreadable after it was loaded), or nil.
    private(set) var error: String?

    /// The time the user asked for; ahead of the player while a seek is pending.
    var displayTime: Double {
        // Read both properties unconditionally: a view must depend on both, or
        // it would stop updating after being drawn while a seek was pending.
        let target = seekTarget
        let current = currentTime
        return target ?? current
    }

    private var seekTarget: Double?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var queuedSeek: (time: Double, exact: Bool)?
    @ObservationIgnored private var lastSeekTime: Double = 0
    @ObservationIgnored private var wasPausedBeforeFastForward = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    static let fastRate: Float = 2

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.timeDidChange(time) }
        }
    }

    /// Shows a new composition, keeping the playhead position.
    func load(_ built: BuiltComposition?) {
        let keepTime = displayTime
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver = nil
        error = nil

        guard let built else {
            pause()
            player.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            seekTarget = nil
            return
        }
        let item = built.makePlayerItem()
        player.replaceCurrentItem(with: item)
        duration = built.layout.duration.seconds
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The video can’t be played."
            Task { @MainActor in
                guard self?.player.currentItem === item else { return }
                self?.pause()
                self?.error = message
            }
        }
        seek(to: keepTime, exact: true)
        if isPlaying { player.rate = currentRate }
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.currentItem != nil, duration > 0 else { return }
        if displayTime >= duration - 0.05 { seek(to: 0, exact: true) }
        isPlaying = true
        player.rate = currentRate
    }

    func pause() {
        isPlaying = false
        player.pause()
        // While paused, the playhead only moves by seeking; take the exact
        // position playback stopped at.
        let time = player.currentTime()
        if seekTarget == nil, time.isNumeric { currentTime = min(max(time.seconds, 0), duration) }
    }

    /// Hold-to-fast-forward started. Playback runs at 2× until `endFastPlayback()`.
    func beginFastPlayback() {
        guard !isFastForwarding, player.currentItem != nil else { return }
        isFastForwarding = true
        wasPausedBeforeFastForward = !isPlaying
        if isPlaying { player.rate = Self.fastRate } else { play() }
    }

    /// Back to 1×, or paused again if playback was paused before.
    func endFastPlayback() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        if wasPausedBeforeFastForward {
            pause()
        } else if isPlaying {
            player.rate = 1
        }
    }

    // MARK: Seeking

    /// Relative jump from the playhead (arrow keys).
    func jump(by delta: Double, exact: Bool) {
        seek(to: displayTime + delta, exact: exact)
    }

    /// Exact seek to the current target (on key release / end of scrubbing).
    func finishSeeking() {
        seek(to: displayTime, exact: true)
    }

    func seek(to time: Double, exact: Bool) {
        let clamped = min(max(time, 0), duration)
        seekTarget = clamped
        currentTime = clamped
        if seekInFlight {
            queuedSeek = (clamped, exact)
        } else {
            performSeek(to: clamped, exact: exact)
        }
    }

    func invalidate() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Private

    private var currentRate: Float { isFastForwarding ? Self.fastRate : 1 }

    private func performSeek(to time: Double, exact: Bool) {
        seekInFlight = true
        lastSeekTime = time
        let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 2)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 90_000),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in self?.seekDidFinish() }
        }
    }

    private func seekDidFinish() {
        seekInFlight = false
        if let next = queuedSeek {
            queuedSeek = nil
            performSeek(to: next.time, exact: next.exact)
        } else {
            // The playhead stays where it was asked to go. A tolerant seek may
            // show a frame up to half a second away (often the start of a clip
            // in the composition); reading that back would make the next jump
            // start from the wrong place and get stuck at cuts.
            currentTime = lastSeekTime
            seekTarget = nil
        }
    }

    private func timeDidChange(_ time: CMTime) {
        // Only playback moves the playhead. The observer also fires when a
        // seek lands, with the frame it landed on, which would undo the above.
        guard isPlaying, seekTarget == nil, time.isNumeric else { return }
        currentTime = time.seconds
    }

    private func didReachEnd() {
        isPlaying = false
        currentTime = duration
    }
}
