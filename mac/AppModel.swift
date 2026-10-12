import AppKit
import Combine
import SwiftUI

/// Shared app state for the window and the menu bar panel.
@MainActor
final class AppModel: ObservableObject {
    let helper = Helper()
    let client: RemoteClient
    let voice: VoiceInput

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
    @Published var typing = false
    /// Size of the remote in the menu bar panel, chosen so the panel fits the screen.
    @Published var panelScale: CGFloat = 0.74
    @Published private(set) var startFailed = false

    private var linkWatch: AnyCancellable?

    init() {
        client = RemoteClient(token: helper.token)
        voice = VoiceInput(client: client)
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

    /// Paste the Mac clipboard into the TV text box.
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            client.show("The clipboard has no text.")
            return
        }
        client.insert(text)
    }

    /// Empty the TV text box by deleting from the end.
    func clearField() {
        guard let field = client.state.field, field.active else { return }
        client.edit(.lineEnd)
        for _ in field.value { client.edit(.deleteBackward) }
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
]

/// A readable name for the app on the TV; unknown apps show their package name.
func friendlyApp(_ package: String?) -> String {
    guard let package else { return "nothing yet" }
    return appNames[package] ?? package
}
