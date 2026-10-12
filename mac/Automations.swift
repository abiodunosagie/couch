import AppKit
import Combine
import IOKit.pwr_mgt

/// Sleep timer, daily wake time and auto pause.
///
/// All of it runs inside Couch, so it only works while the Mac is awake. A pending sleep
/// timer keeps the Mac from idle sleeping until it fires; the wake time does not, since
/// holding the Mac awake all night would drain the battery.
@MainActor
final class Automations: ObservableObject {
    private enum Key {
        static let wakeEnabled = "wakeEnabled"
        static let wakeMinute = "wakeMinute"
        static let wakeApp = "wakeApp"
        static let pauseOnLock = "pauseOnLock"
        static let pauseOnCall = "pauseOnCall"
        static let resumeAfterPause = "resumeAfterPause"
    }

    private enum PauseReason { case lock, call }

    // MARK: settings (saved)

    @Published var wakeEnabled: Bool { didSet { UserDefaults.standard.set(wakeEnabled, forKey: Key.wakeEnabled) } }
    /// Minutes after midnight.
    @Published var wakeMinute: Int { didSet { UserDefaults.standard.set(wakeMinute, forKey: Key.wakeMinute) } }
    /// Favourite app (package) to open after waking, if any.
    @Published var wakeApp: String? { didSet { UserDefaults.standard.set(wakeApp, forKey: Key.wakeApp) } }
    @Published var pauseOnLock: Bool { didSet { UserDefaults.standard.set(pauseOnLock, forKey: Key.pauseOnLock) } }
    @Published var pauseOnCall: Bool { didSet { UserDefaults.standard.set(pauseOnCall, forKey: Key.pauseOnCall) } }
    @Published var resumeAfterPause: Bool { didSet { UserDefaults.standard.set(resumeAfterPause, forKey: Key.resumeAfterPause) } }

    // MARK: state

    @Published private(set) var sleepAt: Date?

    private let client: RemoteClient
    private let favourites: Favourites
    private let mic = MicWatcher()
    private var sleepAssertion: IOPMAssertionID = 0
    private var clock: Timer?
    private var lastWakeDay: String?
    private var pausedFor: Set<PauseReason> = []
    private var lockObservers: [NSObjectProtocol] = []

    private static let defaultWakeMinute = 7 * 60
    private static let clockSeconds = 10.0
    /// A wake time missed while the TV link was down still runs if it comes back this soon.
    private static let wakeCatchUpMinutes = 10
    /// A sleep timer that comes due while the TV link is down keeps trying this long.
    private static let sleepRetrySeconds: TimeInterval = 15 * 60
    /// How long a power press takes to show up in the TV's reported state.
    static let powerSettleSeconds = 8.0

    init(client: RemoteClient, favourites: Favourites) {
        self.client = client
        self.favourites = favourites
        let defaults = UserDefaults.standard
        wakeEnabled = defaults.bool(forKey: Key.wakeEnabled)
        wakeMinute = defaults.object(forKey: Key.wakeMinute) as? Int ?? Self.defaultWakeMinute
        wakeApp = defaults.string(forKey: Key.wakeApp)
        pauseOnLock = defaults.object(forKey: Key.pauseOnLock) as? Bool ?? true
        pauseOnCall = defaults.object(forKey: Key.pauseOnCall) as? Bool ?? true
        resumeAfterPause = defaults.bool(forKey: Key.resumeAfterPause)

        clock = Timer.scheduledTimer(withTimeInterval: Self.clockSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSleep()
                self?.checkWake()
            }
        }
        watchLock()
        mic.onChange = { [weak self] busy in
            guard let self else { return }
            if busy {
                if self.pauseOnCall { self.pause(for: .call) }
            } else {
                self.resume(after: .call)
            }
        }
        mic.start()
    }

    // MARK: power (POWER toggles, so press only when the state is known)

    /// Turn the TV on. Returns false when Couch cannot tell whether it is on.
    @discardableResult
    func turnOn() -> Bool {
        switch client.state.isOn {
        case true: return true
        case false: client.press(.power); return true
        case nil:
            client.show("Couch cannot tell if the TV is on, so it left the power alone.")
            return false
        }
    }

    @discardableResult
    func turnOff() -> Bool {
        switch client.state.isOn {
        case false: return true
        case true: client.press(.power); return true
        case nil:
            client.show("Couch cannot tell if the TV is on, so it left the power alone.")
            return false
        }
    }

    /// Wait until the TV reports the wanted power state, up to `powerSettleSeconds`.
    func waitForPower(on: Bool) async {
        let deadline = Date().addingTimeInterval(Self.powerSettleSeconds)
        while Date() < deadline, client.state.isOn != on {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: sleep timer

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Couch sleep timer turns the TV off" as CFString, &sleepAssertion)
        client.show("TV turns off in \(minutes) minutes.")
    }

    func cancelSleepTimer() {
        sleepAt = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    /// Runs on the clock rather than a sleeping task, so it stays right across Mac sleep.
    private func checkSleep() {
        guard let due = sleepAt, Date() >= due else { return }
        if Date().timeIntervalSince(due) > Self.sleepRetrySeconds {
            cancelSleepTimer()  // the TV never came back; give up rather than switch it off hours later
            return
        }
        // Not connected or state unknown: keep the timer and try again on the next tick.
        guard client.state.isConnected, client.state.isOn != nil else { return }
        turnOff()
        cancelSleepTimer()
    }

    // MARK: wake time

    private func checkWake() {
        guard wakeEnabled else { return }
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        guard let hour = now.hour, let minute = now.minute else { return }
        let late = hour * 60 + minute - wakeMinute
        guard late >= 0, late <= Self.wakeCatchUpMinutes else { return }
        let day = "\(now.year ?? 0)-\(now.month ?? 0)-\(now.day ?? 0)"
        guard lastWakeDay != day, client.state.isConnected, client.state.isOn != nil else { return }
        lastWakeDay = day
        guard turnOn(), let link = favourites.link(for: wakeApp) else { return }
        Task {
            await waitForPower(on: true)
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // the home screen loads before it takes links
            client.open(link)
        }
    }

    // MARK: auto pause

    private func pause(for reason: PauseReason) {
        guard client.state.isConnected, client.state.isOn == true, !pausedFor.contains(reason) else { return }
        if pausedFor.isEmpty { client.press(.pause) }
        pausedFor.insert(reason)
    }

    private func resume(after reason: PauseReason) {
        guard pausedFor.remove(reason) != nil, pausedFor.isEmpty, resumeAfterPause,
              client.state.isConnected, client.state.isOn == true else { return }
        client.press(.play)
    }

    private func watchLock() {
        let center = DistributedNotificationCenter.default()
        lockObservers = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.pauseOnLock == true { self?.pause(for: .lock) } }
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(after: .lock) }
            },
        ]
    }
}
