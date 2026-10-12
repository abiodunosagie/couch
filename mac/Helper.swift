import Foundation

/// Starts and stops the Python helper that speaks the TV protocol.
///
/// The helper listens on 127.0.0.1 only and gets a random token for this launch,
/// which it requires on every request. It is also told our pid, and exits by
/// itself if this app dies without cleaning up.
@MainActor
final class Helper {
    /// Must match DEFAULT_PORT in tv.py.
    nonisolated static let port = 8765
    nonisolated static let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    nonisolated static let tokenHeader = "X-Couch-Token"

    /// A cold start can include `uv` installing packages, so allow a full minute.
    private static let startTimeout: TimeInterval = 60
    private static let pollInterval: UInt64 = 250_000_000
    private static let maxLogBytes: UInt64 = 5_000_000

    let token = UUID().uuidString + UUID().uuidString
    private let projectPath: String
    private let uvPath: String
    private var process: Process?
    private var log: FileHandle?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        projectPath = info["CouchProjectPath"] as? String ?? ""
        uvPath = info["CouchUVPath"] as? String ?? "/usr/local/bin/uv"
    }

    /// Make sure our helper answers on the port, starting one if needed.
    func ensureRunning() async -> Bool {
        if await isHealthy() { return true }
        if process?.isRunning != true {
            do {
                try spawn()
            } catch {
                NSLog("Couch: could not start helper: \(error.localizedDescription)")
                return false
            }
        }
        let deadline = Date().addingTimeInterval(Self.startTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            if await isHealthy() { return true }
            if process?.isRunning == false { return false }
        }
        return false
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        try? log?.close()
        log = nil
    }

    /// Only our own helper knows the token, so a stale or foreign server on the port fails this.
    private func isHealthy() async -> Bool {
        var request = URLRequest(url: Helper.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        request.setValue(token, forHTTPHeaderField: Helper.tokenHeader)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func spawn() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.arguments = [
            "run", "--quiet", "--project", projectPath,
            "python", "tvremote.py", "serve",
            "--port", String(Helper.port),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["COUCH_TOKEN"] = token
        process.environment = environment
        try? log?.close()
        let log = try Helper.openLog()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        self.process = process
        self.log = log
    }

    /// Owner-only log file, started fresh once it grows past a few megabytes.
    private static func openLog() throws -> FileHandle {
        let manager = FileManager.default
        let dir = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Couch.log")
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if !manager.fileExists(atPath: url.path) || size > maxLogBytes {
            manager.createFile(atPath: url.path, contents: nil)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        return handle
    }
}
