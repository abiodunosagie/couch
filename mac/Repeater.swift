import Combine
import Foundation

/// Repeats an action while a control is held, like a physical remote.
///
/// Every repeater also stops when `Repeater.stopAll()` is posted, which the app does
/// whenever a window or the menu bar panel loses focus. A gesture whose end never
/// arrives (window hidden mid-press) therefore cannot keep firing.
@MainActor
final class Repeater: ObservableObject {
    static let firstRepeatDelay: UInt64 = 450_000_000
    static let repeatInterval: UInt64 = 140_000_000
    private static let stopNotification = Notification.Name("CouchStopRepeats")

    /// True while repeating; views use it to drop their pressed look when stopped from outside.
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var stopObserver: AnyCancellable?

    init() {
        stopObserver = NotificationCenter.default.publisher(for: Self.stopNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    static func stopAll() {
        NotificationCenter.default.post(name: stopNotification, object: nil)
    }

    func start(_ action: @escaping () -> Void) {
        stop()
        action()
        running = true
        task = Task {
            try? await Task.sleep(nanoseconds: Self.firstRepeatDelay)
            while !Task.isCancelled {
                action()
                try? await Task.sleep(nanoseconds: Self.repeatInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }
}
