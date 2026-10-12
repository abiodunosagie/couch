import Foundation

/// Starts Couch at login through a user LaunchAgent, so it can pass `--background`
/// (menu bar only, no window), which a plain login item cannot.
enum LoginItem {
    static let label = "com.abiodun.couch"
    static let backgroundArgument = "--background"

    enum Failure: Error { case noExecutable }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
            return
        }
        guard let executable = Bundle.main.executablePath else { throw Failure.noExecutable }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, backgroundArgument],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }
}
