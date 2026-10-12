import AppKit
import SwiftUI

/// Two finger swipes over the remote move around the TV, like the touch surface on some remotes.
@MainActor
final class TrackpadRouter {
    private let model: AppModel
    private var monitor: Any?
    private var pendingX: CGFloat = 0
    private var pendingY: CGFloat = 0

    /// Points of finger travel per step on the TV.
    private static let stepDistance: CGFloat = 26

    init(model: AppModel) {
        self.model = model
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let scroll = event
            let consumed = MainActor.assumeIsolated { self.handle(scroll) }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Trackpads and Magic Mice only; a wheel mouse scrolls as usual.
        guard event.hasPreciseScrollingDeltas, let window = event.window, overRemote(event, in: window) else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            pendingX = 0
            pendingY = 0
        }
        // Momentum after the fingers lift would overshoot; only real finger movement counts.
        guard event.momentumPhase.isEmpty else { return true }

        // With natural scrolling, deltas follow the fingers; otherwise they are reversed.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        pendingX += event.scrollingDeltaX * sign
        pendingY += event.scrollingDeltaY * sign
        while abs(pendingY) >= Self.stepDistance && abs(pendingY) >= abs(pendingX) {
            model.client.press(pendingY > 0 ? .down : .up)
            pendingY -= Self.stepDistance * (pendingY > 0 ? 1 : -1)
        }
        while abs(pendingX) >= Self.stepDistance && abs(pendingX) > abs(pendingY) {
            model.client.press(pendingX > 0 ? .right : .left)
            pendingX -= Self.stepDistance * (pendingX > 0 ? 1 : -1)
        }
        return true
    }

    private func overRemote(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let zone = model.remoteZones[window.windowNumber], let content = window.contentView else { return false }
        // SwiftUI global frames are measured from the top left of the window content.
        let point = event.locationInWindow
        return zone.contains(CGPoint(x: point.x, y: content.bounds.height - point.y))
    }
}

extension View {
    /// Report where the remote is drawn, so trackpad swipes over it can drive the TV.
    func trackpadZone(_ model: AppModel) -> some View {
        background(
            GeometryReader { geometry in
                ZoneReporter(model: model, frame: geometry.frame(in: .global))
            }
        )
    }
}

/// Finds its window and records the remote's frame for it.
private struct ZoneReporter: NSViewRepresentable {
    let model: AppModel
    let frame: CGRect

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let frame = self.frame
        DispatchQueue.main.async {
            guard let number = view.window?.windowNumber else { return }
            if model.remoteZones[number] != frame { model.remoteZones[number] = frame }
        }
    }
}
