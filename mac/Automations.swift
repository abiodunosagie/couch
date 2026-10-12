import AppKit
import Combine
import CoreAudio
import IOKit.pwr_mgt

/// Sleep timer, daily wake time and auto pause.
///
/// All of it runs inside Couch, so it only works while the Mac is awake. A pending sleep
/// timer keeps the Mac from idle sleeping until it fires; the wake time does not, since
/// holding the Mac awake all night would drain the battery.
@MainActor
final class Automations: ObservableObject {
    // MARK: settings (saved)

    @Published var wakeEnabled: Bool { didSet { save() } }
    /// Minutes after midnight.
    @Published var wakeMinute: Int { didSet { save() } }
    /// Favourite app (package) to open after waking, if any.
    @Published var wakeApp: String? { didSet { save() } }
    @Published var pauseOnLock: Bool { didSet { save() } }
    @Published var pauseOnCall: Bool { didSet { save() } }
    @Published var resumeAfterPause: Bool { didSet { save() } }

    // MARK: state

    @Published private(set) var sleepAt: Date?

    private let client: RemoteClient
    private let voice: VoiceInput
    private let favourites: Favourites
    private var sleepTask: Task<Void, Never>?
    private var sleepAssertion: IOPMAssertionID = 0
    private var clock: Timer?
    private var lastWakeDay: String?
    private var pausedFor: Set<String> = []
    private var lockObservers: [NSObjectProtocol] = []
    private var micListener: AudioObjectPropertyListenerBlock?
    private var micDevice = AudioObjectID(kAudioObjectUnknown)

    /// Time from pressing power to the TV taking an app link.
    private static let wakeSettleSeconds: UInt64 = 6

    init(client: RemoteClient, voice: VoiceInput, favourites: Favourites) {
        self.client = client
        self.voice = voice
        self.favourites = favourites
        let defaults = UserDefaults.standard
        wakeEnabled = defaults.bool(forKey: "wakeEnabled")
        wakeMinute = defaults.object(forKey: "wakeMinute") as? Int ?? 7 * 60
        wakeApp = defaults.string(forKey: "wakeApp")
        pauseOnLock = defaults.object(forKey: "pauseOnLock") as? Bool ?? true
        pauseOnCall = defaults.object(forKey: "pauseOnCall") as? Bool ?? true
        resumeAfterPause = defaults.bool(forKey: "resumeAfterPause")

        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWake() }
        }
        watchLock()
        watchMicrophone()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(wakeEnabled, forKey: "wakeEnabled")
        defaults.set(wakeMinute, forKey: "wakeMinute")
        defaults.set(wakeApp, forKey: "wakeApp")
        defaults.set(pauseOnLock, forKey: "pauseOnLock")
        defaults.set(pauseOnCall, forKey: "pauseOnCall")
        defaults.set(resumeAfterPause, forKey: "resumeAfterPause")
    }

    // MARK: sleep timer

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepAt = end
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Couch sleep timer turns the TV off" as CFString, &sleepAssertion)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.turnOff()
            self.cancelSleepTimer()
        }
        client.show("TV turns off in \(minutes) minutes.")
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: power helpers (POWER toggles, so look before pressing)

    func turnOn() {
        if client.state.isOn != true { client.press(.power) }
    }

    func turnOff() {
        if client.state.isOn != false { client.press(.power) }
    }

    // MARK: wake time

    private func checkWake() {
        guard wakeEnabled, client.state.isConnected else { return }
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        guard let hour = now.hour, let minute = now.minute, hour * 60 + minute == wakeMinute else { return }
        let day = "\(now.year ?? 0)-\(now.month ?? 0)-\(now.day ?? 0)"
        guard lastWakeDay != day else { return }
        lastWakeDay = day
        turnOn()
        if let package = wakeApp, let link = favourites.pinned.first(where: { $0.package == package })?.link {
            Task {
                try? await Task.sleep(nanoseconds: Self.wakeSettleSeconds * 1_000_000_000)
                self.client.open(link)
            }
        }
    }

    // MARK: auto pause

    private func pause(for reason: String) {
        guard client.state.isConnected, client.state.isOn == true, !pausedFor.contains(reason) else { return }
        if pausedFor.isEmpty { client.press(.pause) }
        pausedFor.insert(reason)
    }

    private func resume(after reason: String) {
        guard pausedFor.remove(reason) != nil, pausedFor.isEmpty, resumeAfterPause, client.state.isConnected else { return }
        client.press(.play)
    }

    private func watchLock() {
        let center = DistributedNotificationCenter.default()
        lockObservers = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.pauseOnLock == true { self?.pause(for: "lock") } }
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(after: "lock") }
            },
        ]
    }

    /// There is no public "a call started" event on the Mac. The honest signal is another app
    /// using the microphone, which FaceTime, WhatsApp, Zoom and Meet all do during a call.
    private func watchMicrophone() {
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultInput() }
        }
        followDefaultInput()
    }

    private func followDefaultInput() {
        var running = Self.runningAddress
        if let micListener, micDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(micDevice, &running, .main, micListener)
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        micDevice = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.micChanged() }
        }
        micListener = listener
        AudioObjectAddPropertyListenerBlock(device, &running, .main, listener)
    }

    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private func micChanged() {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.runningAddress
        guard AudioObjectGetPropertyData(micDevice, &address, 0, nil, &size, &running) == noErr else { return }
        // Couch's own voice search also uses the mic; that is not a call.
        if running != 0 && !voice.recording {
            if pauseOnCall { pause(for: "call") }
        } else if running == 0 {
            resume(after: "call")
        }
    }
}
