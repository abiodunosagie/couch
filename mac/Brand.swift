import AppKit
import SwiftUI

/// Couch brand colours and the pad symbol. Geometry and hex values match brand/generate.py, whose
/// docstring lists every copy (make-icon.swift, phone/style.css, BRAND.md).
enum Brand {
    private static let terracotta = rgb(0xA8432E)
    private static let coral = rgb(0xEE8E73)

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Accent for controls: Terracotta in light mode (6.0:1 with white text), Coral in dark mode
    /// (7.2:1 with Ink text). Replaces the system blue.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? coral : terracotta
    })

    /// Menu bar glyph: the pad (an opened ring with the OK button). The button is solid while the
    /// TV is on and connected, hollow otherwise. A template image, so macOS tints it for the bar.
    /// Standard menu bar icon box, in points.
    private static let menuBarSize: CGFloat = 18

    static func menuBarImage(live: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: menuBarSize, height: menuBarSize), flipped: true) { rect in
            let scale = rect.width / 256
            // Ring: the 256 design box arc from 40 to 320 degrees, radius 82, stroke 32 (y down).
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 128 * scale, y: 128 * scale), radius: 82 * scale,
                           startAngle: 40, endAngle: 320, clockwise: false)
            ring.lineWidth = 32 * scale
            ring.lineCapStyle = .round
            NSColor.black.set()
            ring.stroke()
            let dot = NSRect(x: (128 - 26) * scale, y: (128 - 26) * scale, width: 52 * scale, height: 52 * scale)
            if live {
                NSBezierPath(ovalIn: dot).fill()
            } else {
                // A ring of stroke 14 inset by half that, so it fills the same 52 circle as the solid button.
                let hollow = NSBezierPath(ovalIn: dot.insetBy(dx: 7 * scale, dy: 7 * scale))
                hollow.lineWidth = 14 * scale
                hollow.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Couch"
        return image
    }
}

/// A root view with the brand accent applied, for the windows and panels Couch hosts in AppKit.
struct Branded<Content: View>: View {
    let content: Content

    init(_ content: Content) { self.content = content }

    var body: some View { content.tint(Brand.accent) }
}
