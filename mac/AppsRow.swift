import SwiftUI

/// Pinned TV apps as one click buttons. Hover a button to remove it; Manage opens the full list.
struct AppsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var favourites: Favourites
    var compact = false

    init(model: AppModel, compact: Bool = false) {
        self.model = model
        self.favourites = model.favourites
        self.compact = compact
    }

    var body: some View {
        // Manage stays outside the scrolling chips, so it is always in reach.
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(favourites.pinned) { app in
                        AppChip(app: app, compact: compact,
                                open: { model.openApp(app) },
                                remove: { withAnimation(.easeOut(duration: 0.15)) { favourites.unpin(app.package) } })
                    }
                }
                .padding(.vertical, 2)
            }
            Button { model.showingApps = true } label: {
                Label(favourites.pinned.isEmpty ? "Add apps" : "Manage", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .help("See every app: pin, remove or uninstall")
        }
    }
}

private struct AppChip: View {
    let app: FavouriteApp
    let compact: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(app.name, action: open)
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .help("Open \(app.name) on the TV")
            .contextMenu {
                Button("Open", action: open)
                Button("Remove from Apps Row", role: .destructive, action: remove)
            }
            // The badge sits inside the padded area, so moving onto it keeps the hover.
            .padding(.top, 6)
            .padding(.trailing, 6)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(app.name) from this row")
                    .accessibilityLabel("Remove \(app.name)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}
