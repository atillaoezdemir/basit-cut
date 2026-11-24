// Draws the app icon and writes every size of the asset catalog.
// Run from the repository root: swift Tools/MakeIcon.swift
import AppKit

let folder = "BasitCut/Resources/Assets.xcassets/AppIcon.appiconset"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
}

/// A clip with rounded outer corners and a slanted cut edge.
func clip(_ points: [(CGPoint, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let last = points[points.count - 1].0, first = points[0].0
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for (i, (point, radius)) in points.enumerated() {
        path.addArc(tangent1End: point, tangent2End: points[(i + 1) % points.count].0, radius: radius)
    }
    path.closeSubpath()
    return path
}

/// One film clip cut in two, on a dark tile (1024 pt grid, macOS margins).
func draw(_ c: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.35))
    c.addPath(tile); c.setFillColor(color(0x1B1E27)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(tile); c.clip()
    c.drawLinearGradient(gradient(0x343A4A, 0x14161D), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    func fill(_ path: CGPath, _ g: CGGradient) {
        c.saveGState()
        c.addPath(path); c.clip()
        c.drawLinearGradient(g, start: CGPoint(x: 512, y: 690), end: CGPoint(x: 512, y: 334), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    let low: CGFloat = 342, high: CGFloat = 682
    fill(clip([(CGPoint(x: 196, y: low), 54), (CGPoint(x: 432, y: low), 18),
               (CGPoint(x: 532, y: high), 18), (CGPoint(x: 196, y: high), 54)]), gradient(0xFFB545, 0xF5821F))
    fill(clip([(CGPoint(x: 492, y: low), 18), (CGPoint(x: 828, y: low), 54),
               (CGPoint(x: 828, y: high), 54), (CGPoint(x: 592, y: high), 18)]), gradient(0xFFFFFF, 0xD9DEE8))
}

func png(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(c)
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)@\(scale)x.png"
        try png(size * scale).write(to: URL(filePath: "\(folder)/\(name)"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(filePath: "\(folder)/Contents.json"))
