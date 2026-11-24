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

/// A closed shape with each corner rounded by its radius.
func polygon(_ points: [(CGPoint, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let last = points[points.count - 1].0, first = points[0].0
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for (i, (point, radius)) in points.enumerated() {
        path.addArc(tangent1End: point, tangent2End: points[(i + 1) % points.count].0, radius: radius)
    }
    path.closeSubpath()
    return path
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A timeline on a light tile: two clips with the playhead at the cut
/// (1024 pt grid, macOS margins). The clip colors are also the app's
/// (`ClipView`). At 16 and 32 pixels the playhead is drawn heavier, so it
/// doesn't blur away.
func draw(_ c: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    func fill(_ path: CGPath, _ g: CGGradient) {
        let box = path.boundingBox
        c.saveGState()
        c.addPath(path); c.clip()
        c.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
        c.restoreGState()
    }
    let tile = rect(100, 100, 824, 824, radius: 186)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale, color: color(0x000000, 0.35))
    c.addPath(tile); c.setFillColor(color(0xE6EAF2)); c.fillPath()
    c.restoreGState()
    fill(tile, gradient(0xFFFFFF, 0xE6EAF2))

    let isSmall = pixels <= 32
    let gap: CGFloat = isSmall ? 62 : 32     // centre to clip edge
    let line: CGFloat = isSmall ? 64 : 36    // playhead thickness
    c.saveGState()
    c.addPath(tile); c.clip()
    fill(rect(40, 352, 512 - gap - 40, 300, radius: 56), gradient(0x4C8DFF, 0x2463EB))
    fill(rect(512 + gap, 352, 1004 - 512 - gap, 300, radius: 56), gradient(0xFFC24B, 0xFF9A1F))
    c.restoreGState()

    let w: CGFloat = isSmall ? 124 : 88      // half the width of the head
    fill(rect(512 - line / 2, 232, line, 470, radius: line / 2), gradient(0x1B2030, 0x1B2030))
    fill(polygon([(CGPoint(x: 512 - w, y: 800), 34), (CGPoint(x: 512 + w, y: 800), 34), (CGPoint(x: 512 + w, y: 716), 34),
                  (CGPoint(x: 512, y: 628), 30), (CGPoint(x: 512 - w, y: 716), 34)]), gradient(0x2B3348, 0x1B2030))
}

func png(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(c, pixels: pixels)
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
