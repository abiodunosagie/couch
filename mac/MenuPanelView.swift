import SwiftUI

/// Contents of the menu bar panel: a compact header, the remote and an on demand type field.
struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: RemoteClient
    var openWindow: () -> Void
    var quit: () -> Void

    init(model: AppModel, openWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.client = model.client
        self.openWindow = openWindow
        self.quit = quit
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    StatusLine(model: model)
                    Text(client.state.tv ?? "Couch").font(.system(size: 17, weight: .bold))
                    Text(friendlyApp(client.state.app)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.typing.toggle() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.borderless)
                    .help("Type on the TV (/)")
                Menu {
                    Button("Open Couch Window", action: openWindow)
                    Picker("Finish", selection: $model.finish) {
                        ForEach(Finish.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Open at Login", isOn: $model.launchAtLogin)
                    Divider()
                    Button("Quit Couch", action: quit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if client.state.needsPairing {
                PairingForm(client: client)
            } else {
                if model.typing {
                    TypingPanel(model: model, compact: true)
                }
                RemoteView(client: client, finish: model.finish) { model.typing = true }
                    .scaleEffect(model.panelScale)
                    .frame(width: RemoteView.size.width * model.panelScale,
                           height: RemoteView.size.height * model.panelScale)
            }

            if let toast = client.toast {
                Text(toast).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
