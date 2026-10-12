import SwiftUI

/// Text field that types into whatever field is focused on the TV.
struct TypeField: View {
    let client: RemoteClient
    /// Changing this value focuses the field.
    var focusRequest = 0
    /// Focus the field as soon as it appears (the menu bar panel shows it on demand).
    var focusOnAppear = false
    /// Called after sending or pressing Esc, so the menu bar panel can hide the field again.
    var onDone: () -> Void = {}

    static let maxLength = 200  // MAX_TEXT_LENGTH in server.py

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type on the TV", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand {
                    focused = false
                    onDone()
                }
            Button("Send", action: send)
                .disabled(text.isEmpty)
        }
        .onChange(of: focusRequest) { focused = true }
        .onAppear { if focusOnAppear { focused = true } }
    }

    private func send() {
        guard !text.isEmpty else { return }
        client.type(String(text.prefix(Self.maxLength)))
        text = ""
        onDone()
    }
}

struct PairingForm: View {
    @ObservedObject var client: RemoteClient
    @State private var code = ""
    @FocusState private var focused: Bool

    private var isPairing: Bool { client.state.status == .pairing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair with your TV").font(.headline)
            Text(isPairing ? "Enter the 6 character code showing on the TV." : "Couch needs a one time code from the TV.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if isPairing {
                HStack(spacing: 8) {
                    TextField("A1B2C3", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .focused($focused)
                        .onSubmit(submit)
                        .onChange(of: code) { code = String(code.uppercased().prefix(6)) }
                    Button("Pair", action: submit).keyboardShortcut(.defaultAction)
                }
                Button("Show a new code") { client.startPairing() }
                    .buttonStyle(.link)
            } else {
                Button("Show a code on the TV") { client.startPairing() }
            }
        }
        // The code field only exists once pairing starts, so focus it then.
        .onChange(of: client.state.status) { if isPairing { focused = true } }
        .onAppear { if isPairing { focused = true } }
        // A rejected code gets a new notice; clear the old code so the new one goes in clean.
        .onChange(of: client.state.noticeId) { code = "" }
    }

    private func submit() {
        client.submitPairing(code.trimmingCharacters(in: .whitespaces))
    }
}

struct StatusLine: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: RemoteClient

    init(model: AppModel) {
        self.model = model
        self.client = model.client
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(model.statusText.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        if client.state.isConnected { return .green }
        if client.state.status == .offline || model.startFailed { return .red }
        return .orange
    }
}

struct FinishPicker: View {
    @Binding var finish: Finish

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Finish.allCases) { option in
                Button { finish = option } label: {
                    Circle()
                        .fill(option.body)
                        .overlay(Circle().strokeBorder(option.edge, lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: finish == option ? 2 : 0).padding(-3))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel("\(option.label) finish")
            }
        }
    }
}
