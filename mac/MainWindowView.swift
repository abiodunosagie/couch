import SwiftUI

/// The Couch window: the remote on the left, TV status and settings on the right.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: RemoteClient

    init(model: AppModel) {
        self.model = model
        self.client = model.client
    }

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            RemoteView(client: client, voice: model.voice, finish: model.finish)
                .padding(.vertical, 36)

            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusLine(model: model)
                    Text(client.state.tv ?? "Couch")
                        .font(.system(size: 40, weight: .bold))
                        .tracking(-0.8)
                    Text("Now on \(Text(friendlyApp(client.state.app)).foregroundStyle(.primary).fontWeight(.semibold))")
                        .foregroundStyle(.secondary)
                }

                if client.state.needsPairing {
                    PairingForm(client: client)
                } else if model.typing {
                    TypingPanel(model: model)
                } else {
                    Button { model.typing = true } label: { Label("Type on the TV", systemImage: "keyboard") }
                        .help("Type with your keyboard (/)")
                }

                Text(client.toast ?? " ")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .animation(.easeOut(duration: 0.15), value: client.toast)

                Shortcuts()
                if !model.unavailableShortcuts.isEmpty {
                    Text("Taken by another app: \(model.unavailableShortcuts.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                HStack(spacing: 18) {
                    FinishPicker(finish: $model.finish)
                    Toggle("Open at login", isOn: $model.launchAtLogin)
                        .toggleStyle(.checkbox)
                }
                .font(.callout)
            }
            .frame(width: 340, alignment: .leading)
        }
        .padding(.horizontal, 48)
        .frame(minWidth: 760, minHeight: 720)
    }
}

private struct Shortcuts: View {
    private let items = [
        ("arrows", "move"), ("return", "select"), ("esc", "back"),
        ("h", "home"), ("space", "play / pause"), ("+ -", "volume"),
        ("m", "mute"), ("p", "power"), ("/", "type text"),
    ]
    private let columns = 3
    private static let global = [
        ("⌥⌘R", "open the remote"), ("⌃⌥Space", "play / pause"), ("⌃⌥↑ ⌃⌥↓", "volume"),
        ("⌃⌥M", "mute"), ("⌃⌥P", "power"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(0..<(items.count / columns), id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let item = items[row * columns + column]
                            HStack(spacing: 6) {
                                Text(item.0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                                Text(item.1).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("From any app")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Self.global, id: \.0) { keys, action in
                    GridRow {
                        Text(keys).font(.system(size: 12, design: .monospaced))
                        Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
