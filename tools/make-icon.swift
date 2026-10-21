// Draws the Couch app icon (the cream pad on a terracotta tile) into an .iconset folder.
// Matches brand/app-icon.svg: the 824 tile of the 1024 icon grid, the 256 pad scaled 2.5x.
// Usage: swift make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let terracotta = NSColor(srgbRed: 0xA8 / 255, green: 0x43 / 255, blue: 0x2E / 255, alpha: 1)
let cream = NSColor(srgbRed: 0xF6 / 255, green: 0xF1 / 255, blue: 0xE9 / 255, alpha: 1)

/// `fullBleed` fills the whole square, for the phone's Home Screen icon (iOS rounds the corners).
func draw(size: CGFloat, fullBleed: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile, inset like system icons (or the full square for the phone).
    terracotta.setFill()
    if fullBleed {
        NSRect(x: 0, y: 0, width: size, height: size).fill()
    } else {
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()
    }

    // The pad: a ring opened on the right (40 to 320 degrees), radius 82 and stroke 32 in the 256
    // design box, with the OK button (radius 26) in the middle. The box sits at 192 and scales 2.5x
    // (3x on the full-bleed square, which has no inset margin).
    let u = (fullBleed ? 3.0 : 2.5) * s
    let centre = NSPoint(x: 512 * s, y: 512 * s)
    cream.set()
    let ring = NSBezierPath()
    ring.appendArc(withCenter: centre, radius: 82 * u, startAngle: 40, endAngle: 320, clockwise: false)
    ring.lineWidth = 32 * u
    ring.lineCapStyle = .round
    ring.stroke()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 26 * u, y: centre.y - 26 * u, width: 52 * u, height: 52 * u)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
// Optional second argument: the phone page icon (512 px, full bleed), phone/icon.png.
if CommandLine.arguments.count > 2 {
    try draw(size: 512, fullBleed: true).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
