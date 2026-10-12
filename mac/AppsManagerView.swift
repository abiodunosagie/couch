import SwiftUI

/// Manage apps: reorder and remove pinned apps, and (with the TV's app manager on) see every
/// app installed on the TV, open it, pin it or uninstall it.
struct AppsManagerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: RemoteClient
    @ObservedObject var favourites: Favourites
    let close: () -> Void

    @State private var search = ""
    @State private var uninstalling: String?
    @State private var editing: FavouriteApp?
    @State private var newName = ""
    @State private var newLink = ""
    @State private var showPairing = false

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        self.client = model.client
        self.favourites = model.favourites
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(.title2.weight(.bold))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)

            if client.appsLink == .ready {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an app", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            List {
                Section("Pinned") {
                    if favourites.pinned.isEmpty {
                        Text("No pinned apps. Pin one below.").foregroundStyle(.secondary)
                    }
                    ForEach(favourites.pinned) { app in
                        pinnedRow(app)
                    }
                    .onMove { favourites.move(from: $0, to: $1) }
                    .onDelete { offsets in
                        offsets.map { favourites.pinned[$0].package }.forEach(favourites.unpin)
                    }
                }

                Section {
                    managerState
                    if client.appsLink == .ready {
                        ForEach(filteredInstalled, id: \.self) { package in
                            installedRow(package)
                        }
                    }
                } header: {
                    HStack {
                        Text("On your TV")
                        Spacer()
                        if client.appsLink == .ready {
                            Button { client.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .help("Reload the list from the TV")
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .sheet(isPresented: $showPairing) {
                PairingSteps(client: client).padding(20).frame(width: 440)
                    .overlay(alignment: .topTrailing) {
                        Button("Close") { showPairing = false }.padding(12)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onExitCommand(perform: close)
        // Opened before the helper link was up: the first Connect was lost, so ask again once it is.
        .onChange(of: client.linkUp) { if client.linkUp && client.appsLink == .unknown { client.connectApps() } }
        .onAppear {
            switch client.appsLink {
            case .ready: if client.installedApps.isEmpty { client.refreshApps() }
            // Never re-prompt on the TV by itself after a refusal, while a prompt is up, or while pairing.
            case .denied, .waiting, .pairing, .needsPairing, .noAdb: break
            case .off, .unknown: client.connectApps()
            }
        }
        .confirmationDialog(uninstallTitle, isPresented: isPresent($uninstalling)) {
            Button("Uninstall", role: .destructive) {
                if let package = uninstalling { model.uninstall(package) }
                uninstalling = nil
            }
        } message: {
            Text("The app and its data are removed from the TV. You can install it again from the Play Store on the TV.")
        }
        .alert("Edit app", isPresented: isPresent($editing)) {
            TextField("Name", text: $newName)
            TextField("Web link (used when the app manager is off)", text: $newLink)
            Button("Save") {
                if let app = editing, !favourites.update(app.package, name: newName, link: newLink) {
                    client.show("The link must start with https://")
                }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private var uninstallTitle: String {
        "Uninstall \(uninstalling.map(friendlyApp) ?? "this app") from the TV?"
    }

    static let size = CGSize(width: 520, height: 620)

    private var filteredInstalled: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let named = client.installedApps.map { (package: $0, name: friendlyApp($0)) }
        return named
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.package.lowercased().contains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.package)
    }

    /// A Bool binding that is true while an optional is set, for alerts and dialogs.
    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: rows

    private func pinnedRow(_ app: FavouriteApp) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.package).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { model.openApp(app) }
            Button { edit(app) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Rename \(app.name)")
            Button { favourites.unpin(app.package) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                .buttonStyle(.borderless)
                .help("Remove \(app.name) from the Apps row")
                .accessibilityLabel("Remove \(app.name) from the Apps row")
        }
        .padding(.vertical, 2)
    }

    private func installedRow(_ package: String) -> some View {
        let pinned = favourites.isPinned(package)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(friendlyApp(package))
                Text(package).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { pinned ? favourites.unpin(package) : favourites.pin(package) } label: {
                Image(systemName: pinned ? "star.fill" : "star").foregroundStyle(pinned ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(pinned ? "Unpin" : "Pin to the Apps row")
            Button("Open") { client.launchApp(package) }
            Button { uninstalling = package } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Uninstall from the TV")
                .accessibilityLabel("Uninstall \(friendlyApp(package))")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var managerState: some View {
        switch client.appsLink {
        case .ready:
            if client.installedApps.isEmpty {
                Text("Loading the apps on your TV…").foregroundStyle(.secondary)
            }
        case .waiting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Look at the TV: tick “Always allow from this computer”, then choose Allow.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text(client.appsMessage.isEmpty ? "The TV did not allow Couch, or nobody answered in time." : client.appsMessage)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { client.connectApps() }
                    Button("Pair with a Code") { showPairing = true }
                }
            }
        case .needsPairing:
            PairingSteps(client: client)
        case .pairing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Pairing with the TV…")
            }
        case .noAdb:
            VStack(alignment: .leading, spacing: 8) {
                Text("Couch uses Google's adb tool to manage apps. Install it once in Terminal:")
                Text("brew install --cask android-platform-tools").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Check Again") { client.connectApps() }
            }
            .font(.callout)
        case .off, .unknown:
            DebuggingSteps { client.connectApps() }
        }
    }

    private func edit(_ app: FavouriteApp) {
        newName = app.name
        newLink = app.link ?? ""
        editing = app
    }
}

/// The one time TV setup that lets Couch see and remove apps.
private struct DebuggingSteps: View {
    let connect: () -> Void
    private static let steps = [
        "Settings › System › About: press “Android TV OS build” 7 times.",
        "Settings › System › Developer options: turn on USB debugging, and Wireless debugging if it is there.",
        "Come back here and choose Connect. Couch asks for a pairing code, or the TV asks you to allow this Mac.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To see, open and remove every app on your TV, turn on Android debugging once:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").fixedSize(horizontal: false, vertical: true)
            }
            Button("Connect", action: connect).padding(.top, 2)
        }
        .font(.callout)
    }
}

/// Wireless debugging: pair once with the 6 digit code the TV shows.
private struct PairingSteps: View {
    @ObservedObject var client: RemoteClient
    @State private var code = ""
    @State private var address = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair Couch with the TV once").font(.headline)
            Text("1. On the TV open Settings › System › Developer options › Wireless debugging.")
            Text("2. Choose “Pair device with pairing code” and leave that screen open.")
            Text("3. Type the 6 digit code it shows:")
            HStack(spacing: 8) {
                TextField("123456", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .frame(width: 120)
                    .focused($codeFocused)
                    .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
                    .onSubmit(pair)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6)
            }
            DisclosureGroup("Couch cannot find the TV?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type the IP address and port shown under the code, like 192.168.1.11:37000.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("IP address and port", text: $address).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                .padding(.top, 4)
            }
            if !client.appsMessage.isEmpty {
                Text(client.appsMessage).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .onAppear { codeFocused = true }
    }

    private func pair() {
        guard code.count == 6 else { return }
        client.pairApps(code: code, address: address.trimmingCharacters(in: .whitespaces))
    }
}
