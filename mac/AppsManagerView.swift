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
            .padding(.bottom, 12)

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
            .searchable(text: $search, placement: .toolbar, prompt: "Find an app")
        }
        .frame(width: 520, height: 600)
        .onAppear { if client.appsLink != .ready { client.connectApps() } else { client.refreshApps() } }
        .confirmationDialog(uninstallTitle, isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let package = uninstalling {
                    client.uninstallApp(package)
                    favourites.unpin(package)
                    favourites.forget(package)
                }
                uninstalling = nil
            }
        } message: {
            Text("The app and its data are removed from the TV. You can install it again from the Play Store on the TV.")
        }
        .alert("Edit app", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
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

    private var filteredInstalled: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = client.installedApps.sorted { friendlyApp($0).localizedCaseInsensitiveCompare(friendlyApp($1)) == .orderedAscending }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { friendlyApp($0).lowercased().contains(query) || $0.lowercased().contains(query) }
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
                Text("The TV did not allow Couch, or nobody answered in time.")
                Button("Try Again") { client.connectApps() }
            }
        case .off, .unknown:
            VStack(alignment: .leading, spacing: 8) {
                Text("To see and remove every app on your TV, turn on Android debugging once:")
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Settings › System › About: press “Android TV OS build” 7 times.")
                Text("2. Settings › System › Developer options: turn on USB debugging.")
                Text("3. Come back here and choose Connect. Allow Couch on the TV.")
                Button("Connect") { client.connectApps() }
                    .padding(.top, 2)
            }
            .font(.callout)
        }
    }

    private func edit(_ app: FavouriteApp) {
        newName = app.name
        newLink = app.link ?? ""
        editing = app
    }
}
