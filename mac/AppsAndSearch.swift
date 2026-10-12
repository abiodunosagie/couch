import SwiftUI

/// Pinned TV apps as one click buttons, with a menu to pin more.
struct AppsRow: View {
    @ObservedObject var favourites: Favourites
    @ObservedObject var client: RemoteClient
    var compact = false

    @State private var editing: FavouriteApp?
    @State private var newName = ""
    @State private var newLink = ""

    var body: some View {
        let chips = HStack(spacing: 8) {
            ForEach(favourites.pinned) { app in
                Button(app.name) { open(app) }
                    .buttonStyle(.bordered)
                    .controlSize(compact ? .small : .regular)
                    .opacity(app.link == nil ? 0.55 : 1)
                    .help(app.link == nil ? "Right click to add a link for \(app.name)" : "Open \(app.name) on the TV")
                    .contextMenu {
                        Button("Edit Name and Link") { edit(app) }
                        Button("Remove") { favourites.unpin(app.package) }
                    }
            }
            addMenu
        }

        Group {
            if compact {
                ScrollView(.horizontal, showsIndicators: false) { chips }
            } else {
                // Wraps naturally in the window's fixed width column.
                ViewThatFits(in: .horizontal) {
                    chips
                    ScrollView(.horizontal, showsIndicators: false) { chips }
                }
            }
        }
        .alert("Edit app", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $newName)
            TextField("Web link that opens it, like https://www.netflix.com/title", text: $newLink)
            Button("Save") {
                if let app = editing, !favourites.update(app.package, name: newName, link: newLink) {
                    client.show("The link must start with https://")
                }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("The TV only opens apps from web links they own. Most streaming apps open from their website address.")
        }
    }

    private func open(_ app: FavouriteApp) {
        if let link = app.link {
            client.open(link)
        } else {
            edit(app)
        }
    }

    private func edit(_ app: FavouriteApp) {
        newName = app.name
        newLink = app.link ?? ""
        editing = app
    }

    private var addMenu: some View {
        Menu {
            if let current = client.state.app, !favourites.isPinned(current) {
                Button("Pin \(favourites.defaultName(for: current)) (on now)") { favourites.pin(current) }
                Divider()
            }
            let others = favourites.unpinnedSeen.filter { $0 != client.state.app }
            if others.isEmpty && (client.state.app == nil || favourites.isPinned(client.state.app!)) {
                Text("Open an app on the TV and it shows up here")
            }
            ForEach(others, id: \.self) { package in
                Button(favourites.defaultName(for: package)) { favourites.pin(package) }
            }
            let popular = Favourites.knownLinks.keys.filter { !favourites.isPinned($0) && !others.contains($0) }.sorted()
            if !popular.isEmpty {
                Divider()
                Text("Popular apps")
                ForEach(popular, id: \.self) { package in
                    Button(favourites.defaultName(for: package)) { favourites.pin(package) }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pin an app")
    }
}

/// Search YouTube on the TV.
struct SearchBar: View {
    let client: RemoteClient
    /// Focus the field as soon as it appears; it is only shown on demand, so it never takes keys meant for the remote.
    var focusOnAppear = false
    var onDone: () -> Void = {}
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search YouTube on the TV", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(search)
                .onExitCommand {
                    focused = false
                    onDone()
                }
            if !query.isEmpty {
                Button("Search", action: search).controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
        .onAppear { if focusOnAppear { focused = true } }
    }

    private func search() {
        client.searchYouTube(query)
        query = ""
        focused = false
        onDone()
    }
}
