import Foundation

/// What Couch knows about common TV apps and screens, by Android package name.
enum KnownApps {
    struct Entry {
        let name: String
        /// A web link the app owns, which opens it on Google TV. The TV refuses package launches.
        var link: String?
        /// A system screen (home, settings, screensaver), not something to pin.
        var isScreen = false
    }

    static let all: [String: Entry] = [
        "com.google.android.youtube.tv": Entry(name: "YouTube", link: "https://www.youtube.com"),
        "com.google.android.youtube.tvkids": Entry(name: "YouTube Kids", link: "https://www.youtubekids.com"),
        "com.netflix.ninja": Entry(name: "Netflix", link: "https://www.netflix.com/title"),
        "com.amazon.amazonvideo.livingroom": Entry(name: "Prime Video", link: "https://app.primevideo.com"),
        "com.disney.disneyplus": Entry(name: "Disney+", link: "https://www.disneyplus.com"),
        "com.apple.atve.androidtv.appletv": Entry(name: "Apple TV", link: "https://tv.apple.com"),
        "com.spotify.tv.android": Entry(name: "Spotify", link: "https://open.spotify.com"),
        "com.wbd.stream": Entry(name: "Max", link: "https://play.max.com"),
        "com.google.android.apps.tv.launcherx": Entry(name: "Home screen", isScreen: true),
        "com.google.android.tvlauncher": Entry(name: "Home screen", isScreen: true),
        "com.android.tv.settings": Entry(name: "Settings", isScreen: true),
        "com.google.android.katniss": Entry(name: "Voice search", isScreen: true),
        "com.neilturner.aerialviews": Entry(name: "Screensaver", isScreen: true),
    ]

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
