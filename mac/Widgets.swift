import SwiftUI

/// Typing mode: the Mac keyboard types straight into the TV text box, and this shows what
/// the box on the TV says (the TV sends its text back after each edit).
struct TypingPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: RemoteClient
    let compact: Bool

    init(model: AppModel, compact: Bool = false) {
        self.model = model
        self.client = model.client
        self.compact = compact
    }

    private var field: TVTextField? { client.state.field }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("Typing on the TV").font(.headline)
                Spacer()
                Button("Done") { model.typing = false }
                    .keyboardShortcut(.cancelAction)
            }

            mirror

            HStack(spacing: 8) {
                Button { model.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                Button { client.edit(.deleteBackward) } label: { Label("Delete", systemImage: "delete.left") }
                Button { client.clearField() } label: { Label("Clear", systemImage: "xmark.circle") }
                    .disabled(field?.value.isEmpty ?? true)
                Spacer()
                Button { model.hideFieldText.toggle() } label: {
                    Image(systemName: model.hideFieldText ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(model.hideFieldText ? "Show the text" : "Hide the text, for passwords")
            }
            .controlSize(compact ? .small : .regular)

            Text("Type, delete and paste (Command V) with your keyboard. Esc stops typing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 12 : 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    /// The TV text box, as the TV last reported it.
    @ViewBuilder private var mirror: some View {
        Group {
            if let field, field.active {
                (Text(model.hideFieldText ? String(repeating: "•", count: field.value.count) : field.value)
                    + Text("|").foregroundStyle(Color.accentColor))
                    .font(.system(size: compact ? 14 : 17, weight: .medium, design: .rounded))
                    .lineLimit(3)
                    .truncationMode(.head)
            } else {
                Text("Select a text box on the TV, then type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 40, alignment: .leading)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .accessibilityLabel(field?.active == true
                            ? (model.hideFieldText ? "TV text box, hidden" : "TV text box: \(field?.value ?? "")")
                            : "No text box selected on the TV")
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
                .focusable(false)
                .help(option.label)
                .accessibilityLabel("\(option.label) finish")
            }
        }
    }
}
