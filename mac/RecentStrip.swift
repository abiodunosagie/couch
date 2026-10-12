import SwiftUI

/// The TV's recent apps as cards: click one to bring it back where you left it.
struct RecentStrip: View {
    @ObservedObject var client: RemoteClient
    var compact = false

    var body: some View {
        Group {
            if client.appsLink != .ready {
                Text("Connect the app manager in Apps to see recent apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if client.recentApps.isEmpty {
                Text("No recent apps yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(client.recentApps) { app in
                            RecentCard(app: app, current: app.package == client.state.app, compact: compact,
                                       open: { client.resume(app.package) },
                                       close: { client.closeApp(app.package) })
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 6)
                }
            }
        }
        .onAppear { if client.appsLink == .ready && client.recentApps.isEmpty { client.refreshRecents() } }
        .onChange(of: client.appsLink) { if client.appsLink == .ready { client.refreshRecents() } }
    }
}

private struct RecentCard: View {
    let app: RecentApp
    let current: Bool
    let compact: Bool
    let open: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var name: String { app.name ?? friendlyApp(app.package) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(current ? Color.green : (app.live ? Color.secondary.opacity(0.6) : Color.clear))
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: app.live ? 0 : 1))
                        .frame(width: 6, height: 6)
                    Text(name).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
                }
                Text(current ? "On screen" : Self.ago(app.inactive))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: compact ? 96 : 118, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(hovering ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .help(app.live ? "Back to \(name) where you left it" : "Open \(name) (it was closed, so it starts fresh)")
        .padding(.top, 6)
        .padding(.trailing, 6)
        .overlay(alignment: .topTrailing) {
            if hovering && !current {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
                .help("Close \(name) on the TV to free memory")
                .accessibilityLabel("Close \(name)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu {
            Button("Open", action: open)
            Button("Close on the TV", role: .destructive, action: close)
        }
    }

    static func ago(_ seconds: Int?) -> String {
        guard let seconds else { return "Recently" }
        switch seconds {
        case ..<60: return "Just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
