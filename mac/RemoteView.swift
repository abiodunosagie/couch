import SwiftUI

/// Body colours of the real remote: Snow, Sunrise and Sky.
enum Finish: String, CaseIterable, Identifiable {
    case snow, sunrise, sky

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var body: Color {
        switch self {
        case .snow: Color(red: 0.957, green: 0.953, blue: 0.941)
        case .sunrise: Color(red: 0.945, green: 0.855, blue: 0.835)
        case .sky: Color(red: 0.843, green: 0.882, blue: 0.929)
        }
    }

    var face: Color { body.mix(with: .white, by: 0.45) }
    var edge: Color { body.mix(with: .black, by: 0.16) }
}

let remoteInk = Color(red: 0.16, green: 0.16, blue: 0.16)

/// The remote itself, drawn after the Chromecast with Google TV voice remote.
struct RemoteView: View {
    static let size = CGSize(width: 226, height: 650)
    /// Dimmed while not connected, so it is clear presses will not reach the TV.
    private static let disconnectedOpacity = 0.72

    @ObservedObject var client: RemoteClient
    var voice: VoiceInput
    var finish: Finish

    var body: some View {
        VStack(spacing: 0) {
            DPad(finish: finish, press: client.press)
                .padding(.top, 16)

            Grid(horizontalSpacing: 30, verticalSpacing: 16) {
                GridRow {
                    RoundKey(finish: finish, help: "Back (Esc)") { client.press(.back) } label: {
                        Image(systemName: "arrow.backward").font(.system(size: 18, weight: .semibold))
                    }
                    VoiceKey(voice: voice, client: client)
                }
                GridRow {
                    RoundKey(finish: finish, help: "Home (H)") { client.press(.home) } label: {
                        Image(systemName: "house.fill").font(.system(size: 16))
                    }
                    RoundKey(finish: finish, help: "Mute (M)") { client.press(.mute) } label: {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 16))
                    }
                }
                GridRow {
                    RoundKey(finish: finish, help: "YouTube") { client.launch("youtube") } label: {
                        Text("YouTube").font(.system(size: 13, weight: .heavy)).fontWidth(.compressed).tracking(-0.2)
                    }
                    RoundKey(finish: finish, help: "Netflix") { client.launch("netflix") } label: {
                        Text("NETFLIX").font(.system(size: 12, weight: .heavy)).fontWidth(.compressed).tracking(0.4)
                    }
                }
            }
            .padding(.top, 22)

            Tray(finish: finish, client: client)
                .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [finish.face, finish.body], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Capsule(style: .continuous).strokeBorder(finish.edge.opacity(0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 18)
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        )
        .overlay(alignment: .topTrailing) {
            // On the real remote the volume rocker sits on the right edge, level with the bottom of the pad.
            VolumeRocker(finish: finish, press: client.press)
                .offset(x: 7, y: 150)
        }
        .opacity(client.state.isConnected ? 1 : Self.disconnectedOpacity)
        .animation(.easeOut(duration: 0.2), value: client.state.isConnected)
    }
}

// MARK: - Buttons

private struct PressStyle: ButtonStyle {
    var finish: Finish
    var dark: Bool
    var size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(dark ? Color.white : remoteInk)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(dark ? Color(white: configuration.isPressed ? 0.22 : 0.1)
                               : (configuration.isPressed ? finish.edge.opacity(0.35) : finish.face))
                    .overlay(Circle().strokeBorder(dark ? Color.black : finish.edge, lineWidth: 1))
                    .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.08), radius: 1.5, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

private struct RoundKey<Label: View>: View {
    var finish: Finish
    var dark = false
    var size: CGFloat = 62
    var help: String
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(PressStyle(finish: finish, dark: dark, size: size))
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The black Assistant key: hold it and speak, release to search, like on the real remote.
private struct VoiceKey: View {
    @ObservedObject var voice: VoiceInput
    @ObservedObject var client: RemoteClient
    @State private var held = false

    private var live: Bool { voice.recording && client.listening }

    var body: some View {
        Image(systemName: live ? "waveform" : "mic.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(
                Circle()
                    .fill(live ? Color(red: 0.86, green: 0.27, blue: 0.22) : Color(white: held ? 0.22 : 0.1))
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1))
            )
            .scaleEffect(held ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: held)
            .animation(.easeOut(duration: 0.12), value: live)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        voice.begin()
                    }
                    .onEnded { _ in
                        held = false
                        voice.end()
                    }
            )
            .onDisappear {
                held = false
                voice.end()
            }
            .help("Hold and speak to search the TV")
            .accessibilityLabel("Voice search, hold and speak")
            .accessibilityAddTraits(.isButton)
    }
}

/// Power, the microphone slot and Input, set in a shallow tray like on the real remote.
private struct Tray: View {
    var finish: Finish
    @ObservedObject var client: RemoteClient

    var body: some View {
        HStack(spacing: 0) {
            RoundKey(finish: finish, size: 36, help: "Power (P)") { client.press(.power) } label: {
                Image(systemName: "power").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Capsule()
                .fill(statusColor)
                .frame(width: 12, height: 5)
                .help(client.state.isConnected ? "Connected" : "Not connected")
            Spacer()
            RoundKey(finish: finish, size: 36, help: "TV input") { client.press(.input) } label: {
                Image(systemName: "arrow.right.to.line.square").font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 150, height: 50)
        .background(
            Capsule(style: .continuous)
                .fill(finish.body.mix(with: .black, by: 0.04))
                .overlay(Capsule(style: .continuous).strokeBorder(finish.edge.opacity(0.4), lineWidth: 0.75))
        )
    }

    /// The microphone slot doubles as the connection light.
    private var statusColor: Color {
        switch client.state.status {
        case .connected: Color(red: 0.25, green: 0.6, blue: 0.38)
        case .reconnecting, .pairing, .searching: Color(red: 0.85, green: 0.6, blue: 0.15)
        case .offline, .unpaired, .unknown: remoteInk.opacity(0.7)
        }
    }
}

private struct VolumeRocker: View {
    var finish: Finish
    var press: (RemoteKey) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Half(symbol: "plus", key: .volumeUp, finish: finish, press: press)
            Rectangle().fill(finish.edge.opacity(0.5)).frame(width: 8, height: 0.75)
            Half(symbol: "minus", key: .volumeDown, finish: finish, press: press)
        }
        .frame(width: 16)
        .background(
            Capsule(style: .continuous)
                .fill(finish.body.mix(with: .black, by: 0.03))
                .overlay(Capsule(style: .continuous).strokeBorder(finish.edge.opacity(0.7), lineWidth: 0.75))
        )
        .help("Volume (+ and -)")
    }

    private struct Half: View {
        var symbol: String
        var key: RemoteKey
        var finish: Finish
        var press: (RemoteKey) -> Void
        @StateObject private var repeater = Repeater()

        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(remoteInk.opacity(0.7))
                .frame(width: 16, height: 40)
                .background(repeater.running ? finish.edge.opacity(0.35) : .clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !repeater.running else { return }
                            repeater.start { press(key) }
                        }
                        .onEnded { _ in repeater.stop() }
                )
                .onDisappear { repeater.stop() }
                .accessibilityLabel(key == .volumeUp ? "Volume up" : "Volume down")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { press(key) }
        }
    }
}
