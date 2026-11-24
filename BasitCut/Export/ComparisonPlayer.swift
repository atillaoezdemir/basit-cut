import AVFoundation
import Observation

/// Plays two versions of the same footage in step, over and over.
@MainActor
@Observable
final class ComparisonPlayer {
    let left = AVPlayer()
    let right = AVPlayer()
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var queuedSeek: Double?

    func load(left leftItem: AVPlayerItem, right rightItem: AVPlayerItem, duration: Double) {
        self.duration = duration
        for (player, item) in [(left, leftItem), (right, rightItem)] {
            player.isMuted = true
            // Needed to start both at one exact moment.
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
            player.replaceCurrentItem(with: item)
        }
        timeObserver = left.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.time = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: leftItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == true { self?.play(from: 0) } }
        }
        play(from: 0)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play(from: time >= duration - 0.05 ? 0 : time)
    }

    func play(from start: Double) {
        startTask?.cancel()
        isPlaying = true
        left.pause()
        right.pause()
        startTask = Task { [left, right] in
            for player in [left, right] {
                while player.currentItem?.status == .unknown {
                    try? await Task.sleep(for: .milliseconds(20))
                    if Task.isCancelled { return }
                }
            }
            await Self.seek(left, to: start)
            await Self.seek(right, to: start)
            guard !Task.isCancelled else { return }
            let at = CMTime(seconds: start, preferredTimescale: 90_000)
            let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 10)
            left.setRate(1, time: at, atHostTime: host)
            right.setRate(1, time: at, atHostTime: host)
        }
    }

    func pause() {
        startTask?.cancel()
        isPlaying = false
        left.pause()
        right.pause()
        seek(to: left.currentTime().seconds)   // the same frame on both sides
    }

    /// Shows the frame at `target` on both sides (paused).
    func seek(to target: Double) {
        if isPlaying {
            startTask?.cancel()
            isPlaying = false
            left.pause()
            right.pause()
        }
        time = min(max(target, 0), duration)
        guard !isSeeking else { queuedSeek = time; return }
        isSeeking = true
        Task {
            var next: Double? = time
            while let current = next {
                queuedSeek = nil
                await Self.seek(left, to: current)
                await Self.seek(right, to: current)
                next = queuedSeek
            }
            isSeeking = false
        }
    }

    func close() {
        startTask?.cancel()
        if let timeObserver { left.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        for player in [left, right] {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private static func seek(_ player: AVPlayer, to seconds: Double) async {
        _ = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
