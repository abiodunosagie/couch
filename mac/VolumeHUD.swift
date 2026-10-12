import AppKit
import SwiftUI

/// A brief on screen sign when the TV volume changes from a global shortcut, like the
/// Mac's own volume pop-up. The TV leaves volume to the TV set (over HDMI), so it never
/// reports a level; the sign shows the direction, not a bar.
@MainActor
final class VolumeHUD {
    enum Change { case up, down, mute }

    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var hide: DispatchWorkItem?

    static let size = NSSize(width: 168, height: 150)
    private static let visibleSeconds = 1.1
    private static let fadeSeconds = 0.25
    private static let bottomMargin: CGFloat = 140

    init() {
        host = NSHostingView(rootView: HUDView(change: .up, tv: nil))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
    }

    func show(_ change: Change, tv: String?) {
        host.rootView = HUDView(change: change, tv: tv)
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + Self.bottomMargin))
        }
        hide?.cancel()
        // Replace any fade still running, so a quick second press keeps the sign up.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = work
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeSeconds
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    // Only hide if no newer press came in during the fade.
                    if self.hide === current { self.panel.orderOut(nil) }
                }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }
}

private struct HUDView: View {
    let change: VolumeHUD.Change
    let tv: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text(tv ?? "TV").font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .frame(width: VolumeHUD.size.width, height: VolumeHUD.size.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var symbol: String {
        switch change {
        case .up: "speaker.plus.fill"
        case .down: "speaker.minus.fill"
        case .mute: "speaker.slash.fill"
        }
    }
}
