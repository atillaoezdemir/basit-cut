import Foundation

enum Timecode {
    /// `m:ss.t`, or `h:mm:ss.t` from one hour on.
    static func string(_ seconds: Double) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let tenthsTotal = Int((clamped * 10).rounded(.down))
        let tenths = tenthsTotal % 10
        let total = tenthsTotal / 10
        let (hours, minutes, secs) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, secs, tenths)
            : String(format: "%d:%02d.%d", minutes, secs, tenths)
    }
}
