import SwiftUI

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
