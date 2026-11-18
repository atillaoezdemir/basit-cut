import SwiftUI

/// Time ruler for the visible part of the timeline, starting at `startX`.
struct RulerView: View {
    let startX: Double
    let pointsPerSecond: Double
    let duration: Double

    /// Smallest label interval that leaves at least ~80 pt between labels.
    private var majorInterval: Double {
        [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
            .first { $0 * pointsPerSecond >= 80 } ?? 3600
    }

    var body: some View {
        Canvas { context, size in
            let major = majorInterval
            let minor = major / 5
            // Count ticks with an integer index: adding `minor` repeatedly
            // drifts and produces labels like 0:03.9.
            var index = Int((startX / pointsPerSecond / minor).rounded(.down))
            while Double(index) * minor * pointsPerSecond - startX <= size.width {
                let time = Double(index) * minor
                let x = time * pointsPerSecond - startX
                let isMajor = index.isMultiple(of: 5)
                let tickHeight = isMajor ? size.height * 0.5 : size.height * 0.25
                context.fill(
                    Path(CGRect(x: x, y: size.height - tickHeight, width: 1, height: tickHeight)),
                    with: .color(time <= duration ? .secondary : .secondary.opacity(0.3))
                )
                if isMajor {
                    context.draw(
                        Text(Timecode.string(time).replacingOccurrences(of: ".0", with: ""))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: 1),
                        anchor: .topLeading
                    )
                }
                index += 1
            }
        }
    }
}
