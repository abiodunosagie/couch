import CoreImage.CIFilterBuiltins
import SwiftUI

/// Phone tab: turn on the phone remote and show the QR code that pairs a phone.
struct PhoneView: View {
    @ObservedObject var client: RemoteClient
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Use Couch from my phone", isOn: Binding(
                get: { client.phone?.enabled ?? false },
                set: { client.setPhone(enabled: $0) }))
                .toggleStyle(.switch)

            if let phone = client.phone, phone.enabled {
                if let url = phone.url, let image = Self.qrCode(for: url) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                            .accessibilityLabel("QR code that pairs a phone")
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Point the phone camera at the code and open the link.")
                            step(2, "Tap Share, then Add to Home Screen.")
                            step(3, "Open Couch from the home screen any time.")
                        }
                        .font(.callout)
                    }
                    Text("The phone must be on the same Wi-Fi, and this Mac awake with Couch running. If macOS asks whether to accept incoming connections, choose Allow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !phone.running {
                    Text("The phone remote could not start. Another app may be using port 8766.")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text("This Mac has no Wi-Fi address right now.").font(.callout).foregroundStyle(.orange)
                }

                Button("Forget Paired Phones") { confirmReset = true }
                    .confirmationDialog("Forget every paired phone?", isPresented: $confirmReset) {
                        Button("Forget Phones", role: .destructive) { client.resetPhonePairing() }
                    } message: {
                        Text("Phones need to scan a new code to use Couch again.")
                    }
            } else {
                Text("Turn this on to get the same remote on your phone, with typing and YouTube search. Voice stays on the Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { client.refreshPhone() }
        .onChange(of: client.linkUp) { if client.linkUp { client.refreshPhone() } }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.secondary).monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
