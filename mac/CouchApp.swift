import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var menuPanel: MenuPanel?
    private var hotKey: GlobalHotKey?
    private var window: NSWindow?
    private var keyRouter: KeyRouter?

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
        Task { await model.start() }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindow), name: Self.showWindowNotification, object: nil)

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
            window.contentView = NSHostingView(rootView: MainWindowView(model: model))
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
            button.image = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: "Couch")
            button.toolTip = "Couch, TV remote (Option Command R)"
            button.target = self
            button.action = #selector(togglePanel)
        }
        item.autosaveName = "CouchStatusItem"
        statusItem = item

        menuPanel = MenuPanel(model: model, openWindow: { [weak self] in self?.showWindow() },
                              quit: { NSApp.terminate(nil) })
        hotKey = GlobalHotKey { [weak self] in self?.togglePanel() }
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
