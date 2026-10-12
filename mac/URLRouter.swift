import AppKit

/// Handles couch:// links from Shortcuts, scripts and bookmarks:
///   couch://link?url=https://...    open a web link on the TV (asks first)
///   couch://app?name=Netflix        open a pinned app (asks first)
///   couch://key?name=MEDIA_PAUSE    play, pause or play/pause only
///
/// Any web page can open a couch:// link, so links and apps ask before they reach the TV,
/// and only harmless keys are allowed. A link that arrives while Couch is still connecting
/// waits for the connection instead of being lost.
@MainActor
final class URLRouter {
    private let model: AppModel
    private static let allowedKeys: Set<RemoteKey> = [.playPause, .pause, .play]
    private static let connectWaitSeconds = 20.0
    private static let pollInterval = Duration.milliseconds(250)

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ url: URL) {
        guard url.scheme == "couch" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        Task {
            guard await waitForConnection() else {
                model.client.show("Couch could not reach the TV for that link.")
                return
            }
            switch url.host {
            case "link":
                guard let link = value("url").flatMap(URL.init(string:)), link.isWebLink else {
                    model.client.show("That couch:// link has no web address.")
                    return
                }
                if confirm("Open \(link.host ?? "this link") on the TV?", detail: link.absoluteString) {
                    model.sendLink(link)
                }
            case "app":
                let pinned = model.favourites.pinned.first { $0.package == value("package") || $0.name == value("name") }
                guard let pinned, let link = pinned.link else {
                    model.client.show("No pinned app by that name.")
                    return
                }
                if confirm("Open \(pinned.name) on the TV?", detail: "A couch:// link asked to open it.") {
                    model.client.open(link)
                }
            case "key":
                guard let key = value("name").flatMap(RemoteKey.init(rawValue:)), Self.allowedKeys.contains(key) else {
                    model.client.show("couch:// links can only play and pause.")
                    return
                }
                model.client.press(key)
            default:
                model.client.show("Couch did not understand that link.")
            }
        }
    }

    private func waitForConnection() async -> Bool {
        let deadline = Date().addingTimeInterval(Self.connectWaitSeconds)
        while Date() < deadline {
            if model.client.linkUp && model.client.state.isConnected { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    private func confirm(_ message: String, detail: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
