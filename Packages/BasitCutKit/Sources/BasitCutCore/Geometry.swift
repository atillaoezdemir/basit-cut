import Foundation

/// A size in pixels, independent of CoreGraphics.
public struct Size: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isPortrait: Bool { height > width }
}

/// A 2D affine transform (same layout as `CGAffineTransform`), used to store a
/// source track's `preferredTransform` (e.g. the rotation of phone videos).
public struct Transform2D: Hashable, Codable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }

    public static let identity = Transform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// The size of a `size`-sized frame after applying this transform.
    public func applied(to size: Size) -> Size {
        Size(
            width: abs(a * size.width + c * size.height),
            height: abs(b * size.width + d * size.height)
        )
    }

    /// Whether two transforms produce the same orientation (ignoring translation).
    public func hasSameOrientation(as other: Transform2D) -> Bool {
        a == other.a && b == other.b && c == other.c && d == other.d
    }
}

/// A rectangle in normalized coordinates (0…1) of the oriented source frame.
public struct NormalizedRect: Hashable, Codable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}
