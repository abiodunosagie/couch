import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The remote that drops down from the menu bar.
///
/// A plain NSPopover anchors to the status item. On a MacBook with a notch, a full
/// menu bar hides that item behind the notch and the popover opens off screen. This
/// panel always lands fully on screen: under the icon when the icon is visible,
/// otherwise at the top right corner.
@MainActor
final class MenuPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: AppModel
    private let host: NSHostingView<MenuPanelView>
    private var lastClosed = Date.distantPast
    private var contentWatch: AnyCancellable?

    /// Room taken by the header, toast and padding around the remote, in points.
    private static let chromeHeight: CGFloat = 150
    /// Extra room the typing panel takes while typing mode is on.
    private static let typingHeight: CGFloat = 170
    private static let maxScale: CGFloat = 0.8
    private static let minScale: CGFloat = 0.5
    private static let gap: CGFloat = 6
    /// A click on the menu bar icon closes the panel (focus loss) and then toggles it;
    /// a toggle this soon after a close is that same click.
    private static let reopenGuard: TimeInterval = 0.3

    init(model: AppModel, openWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        host = NSHostingView(rootView: MenuPanelView(model: model, openWindow: openWindow, quit: quit))
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.delegate = self
        // The type field, toast and pairing form change the height; keep the panel fitted and on screen.
        contentWatch = model.objectWillChange.merge(with: model.client.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refit() } }
    }

    var window: NSWindow { panel }
    var isShown: Bool { panel.isVisible }

    func toggle(below button: NSStatusBarButton?) {
        // Clicking the menu bar icon first takes key focus from the panel, which closes it.
        // Without this check that same click would reopen it straight away.
        if isShown || Date().timeIntervalSince(lastClosed) < Self.reopenGuard {
            close()
        } else {
            show(below: button)
        }
    }

    func show(below button: NSStatusBarButton?) {
        let anchor = Self.visibleAnchor(of: button)
        guard let screen = anchor?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame

        centerX = anchor?.frame.midX ?? area.maxX
        self.screen = screen
        place()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI applies the new scale on its next pass; fit again once it has.
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private var centerX: CGFloat = 0
    private weak var screen: NSScreen?

    private func refit() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    /// Size the panel to its content and pin its top under the menu bar, inside the screen.
    private func place() {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return }
        // Shrink the remote while the typing panel is open so everything still fits.
        let chrome = Self.chromeHeight + (model.typing ? Self.typingHeight : 0)
        let fit = (area.height - chrome - Self.gap * 2) / RemoteView.size.height
        let scale = max(Self.minScale, min(Self.maxScale, fit))
        if abs(scale - model.panelScale) > 0.001 { model.panelScale = scale }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        var x = centerX - size.width / 2
        x = min(max(x, area.minX + Self.gap), area.maxX - size.width - Self.gap)
        let height = min(size.height, area.height - Self.gap * 2)
        let frame = NSRect(x: x, y: area.maxY - height - Self.gap, width: size.width, height: height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    func close() {
        guard panel.isVisible else { return }
        Repeater.stopAll()
        panel.orderOut(nil)
        model.typing = false
        lastClosed = Date()
    }

    /// Close like a menu when the user clicks elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// The status item's frame on screen, or nil when macOS has hidden it (notch overflow).
    private static func visibleAnchor(of button: NSStatusBarButton?) -> (frame: NSRect, screen: NSScreen)? {
        guard let button, let window = button.window, window.isVisible, let screen = window.screen else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.visibleFrame.insetBy(dx: -1, dy: -40).contains(NSPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return (frame, screen)
    }
}

/// Borderless panels refuse key status by default; the remote needs it for arrow keys and typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
