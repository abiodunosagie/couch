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
}

/// WebSocket link to the helper. Publishes TV state and short messages for the user.
@MainActor
final class RemoteClient: ObservableObject {
    static let toastSeconds: UInt64 = 4
    /// MAX_TEXT_LENGTH in server.py.
    static let maxInsert = 2000
    private static let firstRetry: UInt64 = 500_000_000
    private static let maxRetry: UInt64 = 8_000_000_000

    @Published private(set) var state = TVState()
    @Published private(set) var linkUp = false
    @Published var toast: String?

    /// Called when the link drops, before reconnecting. Lets the app restart the helper.
    var onLinkLost: (() async -> Void)?

    private let token: String
    private var task: URLSessionWebSocketTask?
    private var toastClear: Task<Void, Never>?
    private var retryDelay = RemoteClient.firstRetry

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
        case "error":
            if let text = envelope.message { show(text) }
        default:
            break
        }
    }

    private func linkLost() async {
        linkUp = false
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
        send(["type": "edit", "text": String(text.prefix(Self.maxInsert))])
    }

    func edit(_ key: EditKey) {
        guard requireConnected() else { return }
        send(["type": "edit", "key": key.rawValue])
    }

    func launch(_ app: String) {
        guard requireConnected() else { return }
        send(["type": "app", "app": app])
    }

    func startPairing() { send(["type": "pair_start"]) }

    func submitPairing(_ code: String) { send(["type": "pair_code", "code": code]) }

    private func requireConnected() -> Bool {
        if state.isConnected { return true }
        show(state.needsPairing ? "Pair with the TV first." : "Not connected to the TV yet.")
        return false
    }

    private func send(_ payload: [String: String]) {
        guard let task, linkUp,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            show("Couch is still starting. Try again in a moment.")
            return
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
    }
}
