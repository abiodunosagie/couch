import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var menuPanel: MenuPanel?
    private var shortcuts: GlobalShortcuts?
    private let volumeHUD = VolumeHUD()
    private var stateWatch: AnyCancellable?
    private var appsWatch: AnyCancellable?
    private var window: NSWindow?
    private var keyRouter: KeyRouter?
    private var trackpad: TrackpadRouter?
    private lazy var urlRouter = URLRouter(model: model)

    override init() {
        model = AppModel()
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Asks an already running Couch to show its window; see `handOffToRunningCopy`.
    private static let showWindowNotification = Notification.Name("com.abiodun.couch.showWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if handOffToRunningCopy(background: arguments.contains(LoginItem.backgroundArgument)) { return }

        // No Dock icon until the window opens, so login start is menu bar only.
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        buildStatusItem()
        keyRouter = KeyRouter(
            model: model,
            isRemoteWindow: { [weak self] in $0 === self?.window || $0 === self?.menuPanel?.window },
            isPanel: { [weak self] in $0 === self?.menuPanel?.window },
            closePanel: { [weak self] in self?.menuPanel?.close() })
        keyRouter?.install()
        trackpad = TrackpadRouter(model: model)
        trackpad?.install()
        Task { await model.start() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindow), name: Self.showWindowNotification, object: nil)

        if arguments.contains("--show-apps") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.showingApps = true }
        }
        if arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePanel() }
        } else if !arguments.contains(LoginItem.backgroundArgument) {
            showWindow()
        }
    }

    /// One Couch at a time: two would fight over the helper port and the hot key.
    /// Returns true when another copy is running and this one is quitting.
    private func handOffToRunningCopy(background: Bool) -> Bool {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: LoginItem.label)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return false }
        if !background {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        NSApp.terminate(nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(urlRouter.handle)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.helper.stop()
    }

    // MARK: window

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Couch"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Branded(MainWindowView(model: model)))
            window.setFrameAutosaveName("CouchMainWindow")
            if !window.setFrameUsingName("CouchMainWindow") { window.center() }
            window.delegate = self
            self.window = window
        }
        menuPanel?.close()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The Apps manager as a real sheet on the window.
    private func showAppsSheet() {
        showWindow()
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: Branded(AppsManagerView(model: model) { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.window?.endSheet(sheet)
        }))
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.showingApps = false }
        }
    }

    func windowWillClose(_ notification: Notification) {
        Repeater.stopAll()
        // Back to a menu bar only app once the window is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidResignKey(_ notification: Notification) {
        Repeater.stopAll()
    }

    // MARK: menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        item.autosaveName = "CouchStatusItem"
        statusItem = item
        if let button = item.button {
            // Drop a link from a browser on the icon to play it on the TV.
            let drop = LinkDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onLink = { [weak self] url in self?.model.sendLink(url) }
            drop.onClick = { [weak self] in self?.togglePanel() }
            drop.onMenu = { [weak self] view in self?.showIconMenu(below: view) }
            button.addSubview(drop)
        }

        menuPanel = MenuPanel(model: model, openWindow: { [weak self] in self?.showWindow() },
                              quit: { NSApp.terminate(nil) })
        installShortcuts()
        // The icon is solid while the TV is on and connected, an outline otherwise.
        stateWatch = model.client.$state.combineLatest(model.client.$linkUp)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, linkUp in
                MainActor.assumeIsolated { self?.updateStatusIcon(state, linkUp: linkUp) }
            }
        updateStatusIcon(model.client.state, linkUp: false)
        // Manage (in the window or the menu bar panel) opens the Apps sheet on the window.
        appsWatch = model.$showingApps.sink { [weak self] showing in
            guard showing else { return }
            DispatchQueue.main.async { self?.showAppsSheet() }
        }
    }

    private func updateStatusIcon(_ state: TVState, linkUp: Bool) {
        guard let button = statusItem?.button else { return }
        let live = linkUp && state.isConnected && state.isOn != false
        button.image = Brand.menuBarImage(live: live)
        let tv = state.tv ?? "TV"
        let detail: String
        if !linkUp || !state.isConnected {
            detail = "\(tv): not connected"
        } else if state.isOn == false {
            detail = "\(tv) is off"
        } else {
            detail = "\(tv): \(friendlyApp(state.app))"
        }
        button.toolTip = "Couch, \(detail)\nOption Command R opens the remote"
    }

    // MARK: global shortcuts

    private func installShortcuts() {
        let controlOption = controlKey | optionKey
        let press: (RemoteKey) -> Void = { [weak self] key in self?.model.client.press(key) }
        let volume: (RemoteKey, VolumeHUD.Change) -> Void = { [weak self] key, change in
            guard let self, self.model.client.state.isConnected else { return }
            self.model.client.press(key)
            self.volumeHUD.show(change, tv: self.model.client.state.tv)
        }
        let list: [GlobalShortcuts.Shortcut] = [
            .init(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey, label: "Option Command R",
                  action: { [weak self] in self?.togglePanel() }),
            .init(keyCode: kVK_Space, modifiers: controlOption, label: "Control Option Space",
                  action: { press(.playPause) }),
            .init(keyCode: kVK_UpArrow, modifiers: controlOption, label: "Control Option Up",
                  action: { volume(.volumeUp, .up) }),
            .init(keyCode: kVK_DownArrow, modifiers: controlOption, label: "Control Option Down",
                  action: { volume(.volumeDown, .down) }),
            .init(keyCode: kVK_ANSI_M, modifiers: controlOption, label: "Control Option M",
                  action: { volume(.mute, .mute) }),
            .init(keyCode: kVK_ANSI_P, modifiers: controlOption, label: "Control Option P",
                  action: { press(.power) }),
        ]
        shortcuts = GlobalShortcuts(list)
        model.unavailableShortcuts = shortcuts?.unavailable ?? []
    }

    /// The menu bar icon's own menu, like every menu bar app: open the window or quit.
    private func showIconMenu(below view: NSView) {
        menuPanel?.close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Couch", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Panel", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Couch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The drop view is not flipped, so y below 0 is just under the icon.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    @objc func togglePanel() {
        menuPanel?.toggle(below: statusItem?.button)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Couch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Couch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command]
        appMenu.addItem(withTitle: "Quit Couch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu so copy and paste work in the text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Remote", action: #selector(showWindow), keyEquivalent: "1").target = self
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
