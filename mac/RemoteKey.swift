import AppKit

/// Remote buttons. Raw values are Android key names and must stay in step with
/// ALLOWED_KEYS in server.py, which refuses anything else.
enum RemoteKey: String {
    case up = "DPAD_UP"
    case down = "DPAD_DOWN"
    case left = "DPAD_LEFT"
    case right = "DPAD_RIGHT"
    case select = "DPAD_CENTER"
    case back = "BACK"
    case home = "HOME"
    case power = "POWER"
    case input = "TV_INPUT"
    case volumeUp = "VOLUME_UP"
    case volumeDown = "VOLUME_DOWN"
    case mute = "VOLUME_MUTE"
    case playPause = "MEDIA_PLAY_PAUSE"

    /// Keys that repeat while held, like on the physical remote; the rest fire once per press.
    var repeats: Bool {
        switch self {
        case .up, .down, .left, .right, .volumeUp, .volumeDown: true
        default: false
        }
    }

    /// The Mac keyboard shortcut for a key press, if there is one.
    init?(event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .select  // Return, keypad Enter
        case 51: self = .back  // Delete
        case 49: self = .playPause  // Space
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": self = .home
            case "p": self = .power
            case "m": self = .mute
            case "+", "=": self = .volumeUp
            case "-": self = .volumeDown
            default: return nil
            }
        }
    }
}

/// Esc: Back in the window, close in the menu bar panel.
let escapeKeyCode: UInt16 = 53
