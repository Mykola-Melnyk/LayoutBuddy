// Regenerates the macOS app icon set (a white SF Symbol "infinity" on a
// blue→indigo squircle) into AppIcon.appiconset.
//
// Usage:
//   swift Tools/generate-app-icon.swift LayoutBuddy/Assets.xcassets/AppIcon.appiconset
//
// Re-run after tweaking the colors/glyph below; Contents.json already
// references the generated filenames.
import AppKit

let outDir = CommandLine.arguments[1]

// (filename, pixel size) for the macOS app icon set.
let targets: [(String, Int)] = [
    ("icon_16.png", 16), ("icon_16@2x.png", 32),
    ("icon_32.png", 32), ("icon_32@2x.png", 64),
    ("icon_128.png", 128), ("icon_128@2x.png", 256),
    ("icon_256.png", 256), ("icon_256@2x.png", 512),
    ("icon_512.png", 512), ("icon_512@2x.png", 1024),
]

// Pre-render a white-tinted infinity glyph at a generous point size; it is
// scaled per icon, so one master is enough.
func whiteInfinity() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 512, weight: .bold)
    let base = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let out = NSImage(size: base.size)
    out.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}
let glyph = whiteInfinity()

func render(_ px: Int) -> Data {
    let dim = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: dim, height: dim)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: dim, height: dim))

    // macOS squircle body: ~80.5% of the canvas, centered.
    let inset = dim * 0.0977
    let body = CGRect(x: inset, y: inset, width: dim - 2 * inset, height: dim - 2 * inset)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.29, green: 0.47, blue: 0.99, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.45, green: 0.29, blue: 0.93, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // White infinity, ~54% of canvas width, centered.
    let boxMax = dim * 0.56
    let s = min(boxMax / glyph.size.width, boxMax / glyph.size.height)
    let w = glyph.size.width * s, h = glyph.size.height * s
    glyph.draw(in: NSRect(x: (dim - w) / 2, y: (dim - h) / 2, width: w, height: h),
               from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var cache: [Int: Data] = [:]
for (name, px) in targets {
    let data = cache[px] ?? render(px)
    cache[px] = data
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
print("wrote \(targets.count) icons to \(outDir)")
