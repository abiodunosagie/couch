import AppKit

/// One step of a scene.
enum SceneStep: Codable, Equatable, Hashable {
    case turnOn
    case turnOff
    case press(RemoteKey)
    case openApp(package: String)
    case wait(seconds: Int)
    /// Hands the air conditioner part to the Breeze app through a breeze:// link; Breeze asks first.
    case airConditioner(AirStep)

    var label: String {
        switch self {
        case .turnOn: "Turn the TV on"
        case .turnOff: "Turn the TV off"
        case .press(let key): "Press \(key.title)"
        case .openApp(let package): "Open \(friendlyApp(package))"
        case .wait(let seconds): "Wait \(seconds) seconds"
        case .airConditioner(let step): step.label
        }
    }
}

/// What a scene can ask Breeze for. Couch never talks to the air conditioner itself.
enum AirStep: Codable, Equatable, Hashable {
    case on
    case off
    case cool(degrees: Int)

    static let degrees = Array(18...28)

    var label: String {
        switch self {
        case .on: "Switch the AC on (Breeze)"
        case .off: "Switch the AC off (Breeze)"
        case .cool(let degrees): "Cool to \(degrees)° (Breeze)"
        }
    }

    var url: URL? {
        switch self {
        case .on: URL(string: "breeze://on")
        case .off: URL(string: "breeze://off")
        case .cool(let degrees): URL(string: "breeze://set?target=\(degrees)&mode=cool")
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
    private var currentRun: UUID?
    private static let key = "scenes"
    private static let unreadableKey = "scenes.unreadable"
    /// Gap between steps so the TV keeps up.
    private static let stepGap: UInt64 = 400_000_000
    static let maxWaitSeconds = 60

    init(client: RemoteClient, automations: Automations, favourites: Favourites) {
        self.client = client
        self.automations = automations
        self.favourites = favourites
        let data = UserDefaults.standard.data(forKey: Self.key)
        if let data, let saved = try? JSONDecoder().decode([TVScene].self, from: data) {
            scenes = saved
        } else {
            // Saved by a build that knows a step this one does not: keep a copy before the
            // defaults below are saved over it, so going back to that build loses nothing.
            if let data { UserDefaults.standard.set(data, forKey: Self.unreadableKey) }
            scenes = [
                TVScene(name: "Movie night", steps: [.turnOn, .wait(seconds: 4), .openApp(package: KnownApps.netflix)]),
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
        // A fresh id per run, so a cancelled earlier run of the same scene cannot clear this one.
        let run = UUID()
        currentRun = run
        task = Task { [weak self] in
            guard let self else { return }
            for step in scene.steps {
                if Task.isCancelled { break }
                await self.perform(step)
                try? await Task.sleep(nanoseconds: Self.stepGap)
            }
            if self.currentRun == run { self.running = nil }
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
        case .turnOn: if automations.turnOn() { await automations.waitForPower(on: true) }
        case .turnOff: if automations.turnOff() { await automations.waitForPower(on: false) }
        case .press(let key): client.press(key)
        case .openApp(let package):
            if let link = favourites.link(for: package) {
                client.open(link)
            } else {
                client.show("No link for \(friendlyApp(package)); add one in Apps.")
            }
        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), Self.maxWaitSeconds)) * 1_000_000_000)
        case .airConditioner(let step):
            // Breeze shows the request in its panel; nothing changes until the user confirms there.
            guard let url = step.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                client.show("Breeze is not installed, so the air conditioner step was skipped.")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(scenes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
