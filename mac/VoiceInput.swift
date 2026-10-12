@preconcurrency import AVFoundation
import AppKit

/// Hold to talk: records the Mac microphone and streams it to the TV's voice search.
///
/// The TV wants 16-bit mono PCM at 8 kHz (androidtvremote2 VoiceStream), so input is
/// converted to that before it leaves the app. Audio recorded before the TV says it is
/// listening is held back and sent once it is, so the first words are not lost.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var recording = false

    private let client: RemoteClient
    private let engine = AVAudioEngine()
    nonisolated private static let tvFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    init(client: RemoteClient) {
        self.client = client
    }

    /// Button pressed: ask for the microphone if needed, open the TV's voice search and record.
    func begin() {
        guard !recording, client.state.isConnected else {
            if !client.state.isConnected { client.show("Not connected to the TV yet.") }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            // The system prompt takes the press; the next press records.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.client.show(granted ? "Microphone ready. Hold the button and speak." : "Couch needs the microphone for voice.")
                }
            }
        default:
            client.show("Allow the microphone for Couch in System Settings, Privacy and Security.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    /// Button released: stop and let the TV run the search.
    func end() {
        guard recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false
        client.endVoice()
    }

    private func startRecording() {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.tvFormat) else {
            client.show("No microphone found.")
            return
        }
        let client = self.client
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            guard let pcm = Self.convert(buffer, with: converter) else { return }
            Task { @MainActor in client.sendVoiceAudio(pcm) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            client.show("Could not start the microphone.")
            return
        }
        recording = true
        client.startVoice()
    }

    /// Resample one microphone buffer to the TV format. Runs on the audio thread.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let ratio = tvFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: tvFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
