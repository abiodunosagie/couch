import SwiftUI
import UniformTypeIdentifiers

/// The TV tab: space and memory, speed and sleep, installing apps and the home screen.
struct TVToolsView: View {
    @ObservedObject var client: RemoteClient
    @State private var dropTargeted = false
    @State private var confirmFreeMemory = false

    private static let googleHome = "com.google.android.apps.tv.launcherx"
    private static let suggestedHome = "com.spocky.projengmenu"

    var body: some View {
        Group {
            if client.appsLink != .ready {
                Text("These need the TV's app manager. Open Apps › Manage and connect it first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let tools = client.tvTools {
                content(tools)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { if client.appsLink == .ready { client.refreshTools() } }
        .onChange(of: client.appsLink) { if client.appsLink == .ready { client.refreshTools() } }
    }

    @ViewBuilder private func content(_ tools: TVTools) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Space and memory") {
                if let storage = tools.storage { meter("Storage", storage) }
                if let memory = tools.memory { meter("Memory", memory) }
                HStack(spacing: 8) {
                    Button { client.freeSpace() } label: { Label("Free Up Space", systemImage: "internaldrive") }
                        .help("Clears cached files of every app. Nothing personal is deleted.")
                    Button { confirmFreeMemory = true } label: { Label("Free Memory", systemImage: "memorychip") }
                        .help("Stops apps running in the background, except the one on screen")
                }
            }

            section("Speed and sleep") {
                picker("Animations", "animations", tools, [("normal", "Normal"), ("fast", "Fast"), ("off", "Off")])
                picker("Screensaver after", "screensaver_after", tools,
                       [("5", "5 min"), ("10", "10 min"), ("15", "15 min"), ("30", "30 min")])
                picker("Turn off after", "sleep_after", tools,
                       [("30", "30 min"), ("60", "1 hour"), ("120", "2 hours"), ("240", "4 hours")])
                if !tools.changed.isEmpty {
                    Button("Reset to the TV's Own Settings") { client.resetTweaks() }
                        .buttonStyle(.link)
                }
            }

            section("Install an app") {
                installZone
            }

            section("Home screen") {
                let home = tools.home
                Text("Now: \(home == Self.googleHome ? "Google TV" : home.map(friendlyApp) ?? "unknown")")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if client.installedApps.contains(Self.suggestedHome) {
                        if home != Self.suggestedHome {
                            Button("Use Projectivy") { client.setHome(Self.suggestedHome) }
                        }
                    } else {
                        Button("Get Projectivy on the TV") { client.suggestHome() }
                            .help("An ad free home screen you can arrange. Opens its Play Store page on the TV.")
                    }
                    if home != Self.googleHome {
                        Button("Back to Google TV") { client.setHome(Self.googleHome) }
                    }
                }
            }
        }
        .confirmationDialog("Stop apps running in the background?", isPresented: $confirmFreeMemory) {
            Button("Free Memory") { client.freeMemory() }
        } message: {
            Text("The app on screen keeps running. The others start fresh next time you open them.")
        }
    }

    private var installZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: client.installing ? "hourglass" : "square.and.arrow.down")
                    .font(.title3)
                Text(client.installing ? "Installing on the TV…" : "Drop an app file (.apk) here")
                Spacer()
                Button("Choose File…", action: chooseFile).disabled(client.installing)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else { return false }
                client.install(file)
                return true
            } isTargeted: { dropTargeted = $0 }
            Text("Apps added this way often do not show on the Google TV home screen. Open them from Apps or Recent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Android app file to install on the TV"
        if panel.runModal() == .OK, let file = panel.url { client.install(file) }
    }

    private func picker(_ title: String, _ name: String, _ tools: TVTools, _ options: [(String, String)]) -> some View {
        Picker(title, selection: Binding(
            get: { tools.tweaks[name] ?? "custom" },
            set: { client.setTweak(name, $0) })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            if tools.tweaks[name] == "custom" { Text("TV's own").tag("custom") }
        }
        .frame(maxWidth: 280)
    }

    private func meter(_ title: String, _ amount: TVTools.Amount) -> some View {
        let used = Double(amount.total - amount.free) / Double(max(amount.total, 1))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Self.bytes(amount.free)) free of \(Self.bytes(amount.total))").foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: used).tint(used > 0.85 ? .orange : .accentColor)
        }
        .frame(maxWidth: 340)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
