import Foundation

/// Connection status as reported by the helper (TVSession.status in server.py).
enum LinkStatus: String, Decodable {
    case searching, offline, unpaired, pairing, connected, reconnecting
    case unknown

    init(from decoder: Decoder) throws {
        self = LinkStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// The text box focused on the TV, if any, and what it currently says.
struct TVTextField: Decodable, Equatable {
    var active: Bool
    var value: String
}

/// Keys that edit the TV text box. Raw values must match EDIT_KEYS in text_input.py.
enum EditKey: String {
    case deleteBackward = "DEL"
    case deleteForward = "FORWARD_DEL"
    case enter = "ENTER"
    case left = "DPAD_LEFT"
    case right = "DPAD_RIGHT"
    case up = "DPAD_UP"
    case down = "DPAD_DOWN"
    case lineStart = "MOVE_HOME"
    case lineEnd = "MOVE_END"
}

/// What the helper reports about the TV.
struct TVState: Decodable, Equatable {
    var status: LinkStatus = .searching
    var notice: String = ""
    var noticeId: Int = 0
    var tv: String?
    var isOn: Bool?
    var app: String?
    var field: TVTextField?

    enum CodingKeys: String, CodingKey {
        case status, notice, tv, app, field
        case noticeId = "notice_id"
        case isOn = "is_on"
    }

    var isConnected: Bool { status == .connected }
    var needsPairing: Bool { status == .unpaired || status == .pairing }
}

private struct Envelope: Decodable {
    let type: String
    let message: String?
    /// For errors: the request type that failed.
    let `for`: String?
}

private struct PackageMessage: Decodable {
    let package: String
}

private struct VoiceMessage: Decodable {
    let listening: Bool
}

/// The TV's app manager (Android debugging) as the helper reports it.
enum AppsLink: String, Decodable {
    case unknown, off, waiting, ready, denied, pairing
    case noAdb = "no_adb"
    case needsPairing = "needs_pairing"

    /// A state this app does not know yet reads as unknown, so the message is not dropped.
    init(from decoder: Decoder) throws {
        self = AppsLink(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

private struct AppsMessage: Decodable {
    let status: AppsLink
    let message: String?
    let installed: [String]?
}

/// Phone remote settings from the helper. The URL carries the pairing token: Mac app only.
struct PhoneInfo: Decodable, Equatable {
    var enabled: Bool
    var running: Bool
    var url: String?
}

/// WebSocket link to the helper. Publishes TV state and short messages for the user.
@MainActor
final class RemoteClient: ObservableObject {
    static let toastSeconds: UInt64 = 4
    /// MAX_TEXT_LENGTH in server.py.
    static let maxInsert = 2000
    /// The helper drops WebSocket frames over 64 KB, so held audio goes out in pieces.
    private static let audioFrameBytes = 8192
    private static let firstRetry: UInt64 = 500_000_000
    private static let maxRetry: UInt64 = 8_000_000_000

    @Published private(set) var state = TVState()
    @Published private(set) var linkUp = false
    @Published var toast: String?
    /// True while the TV's voice search is taking audio from us.
    @Published private(set) var listening = false
    @Published private(set) var phone: PhoneInfo?
    @Published private(set) var appsLink: AppsLink = .unknown
    /// Why the last connect or pairing failed, from the helper.
    @Published private(set) var appsMessage = ""
    /// Apps the user installed on the TV, by package, once the app manager is ready.
    @Published private(set) var installedApps: [String] = []

    /// Called when the link drops, before reconnecting. Lets the app restart the helper.
    var onLinkLost: (() async -> Void)?
    /// Called when the TV confirms an app was uninstalled.
    var onUninstalled: ((String) -> Void)?
    /// Called when a Connect attempt for the app manager ends without a link.
    var onAppsConnectFailed: ((AppsLink) -> Void)?
    /// Called when the TV stops taking voice (released, timed out, or the TV dropped).
    var onListeningEnded: (() -> Void)?

    private let token: String
    private var task: URLSessionWebSocketTask?
    private var toastClear: Task<Void, Never>?
    private var retryDelay = RemoteClient.firstRetry
    private var pendingLaunchLink: String?
    /// A Connect the user asked for, so its failure can be explained.
    private var connectingApps = false
    /// Microphone audio recorded before the TV starts listening.
    private var heldAudio = Data()
    private var voiceRequested = false
    /// Four seconds of TV-format audio (8 kHz, 16 bit, mono); later audio is not held.
    private static let maxHeldAudio = VoiceInput.bytesPerSecond * 4

    init(token: String) {
        self.token = token
    }

    func connect() {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(Helper.port)/ws")!)
        // The helper refuses other origins (web pages) and requests without our launch token.
        request.setValue(Helper.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(token, forHTTPHeaderField: Helper.tokenHeader)
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        Task { await receive(on: task) }
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard task === self.task else { return }
                await linkLost()
                return
            }
            guard case .string(let text) = message, let data = text.data(using: .utf8) else { continue }
            linkUp = true
            retryDelay = Self.firstRetry
            handle(data)
        }
    }

    private func handle(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        switch envelope.type {
        case "state":
            guard let next = try? JSONDecoder().decode(TVState.self, from: data) else { return }
            if !next.notice.isEmpty && next.noticeId != state.noticeId { show(next.notice) }
            state = next
        case "apps":
            if let message = try? JSONDecoder().decode(AppsMessage.self, from: data) {
                let previous = appsLink
                appsLink = message.status
                appsMessage = message.message ?? ""
                if let installed = message.installed { installedApps = installed }
                if connectingApps, [.off, .denied, .noAdb, .needsPairing].contains(message.status) {
                    connectingApps = false
                    onAppsConnectFailed?(message.status)
                } else if message.status == .ready || (previous == .waiting && message.status != .waiting) {
                    connectingApps = false
                }
            }
        case "apps_launched":
            pendingLaunchLink = nil
        case "apps_uninstalled":
            if let package = try? JSONDecoder().decode(PackageMessage.self, from: data).package {
                onUninstalled?(package)
            }
        case "phone":
            phone = try? JSONDecoder().decode(PhoneInfo.self, from: data)
        case "voice":
            listening = (try? JSONDecoder().decode(VoiceMessage.self, from: data))?.listening ?? false
            if !listening { onListeningEnded?() }
            if listening {
                var offset = heldAudio.startIndex
                while offset < heldAudio.endIndex {
                    let end = min(offset + Self.audioFrameBytes, heldAudio.endIndex)
                    task?.send(.data(heldAudio.subdata(in: offset..<end))) { _ in }
                    offset = end
                }
                heldAudio.removeAll()
                // Released before the TV was ready: end the session now that it exists.
                if !voiceRequested { send(["type": "voice_end"]) }
            }
        case "error":
            if envelope.for == "apps_launch", let link = pendingLaunchLink {
                // The app manager could not open it; the app's web link still can.
                pendingLaunchLink = nil
                open(link)
                return
            }
            if let text = envelope.message { show(text) }
            if envelope.for == "voice_start" {
                voiceRequested = false
                heldAudio.removeAll()
            }
        default:
            break
        }
    }

    private func linkLost() async {
        linkUp = false
        // A restarted helper has a fresh app manager; forget the old link so pinned apps fall back to links.
        appsLink = .unknown
        installedApps = []
        connectingApps = false
        if listening { onListeningEnded?() }
        listening = false
        voiceRequested = false
        heldAudio.removeAll()
        state.status = .searching
        await onLinkLost?()
        try? await Task.sleep(nanoseconds: retryDelay)
        retryDelay = min(retryDelay * 2, Self.maxRetry)
        connect()
    }

    func show(_ text: String) {
        toast = text
        toastClear?.cancel()
        toastClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.toastSeconds * 1_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: commands

    func press(_ key: RemoteKey) {
        guard requireConnected() else { return }
        send(["type": "key", "key": key.rawValue])
    }

    /// Insert text at the cursor of the TV text box.
    func insert(_ text: String) {
        guard !text.isEmpty, requireConnected() else { return }
        // Count code points, as the helper does, so a paste near the limit is not rejected whole.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(Self.maxInsert))
        if scalars.count < text.unicodeScalars.count {
            show("Only the first \(Self.maxInsert) characters were sent.")
        }
        send(["type": "edit", "text": String(scalars)])
    }

    /// Empty the TV text box. The helper deletes from the end, using the text it has from the TV.
    func clearField() {
        guard requireConnected() else { return }
        send(["type": "edit", "clear": true])
    }

    func edit(_ key: EditKey) {
        guard requireConnected() else { return }
        send(["type": "edit", "key": key.rawValue])
    }

    func launch(_ app: String) {
        guard requireConnected() else { return }
        send(["type": "app", "app": app])
    }

    // MARK: voice

    func startVoice() {
        guard requireConnected() else { return }
        voiceRequested = true
        heldAudio.removeAll()
        send(["type": "voice_start"])
    }

    func sendVoiceAudio(_ pcm: Data) {
        guard voiceRequested || listening, let task else { return }
        if listening {
            task.send(.data(pcm)) { _ in }
        } else if heldAudio.count < Self.maxHeldAudio {
            heldAudio.append(pcm)
        }
    }

    func endVoice() {
        voiceRequested = false
        if listening { send(["type": "voice_end"]) }
    }

    /// Open a web link on the TV; apps that own the link (YouTube, Netflix) open it.
    @discardableResult
    func open(_ link: String) -> Bool {
        guard requireConnected() else { return false }
        return send(["type": "open", "link": link])
    }

    func searchYouTube(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, requireConnected() else { return }
        send(["type": "search", "query": query])
    }

    // MARK: installed apps (ADB)

    func connectApps() {
        connectingApps = true
        send(["type": "apps_connect"])
    }
    func refreshApps() { send(["type": "apps_list"]) }
    /// Pair with the TV's Wireless debugging code. `address` is the host:port the TV shows, if typed.
    func pairApps(code: String, address: String) {
        connectingApps = true
        send(["type": "apps_pair", "code": code, "address": address])
    }
    /// Open an app through the TV's app manager. `fallbackLink` opens instead if that fails.
    func launchApp(_ package: String, fallbackLink: String? = nil) {
        guard requireConnected() else { return }
        pendingLaunchLink = fallbackLink
        send(["type": "apps_launch", "package": package])
    }
    func uninstallApp(_ package: String) { send(["type": "apps_uninstall", "package": package]) }

    // MARK: phone remote

    func refreshPhone() { send(["type": "phone_get"]) }
    func setPhone(enabled: Bool) { send(["type": "phone_set", "enabled": enabled]) }
    func resetPhonePairing() { send(["type": "phone_reset"]) }

    func startPairing() { send(["type": "pair_start"]) }

    func submitPairing(_ code: String) { send(["type": "pair_code", "code": code]) }

    private func requireConnected() -> Bool {
        if state.isConnected { return true }
        show(state.needsPairing ? "Pair with the TV first." : "Not connected to the TV yet.")
        return false
    }

    @discardableResult
    private func send(_ payload: [String: Any]) -> Bool {
        guard let task, linkUp,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            show("Couch is still starting. Try again in a moment.")
            return false
        }
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            // A failed send means the socket is dead; cancelling makes receive() fail and reconnect.
            Task { @MainActor in
                guard let self, task === self.task else { return }
                self.show("Lost the link to the TV. Reconnecting.")
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        return true
    }
}
