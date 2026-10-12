// Draws the Couch app icon (a snow remote on a warm tile) into an .iconset folder.
// Usage: swift make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile, inset like system icons.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.93, green: 0.55, blue: 0.42, alpha: 1),
                        NSColor(red: 0.80, green: 0.35, blue: 0.27, alpha: 1)])!.draw(in: tilePath, angle: -90)

    // Remote body, tilted slightly.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: 512 * s, y: 512 * s)
    ctx.rotate(by: -0.18)
    let body = NSRect(x: -140 * s, y: -330 * s, width: 280 * s, height: 660 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 40 * s
    shadow.shadowOffset = NSSize(width: 0, height: -18 * s)
    shadow.set()
    NSColor(red: 0.97, green: 0.965, blue: 0.955, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 140 * s, yRadius: 140 * s).fill()
    NSShadow().set()

    let ring = NSColor(red: 0.78, green: 0.76, blue: 0.73, alpha: 1)
    ring.setStroke()
    let pad = NSBezierPath(ovalIn: NSRect(x: -112 * s, y: 70 * s, width: 224 * s, height: 224 * s))
    pad.lineWidth = 7 * s
    pad.stroke()
    let ok = NSBezierPath(ovalIn: NSRect(x: -44 * s, y: 138 * s, width: 88 * s, height: 88 * s))
    ok.lineWidth = 7 * s
    ok.stroke()

    // Two columns of round keys; the right top one is the black key.
    for (row, y) in [CGFloat(-30), -140].enumerated() {
        for (column, x) in [CGFloat(-62), 62].enumerated() {
            let key = NSBezierPath(ovalIn: NSRect(x: x * s - 40 * s, y: y * s - 40 * s, width: 80 * s, height: 80 * s))
            if row == 0 && column == 1 {
                NSColor(white: 0.1, alpha: 1).setFill()
                key.fill()
            } else {
                key.lineWidth = 6 * s
                key.stroke()
            }
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
