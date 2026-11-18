import AVFoundation
import BasitCutCore

// Lossless conversions between the AVFoundation-free model types and their
// CoreMedia / CoreGraphics counterparts.

extension RationalTime {
    public init(_ time: CMTime) {
        precondition(time.isNumeric, "CMTime must be numeric")
        self.init(value: time.value, timescale: time.timescale)
    }

    public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

extension TimeRange {
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

extension Size {
    public init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

extension Transform2D {
    public init(_ t: CGAffineTransform) { self.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }
    public var cgAffineTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension FourCharCode {
    /// `'avc1'` etc. as a string.
    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
