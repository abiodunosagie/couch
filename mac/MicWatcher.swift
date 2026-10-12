import CoreAudio
import Foundation

/// Tells whether another app is recording from a microphone, as a sign of a call.
///
/// There is no public "a call started" event on the Mac. FaceTime, WhatsApp, Zoom and Meet
/// all record from the microphone during a call, so that is the signal. It is read per app
/// (Core Audio process objects), so music playing through a headset does not count, and
/// Couch's own voice search is left out by process id. Nothing is recorded or stored.
///
/// macOS's own services (Siri and dictation listening in corespeechd, for one) switch the
/// microphone on for a moment during ordinary use, like copying text. Those never count, and the
/// microphone must stay busy for a few seconds before it counts as a call.
@MainActor
final class MicWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var inUseByOthers = false
    private var timer: Timer?
    private static let pollSeconds = 2.0
    /// Readings in a row that must agree before the state changes: 2 to 4 seconds.
    private static let confirmReadings = 2
    private var streak = 0
    /// Where macOS keeps its own background services; apps live elsewhere.
    nonisolated private static let systemServiceFolders = [
        "/System/Library/", "/Library/Apple/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/usr/lib/",
    ]
    /// Safari records a call in WebKit's own processes, which live in a system folder: those count.
    nonisolated private static let webKit = "/System/Library/Frameworks/WebKit.framework/"
    /// The macOS services that do the recording for FaceTime and for iPhone calls on the Mac: those are calls.
    nonisolated private static let callServices: Set<String> = ["avconferenced", "callservicesd"]

    func start() {
        let timer = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Common modes, so polling goes on while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        let busy = Self.otherAppRecording()
        guard busy != inUseByOthers else {
            streak = 0  // a reading that agrees with the current state starts the count again
            return
        }
        streak += 1
        guard streak >= Self.confirmReadings else { return }
        streak = 0
        inUseByOthers = busy
        onChange?(busy)
    }

    nonisolated private static func otherAppRecording() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return processObjects().contains { process in
            guard let pid: pid_t = property(process, kAudioProcessPropertyPID), pid != me else { return false }
            let running: UInt32? = property(process, kAudioProcessPropertyIsRunningInput)
            return (running ?? 0) != 0 && !isSystemService(pid)
        }
    }

    nonisolated private static func isSystemService(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // A process whose path cannot be read is left out: a missed blip beats a TV paused for nothing.
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        return isSystemServicePath(String(cString: buffer))
    }

    nonisolated static func isSystemServicePath(_ path: String) -> Bool {
        if callServices.contains((path as NSString).lastPathComponent) || path.hasPrefix(webKit) { return false }
        return systemServiceFolders.contains { path.hasPrefix($0) }
    }

    nonisolated private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    nonisolated private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.load(as: T.self)
    }
}
