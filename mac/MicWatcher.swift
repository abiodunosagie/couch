import CoreAudio
import Foundation

/// Tells whether another app is recording from a microphone, as a sign of a call.
///
/// There is no public "a call started" event on the Mac. FaceTime, WhatsApp, Zoom and Meet
/// all record from the microphone during a call, so that is the signal. It is read per app
/// (Core Audio process objects), so music playing through a headset does not count, and
/// Couch's own voice search is left out by process id. Nothing is recorded or stored.
@MainActor
final class MicWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var inUseByOthers = false
    private var timer: Timer?
    private static let pollSeconds = 2.0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    private func check() {
        let busy = Self.otherProcessRecording()
        guard busy != inUseByOthers else { return }
        inUseByOthers = busy
        onChange?(busy)
    }

    nonisolated private static func otherProcessRecording() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return processObjects().contains { process in
            guard let pid: pid_t = property(process, kAudioProcessPropertyPID), pid != me else { return false }
            let running: UInt32? = property(process, kAudioProcessPropertyIsRunningInput)
            return (running ?? 0) != 0
        }
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
