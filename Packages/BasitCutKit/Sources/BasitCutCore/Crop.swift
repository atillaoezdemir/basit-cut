import Foundation

/// Crop geometry. Rects are normalized (0…1, origin top left) in the upright
/// frame of the project's first clip, the "canvas". Fixed-ratio modes keep
/// their ratio in pixels, whatever the canvas shape.
extension CropSetting.Mode {
    /// Width / height in pixels, or nil for original and free.
    public var aspectRatio: Double? {
        switch self {
        case .original, .free: nil
        case .ratio16x9: 16.0 / 9
        case .ratio9x16: 9.0 / 16
        case .ratio1x1: 1
        }
    }

    public var title: String {
        switch self {
        case .original: "Original"
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        case .ratio1x1: "1:1"
        case .free: "Free"
        }
    }
}

extension NormalizedRect {
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum CropGeometry {
    /// Smallest crop side, as a fraction of the canvas side.
    public static let minimumSide = 0.1

    public enum Corner: Sendable, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    /// The crop setting for `mode` on `canvas`: fixed ratios get the largest
    /// centered rect, free keeps `current` (or the whole frame).
    public static func setting(for mode: CropSetting.Mode, canvas: Size, current: NormalizedRect = .full) -> CropSetting {
        switch mode {
        case .original: .original
        case .free: CropSetting(mode: .free, rect: clamped(current, mode: .free, canvas: canvas))
        default: CropSetting(mode: mode, rect: clamped(.full, mode: mode, canvas: canvas))
        }
    }

    /// `rect` made valid for `mode` on `canvas`: inside the frame, at least the
    /// minimum size, and with the mode's ratio (kept around the rect's centre,
    /// as large as its height allows).
    public static func clamped(_ rect: NormalizedRect, mode: CropSetting.Mode, canvas: Size) -> NormalizedRect {
        guard mode != .original else { return .full }
        var width = min(max(rect.width, minimumSide), 1)
        var height = min(max(rect.height, minimumSide), 1)
        if let ratio = mode.aspectRatio {
            // Normalized width for a normalized height, keeping the pixel ratio.
            let factor = ratio * canvas.height / canvas.width
            width = height * factor
            if width > 1 { width = 1; height = width / factor }
            if height > 1 { height = 1; width = factor }
        }
        let x = min(max(rect.midX - width / 2, 0), 1 - width)
        let y = min(max(rect.midY - height / 2, 0), 1 - height)
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    /// Moves `rect` by a normalized offset, staying inside the frame.
    public static func moved(_ rect: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        NormalizedRect(
            x: min(max(rect.x + dx, 0), 1 - rect.width),
            y: min(max(rect.y + dy, 0), 1 - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    /// Drags `corner` of `rect` to `point` (normalized); the opposite corner stays.
    public static func resized(
        _ rect: NormalizedRect,
        corner: Corner,
        to point: (x: Double, y: Double),
        mode: CropSetting.Mode,
        canvas: Size
    ) -> NormalizedRect {
        let leading = corner == .topLeading || corner == .bottomLeading
        let top = corner == .topLeading || corner == .topTrailing
        let anchorX = leading ? rect.maxX : rect.x
        let anchorY = top ? rect.maxY : rect.y
        // Room between the anchor and the frame edge in the drag direction.
        let roomX = leading ? anchorX : 1 - anchorX
        let roomY = top ? anchorY : 1 - anchorY
        var width = leading ? anchorX - point.x : point.x - anchorX
        var height = top ? anchorY - point.y : point.y - anchorY

        if let ratio = mode.aspectRatio {
            let factor = ratio * canvas.height / canvas.width   // normalized width per height
            width = max(width, height * factor)
            width = min(width, roomX, roomY * factor)
            width = max(width, minimumSide, minimumSide * factor)
            height = width / factor
        } else {
            width = min(max(width, minimumSide), roomX)
            height = min(max(height, minimumSide), roomY)
        }
        return NormalizedRect(
            x: leading ? anchorX - width : anchorX,
            y: top ? anchorY - height : anchorY,
            width: width,
            height: height
        )
    }
}

/// A crop in pixels of the canvas.
public struct PixelRect: Hashable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public var size: Size { Size(width: width, height: height) }
}

extension Project {
    /// The upright frame size of the first clip; crop rects refer to it.
    public var canvasSize: Size? {
        referenceSource?.orientedSize
    }

    /// The cropped area in canvas pixels, with an even width and height
    /// (encoders need that). Without a crop, the whole canvas.
    public var cropRect: PixelRect? {
        guard let canvas = canvasSize else { return nil }
        let rect = CropGeometry.clamped(crop.rect, mode: crop.mode, canvas: canvas)
        let width = min(ExportPlan.even(rect.width * canvas.width), ExportPlan.even(canvas.width))
        let height = min(ExportPlan.even(rect.height * canvas.height), ExportPlan.even(canvas.height))
        return PixelRect(
            x: min(max(0, (rect.x * canvas.width).rounded()), max(0, canvas.width - width)),
            y: min(max(0, (rect.y * canvas.height).rounded()), max(0, canvas.height - height)),
            width: width,
            height: height
        )
    }
}
