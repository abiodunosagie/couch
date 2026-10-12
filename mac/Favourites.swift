import Combine
import Foundation

/// An app on the TV that the user pinned, with the name they gave it.
/// The TV only starts apps from web links they own, so each favourite carries one.
struct FavouriteApp: Codable, Equatable, Identifiable {
    var package: String
    var name: String
    var link: String?
    var id: String { package }
}

/// Apps Couch has seen on the TV, and the ones the user pinned for one click launch.
///
/// The TV has no "list installed apps" request, so Couch learns apps as they come to the
/// front. Stored in UserDefaults; package names only, nothing about what was watched.
@MainActor
final class Favourites: ObservableObject {
    @Published private(set) var pinned: [FavouriteApp] = []
    @Published private(set) var seen: [String] = []

    private var watch: AnyCancellable?
    private static let pinnedKey = "favouriteApps"
    private static let seenKey = "seenApps"
    private static let maxSeen = 60
    /// Web links known to open these apps on Google TV. Others need a link from the user.
    static let knownLinks: [String: String] = [
        "com.google.android.youtube.tv": "https://www.youtube.com",
        "com.google.android.youtube.tvkids": "https://www.youtubekids.com",
        "com.netflix.ninja": "https://www.netflix.com/title",
        "com.amazon.amazonvideo.livingroom": "https://app.primevideo.com",
        "com.disney.disneyplus": "https://www.disneyplus.com",
        "com.apple.atve.androidtv.appletv": "https://tv.apple.com",
        "com.spotify.tv.android": "https://open.spotify.com",
        "com.wbd.stream": "https://play.max.com",
    ]

    /// Screens rather than apps: the home screen, settings, voice search, the screensaver.
    private static let notApps: Set<String> = [
        "com.google.android.apps.tv.launcherx", "com.google.android.tvlauncher",
        "com.android.tv.settings", "com.google.android.katniss", "com.neilturner.aerialviews",
    ]

    init(client: RemoteClient) {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.pinnedKey),
           let saved = try? JSONDecoder().decode([FavouriteApp].self, from: data) {
            pinned = saved
        } else {
            pinned = [FavouriteApp(package: "com.google.android.youtube.tv", name: "YouTube",
                                   link: Self.knownLinks["com.google.android.youtube.tv"])]
        }
        seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        watch = client.$state.map(\.app).removeDuplicates().sink { [weak self] app in
            guard let app else { return }
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    func isPinned(_ package: String) -> Bool { pinned.contains { $0.package == package } }

    func pin(_ package: String) {
        guard !isPinned(package) else { return }
        pinned.append(FavouriteApp(package: package, name: defaultName(for: package), link: Self.knownLinks[package]))
        save()
    }

    func unpin(_ package: String) {
        pinned.removeAll { $0.package == package }
        save()
    }

    /// Change a favourite's name and launch link. Returns false if the link is not a web link.
    @discardableResult
    func update(_ package: String, name: String, link: String) -> Bool {
        guard let index = pinned.firstIndex(where: { $0.package == package }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pinned[index].name = String(trimmed.prefix(24)) }
        let linkText = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if linkText.isEmpty {
            pinned[index].link = nil
        } else if let url = URL(string: linkText), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            pinned[index].link = linkText
        } else {
            save()
            return false
        }
        save()
        return true
    }

    /// Seen apps not pinned yet, most recent first.
    var unpinnedSeen: [String] { seen.filter { !isPinned($0) } }

    func defaultName(for package: String) -> String {
        let known = friendlyApp(package)
        if known != package { return known }
        // com.example.someapp.tv -> Someapp
        let parts = package.split(separator: ".").filter { !["com", "tv", "android", "app", "atv", "google"].contains($0) }
        return (parts.last.map(String.init) ?? package).capitalized
    }

    private func record(_ package: String) {
        guard !Self.notApps.contains(package) else { return }
        seen.removeAll { $0 == package }
        seen.insert(package, at: 0)
        if seen.count > Self.maxSeen { seen.removeLast(seen.count - Self.maxSeen) }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pinned) {
            UserDefaults.standard.set(data, forKey: Self.pinnedKey)
        }
    }
}
