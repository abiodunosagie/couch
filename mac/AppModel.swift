import AppKit
import Combine
import SwiftUI

/// Shared app state for the window and the menu bar panel.
@MainActor
final class AppModel: ObservableObject {
    let helper = Helper()
    let client: RemoteClient
    let voice: VoiceInput
    let favourites: Favourites
    let automations: Automations
    let scenes: Scenes

    @Published var finish: Finish {
        didSet { UserDefaults.standard.set(finish.rawValue, forKey: "finish") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            do {
                try LoginItem.set(enabled: launchAtLogin)
            } catch {
                client.show("Could not change the login setting.")
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }
    /// Shows the Apps manager sheet in the window.
    @Published var showingApps = false
    /// While on, the Mac keyboard types into the TV text box instead of pressing remote buttons.
    @Published var typing = false {
        didSet {
            if !typing { hideFieldText = false }
            if typing { searching = false }
        }
    }
    /// Shows the YouTube search field.
    @Published var searching = false {
        didSet { if searching { typing = false } }
    }
    /// Size of the remote in the menu bar panel, chosen so the panel fits the screen.
    @Published var panelScale: CGFloat = 0.74
    @Published private(set) var startFailed = false
    /// Where the remote sits in each window (by window number), for trackpad swipes. Not published:
    /// it changes on every layout and nothing redraws from it.
    var remoteZones: [Int: CGRect] = [:]
    /// Global shortcuts another app already owns.
    @Published var unavailableShortcuts: [String] = []

    private var linkWatch: AnyCancellable?


    init() {
        client = RemoteClient(token: helper.token)
        voice = VoiceInput(client: client)
        favourites = Favourites(client: client)
        automations = Automations(client: client, favourites: favourites)
        scenes = Scenes(client: client, automations: automations, favourites: favourites)
        finish = Finish(rawValue: UserDefaults.standard.string(forKey: "finish") ?? "") ?? .snow
        launchAtLogin = LoginItem.isEnabled
        client.onLinkLost = { [weak self] in
            guard let self else { return }
            self.startFailed = !(await self.helper.ensureRunning())
        }
        client.onUninstalled = { [weak self] package in
            guard let self else { return }
            self.favourites.unpin(package)
            self.favourites.forget(package)
            self.client.show("\(friendlyApp(package)) was removed from the TV.")
        }
        client.onAppsConnectFailed = { [weak self] status in
            guard let self else { return }
            let reason = self.client.appsMessage
            switch status {
            case .needsPairing: self.client.show(reason.isEmpty ? "Pair Couch with the TV once: see Apps." : reason)
            case .denied: self.client.show(reason.isEmpty ? "The TV did not allow Couch. Try again." : reason)
            case .noAdb: self.client.show("Google's adb tool is missing. See Apps.")
            default: self.client.show(reason.isEmpty ? "Couch could not find debugging on the TV. See the steps in Apps." : reason)
            }
        }
        // A slow first start can time out and then succeed; clear the error once the link is up.
        linkWatch = client.$linkUp.sink { [weak self] up in
            if up { MainActor.assumeIsolated { self?.startFailed = false } }
        }
    }

    /// Uninstall from the TV. The pin goes only when the TV confirms (onUninstalled).
    func uninstall(_ package: String) {
        client.uninstallApp(package)
    }

    func start() async {
        startFailed = !(await helper.ensureRunning())
        client.connect()
    }

    /// Open a pinned app: by package through the TV's app manager when it is on, else by its web link.
    func openApp(_ app: FavouriteApp) {
        if client.appsLink == .ready {
            client.launchApp(app.package, fallbackLink: app.link)
        } else if let link = app.link {
            client.open(link)
        } else {
            client.show("Turn on the app manager in Apps, or add a link for \(app.name).")
        }
    }

    /// Send a web link to the TV: YouTube links play in the YouTube app, others open in the TV browser.
    func sendLink(_ url: URL) {
        guard url.isWebLink else {
            client.show("Only web links can go to the TV.")
            return
        }
        if client.open(url.absoluteString) { client.show("Sent to the TV.") }
    }

    /// Send the link on the Mac clipboard, if there is one.
    func sendClipboardLink() {
        let board = NSPasteboard.general
        let text = board.string(forType: .URL) ?? board.string(forType: .string) ?? ""
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.isWebLink else {
            client.show("The clipboard has no web link.")
            return
        }
        sendLink(url)
    }

    /// Hides the mirrored TV text, for passwords. Turns on by itself after pasting one.
    @Published var hideFieldText = false

    /// Paste the Mac clipboard into the TV text box.
    func paste() {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string), !text.isEmpty else {
            client.show("The clipboard has no text.")
            return
        }
        // Password managers mark copied secrets; keep them off the screen once on the TV.
        if board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true {
            hideFieldText = true
        }
        client.insert(text)
    }

    var statusText: String {
        if startFailed { return "Couldn't start" }
        if !client.linkUp { return "Starting" }
        switch client.state.status {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .offline: return "TV not reachable"
        case .unpaired: return "Not paired"
        case .pairing: return "Pairing"
        case .searching, .unknown: return "Looking for your TV"
        }
    }
}
