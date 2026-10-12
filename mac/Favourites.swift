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
    private static let maxLinkLength = 2000  // MAX_LINK_LENGTH in server.py
    init(client: RemoteClient) {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.pinnedKey),
           let saved = try? JSONDecoder().decode([FavouriteApp].self, from: data) {
            pinned = saved
        } else {
            pinned = [FavouriteApp(package: KnownApps.youtube, name: friendlyApp(KnownApps.youtube),
                                   link: KnownApps.all[KnownApps.youtube]?.link)]
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
        pinned.append(FavouriteApp(package: package, name: defaultName(for: package), link: KnownApps.all[package]?.link))
        save()
    }

    func unpin(_ package: String) {
        pinned.removeAll { $0.package == package }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Forget an app Couch saw, for apps that were uninstalled.
    func forget(_ package: String) {
        seen.removeAll { $0 == package }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
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
        } else if linkText.count <= Self.maxLinkLength, URL(string: linkText)?.isWebLink == true {
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

    func defaultName(for package: String) -> String { friendlyApp(package) }

    /// The launch link for an app: the user's own, else the known one.
    func link(for package: String?) -> String? {
        guard let package else { return nil }
        return pinned.first { $0.package == package }?.link ?? KnownApps.all[package]?.link
    }

    private func record(_ package: String) {
        guard KnownApps.all[package]?.isScreen != true else { return }
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
