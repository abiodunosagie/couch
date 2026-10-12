import Foundation

/// Common TV apps and screens by Android package name, from known_apps.json (shared with the
/// helper and the phone page, so all three name apps the same way).
enum KnownApps {
    struct Entry: Decodable {
        let name: String
        /// A web link the app owns, which opens it when the TV's app manager is off.
        var link: String?
        /// A system screen (home, settings, screensaver), not something to pin.
        var screen: Bool?
        var isScreen: Bool { screen == true }
    }

    static let youtube = "com.google.android.youtube.tv"
    static let netflix = "com.netflix.ninja"

    /// Entries keyed by package; keys starting with "_" are comments in the file.
    private struct Table: Decodable {
        let entries: [String: Entry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var entries: [String: Entry] = [:]
            for key in container.allKeys where !key.stringValue.hasPrefix("_") {
                entries[key.stringValue] = try container.decode(Entry.self, forKey: key)
            }
            self.entries = entries
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static let all: [String: Entry] = {
        do {
            guard let url = Bundle.main.url(forResource: "known_apps", withExtension: "json") else {
                NSLog("Couch: known_apps.json is missing from the app bundle")
                return [:]
            }
            return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url)).entries
        } catch {
            NSLog("Couch: could not read known_apps.json: \(error)")
            return [:]
        }
    }()

    /// Known apps with a launch link, for the "Popular apps" menu.
    static var launchable: [String] { all.filter { $0.value.link != nil }.keys.sorted() }
}

/// A readable name for the app on the TV; unknown apps get a name made from the package.
func friendlyApp(_ package: String?) -> String {
    guard let package else { return "nothing yet" }
    if let known = KnownApps.all[package] { return known.name }
    // com.example.someapp.tv -> Someapp
    let filler: Set<Substring> = ["com", "tv", "android", "app", "atv", "google", "androidtv"]
    let parts = package.split(separator: ".").filter { !filler.contains($0) }
    return (parts.last.map(String.init) ?? package).capitalized
}

extension URL {
    /// An http or https link with a host: the only kind the TV opens.
    var isWebLink: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(host ?? "").isEmpty && user == nil && password == nil
    }
}
