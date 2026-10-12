import Foundation

/// One step of a scene.
enum SceneStep: Codable, Equatable, Hashable {
    case turnOn
    case turnOff
    case press(RemoteKey)
    case openApp(package: String)
    case wait(seconds: Int)

    var label: String {
        switch self {
        case .turnOn: "Turn the TV on"
        case .turnOff: "Turn the TV off"
        case .press(let key): "Press \(key.title)"
        case .openApp(let package): "Open \(friendlyApp(package))"
        case .wait(let seconds): "Wait \(seconds) seconds"
        }
    }
}

/// A named list of steps that runs with one click, like "Movie night".
struct TVScene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var steps: [SceneStep]
}

@MainActor
final class Scenes: ObservableObject {
    @Published private(set) var scenes: [TVScene] = []
    @Published private(set) var running: UUID?

    private let client: RemoteClient
    private let automations: Automations
    private let favourites: Favourites
    private var task: Task<Void, Never>?
    private static let key = "scenes"
    /// Gap between steps so the TV keeps up.
    private static let stepGap: UInt64 = 400_000_000
    static let maxWaitSeconds = 60

    init(client: RemoteClient, automations: Automations, favourites: Favourites) {
        self.client = client
        self.automations = automations
        self.favourites = favourites
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([TVScene].self, from: data) {
            scenes = saved
        } else {
            scenes = [
                TVScene(name: "Movie night", steps: [.turnOn, .wait(seconds: 4), .openApp(package: "com.netflix.ninja")]),
                TVScene(name: "Good night", steps: [.press(.pause), .wait(seconds: 1), .turnOff]),
            ]
        }
    }

    func run(_ scene: TVScene) {
        guard client.state.isConnected else {
            client.show("Not connected to the TV yet.")
            return
        }
        task?.cancel()
        running = scene.id
        task = Task { [weak self] in
            guard let self else { return }
            for step in scene.steps {
                if Task.isCancelled { break }
                await self.perform(step)
                try? await Task.sleep(nanoseconds: Self.stepGap)
            }
            if self.running == scene.id { self.running = nil }
        }
    }

    func stop() {
        task?.cancel()
        running = nil
    }

    func save(_ scene: TVScene) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        persist()
    }

    func delete(_ scene: TVScene) {
        scenes.removeAll { $0.id == scene.id }
        persist()
    }

    private func perform(_ step: SceneStep) async {
        switch step {
        case .turnOn: automations.turnOn()
        case .turnOff: automations.turnOff()
        case .press(let key): client.press(key)
        case .openApp(let package):
            let link = favourites.pinned.first { $0.package == package }?.link ?? Favourites.knownLinks[package]
            if let link { client.open(link) } else { client.show("No link for \(friendlyApp(package)); add one in Apps.") }
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), Self.maxWaitSeconds)) * 1_000_000_000)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(scenes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
