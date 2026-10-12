@preconcurrency import AVFoundation
import AppKit

/// Hold to talk: records the Mac microphone and streams it to the TV's voice search.
///
/// The TV wants 16-bit mono PCM at 8 kHz (androidtvremote2 VoiceStream), so input is
/// converted to that before it leaves the app. Audio recorded before the TV says it is
/// listening is held back by RemoteClient and sent once it is, so the first words are not lost.
@MainActor
final class VoiceInput: ObservableObject {
    nonisolated static let sampleRate = 8000.0
    nonisolated static let bytesPerSecond = Int(sampleRate) * MemoryLayout<Int16>.size

    @Published private(set) var recording = false

    private let client: RemoteClient
    private let engine = AVAudioEngine()
    private var sender: Task<Void, Never>?
    private var audio: AsyncStream<Data>.Continuation?
    private var configWatch: NSObjectProtocol?
    nonisolated private static let tvFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    init(client: RemoteClient) {
        self.client = client
        // The server ends a session that runs too long, and the TV can drop; stop the mic then too.
        client.onListeningEnded = { [weak self] in self?.end() }
        // A microphone change (AirPods in or out) stops the engine under us.
        configWatch = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    /// Button pressed: ask for the microphone if needed, open the TV's voice search and record.
    func begin() {
        guard !recording else { return }
        guard client.state.isConnected else {
            client.show("Not connected to the TV yet.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            // The system prompt takes this press; the next press records.
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

    /// Button released (or the session ended): stop and let the TV run the search.
    func end() {
        guard recording else { return }
        recording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audio?.finish()
        audio = nil
        client.endVoice()
    }

    private func startRecording() {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.tvFormat) else {
            client.show("No microphone found.")
            return
        }

        // One consumer keeps the audio in recording order on its way to the TV.
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
        audio = continuation
        let client = self.client
        sender = Task { @MainActor in
            for await pcm in stream { client.sendVoiceAudio(pcm) }
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            if let pcm = Self.convert(buffer, with: converter) { continuation.yield(pcm) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            audio = nil
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
        // Hand the converter this one buffer; it keeps any leftover input for the next call.
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
