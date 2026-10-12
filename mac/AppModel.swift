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
        automations = Automations(client: client, voice: voice, favourites: favourites)
        scenes = Scenes(client: client, automations: automations, favourites: favourites)
        finish = Finish(rawValue: UserDefaults.standard.string(forKey: "finish") ?? "") ?? .snow
        launchAtLogin = LoginItem.isEnabled
        client.onLinkLost = { [weak self] in
            guard let self else { return }
            self.startFailed = !(await self.helper.ensureRunning())
        }
        // A slow first start can time out and then succeed; clear the error once the link is up.
        linkWatch = client.$linkUp.sink { [weak self] up in
            if up { MainActor.assumeIsolated { self?.startFailed = false } }
        }
    }

    func start() async {
        startFailed = !(await helper.ensureRunning())
        client.connect()
    }

    /// Send a web link to the TV: YouTube links play in the YouTube app, others open in the TV browser.
    func sendLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            client.show("Only web links can go to the TV.")
            return
        }
        client.open(url.absoluteString)
        client.show("Sent to the TV.")
    }

    /// Send the link on the Mac clipboard, if there is one.
    func sendClipboardLink() {
        let board = NSPasteboard.general
        let text = board.string(forType: .URL) ?? board.string(forType: .string) ?? ""
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
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

private let appNames = [
    "com.google.android.youtube.tv": "YouTube",
    "com.google.android.youtube.tvkids": "YouTube Kids",
    "com.netflix.ninja": "Netflix",
    "com.amazon.amazonvideo.livingroom": "Prime Video",
    "com.disney.disneyplus": "Disney+",
    "com.spotify.tv.android": "Spotify",
    "com.google.android.apps.tv.launcherx": "Home screen",
    "com.google.android.tvlauncher": "Home screen",
    "com.android.tv.settings": "Settings",
    "com.neilturner.aerialviews": "Screensaver",
    "com.apple.atve.androidtv.appletv": "Apple TV",
]

/// A readable name for the app on the TV; unknown apps show their package name.
func friendlyApp(_ package: String?) -> String {
    guard let package else { return "nothing yet" }
    return appNames[package] ?? package
}
