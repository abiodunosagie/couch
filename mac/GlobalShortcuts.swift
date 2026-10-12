import AppKit
import Carbon.HIToolbox

/// System wide shortcuts that work while another app is in front.
/// Uses the Carbon hot key API, which needs no Accessibility permission.
@MainActor
final class GlobalShortcuts {
    struct Shortcut {
        let keyCode: Int
        let modifiers: Int  // Carbon modifier flags: cmdKey, optionKey, controlKey, shiftKey
        let label: String  // as shown in the Couch window
        let action: () -> Void
    }

    private var shortcuts: [UInt32: Shortcut] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// Shortcuts another app already owns, for the Couch window to mention.
    private(set) var unavailable: [String] = []

    private static let signature = OSType(0x4355_4348)  // "CUCH"

    init(_ list: [Shortcut]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.shortcuts[number]?.action() } }
            return noErr
        }, 1, &spec, context, &handler)

        for (index, shortcut) in list.enumerated() {
            let number = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: number),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                shortcuts[number] = shortcut
            } else {
                unavailable.append(shortcut.label)
                NSLog("Couch: \(shortcut.label) is taken by another app (\(status))")
            }
        }
    }

    // The app keeps one instance for its whole life; the system drops hot keys at exit.
}
