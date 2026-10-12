import AppKit
import Carbon.HIToolbox

/// Turns Mac key presses in Couch's windows into remote buttons, or, in typing mode,
/// into edits of the TV text box.
@MainActor
final class KeyRouter {
    private let model: AppModel
    /// The Couch window and the menu bar panel; keys elsewhere are left alone.
    private let isRemoteWindow: (NSWindow) -> Bool
    private let isPanel: (NSWindow) -> Bool
    private let closePanel: () -> Void
    private var monitor: Any?
    /// Pending dead key (Option E, Option U...) waiting for the letter it accents.
    private var deadKeyState: UInt32 = 0

    /// First code point of AppKit's function key range (arrows, F keys); never text.
    private static let functionKeyRangeStart: UInt32 = 0xF700

    init(model: AppModel, isRemoteWindow: @escaping (NSWindow) -> Bool,
         isPanel: @escaping (NSWindow) -> Bool, closePanel: @escaping () -> Void) {
        self.model = model
        self.isRemoteWindow = isRemoteWindow
        self.isPanel = isPanel
        self.closePanel = closePanel
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // AppKit calls local monitors on the main thread.
            nonisolated(unsafe) let pressed = event
            let consumed = MainActor.assumeIsolated { self.handle(pressed) }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let keyWindow = event.window, isRemoteWindow(keyWindow) else { return false }
        // Typing into a real text field (the pairing code; its field editor is an NSTextView) is left to AppKit.
        if keyWindow.firstResponder is NSTextView { return false }
        if model.typing { return handleTyping(event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            model.searching = true
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            model.sendClipboardLink()
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }

        if event.keyCode == UInt16(kVK_Escape) {
            // Esc closes the menu bar remote like any menu; in the window it is Back.
            if isPanel(keyWindow) { closePanel() } else { model.client.press(.back) }
            return true
        }
        if event.charactersIgnoringModifiers == "/" {
            model.typing = true
            return true
        }
        guard let key = RemoteKey(event: event) else { return false }
        if !event.isARepeat || key.repeats { model.client.press(key) }
        return true
    }

    /// Typing mode: keys edit the TV text box. Esc leaves, Command V pastes, other shortcuts work as usual.
    private func handleTyping(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers == .command {
            guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }  // Command W, Q...
            model.paste()
            return true
        }
        // Option stays allowed for accents and symbols; Control combinations are left to AppKit.
        if !modifiers.isEmpty && modifiers != .option { return false }

        switch Int(event.keyCode) {
        case kVK_Escape: model.typing = false
        case kVK_Delete: model.client.edit(.deleteBackward)
        case kVK_ForwardDelete: model.client.edit(.deleteForward)
        case kVK_Return, kVK_ANSI_KeypadEnter: model.client.edit(.enter)
        case kVK_LeftArrow: model.client.edit(.left)
        case kVK_RightArrow: model.client.edit(.right)
        case kVK_UpArrow: model.client.edit(.up)  // Up and Down move between fields on the TV
        case kVK_DownArrow: model.client.edit(.down)
        case kVK_Home: model.client.edit(.lineStart)
        case kVK_End: model.client.edit(.lineEnd)
        default:
            guard let text = typedText(for: event) else { return true }  // a dead key: wait for its letter
            guard !text.isEmpty, text.unicodeScalars.allSatisfy(Self.isTypeable) else { return false }
            model.client.insert(text)
        }
        return true
    }

    /// The text a key produces, composing dead key accents (Option E then E gives é).
    /// Returns nil while a dead key waits for the next letter.
    private func typedText(for event: NSEvent) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return event.characters ?? ""
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let modifierState = UInt32((event.modifierFlags.rawValue >> 8) & 0xFF)  // Carbon modifier bits
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyLayout in
            UCKeyTranslate(keyLayout, event.keyCode, UInt16(kUCKeyActionDown), modifierState,
                           UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr else { return event.characters ?? "" }
        if length == 0 && deadKeyState != 0 { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && scalar.value < functionKeyRangeStart
    }
}
