import SwiftUI

/// The Automation side of the window: sleep timer, wake time, auto pause and scenes.
struct AutomationView: View {
    @ObservedObject var automations: Automations
    @ObservedObject var scenes: Scenes
    @ObservedObject var favourites: Favourites

    @State private var editing: TVScene?

    static let sleepChoices = [15, 30, 60, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Sleep timer") {
                HStack(spacing: 8) {
                    ForEach(Self.sleepChoices, id: \.self) { minutes in
                        Button("\(minutes) min") { automations.startSleepTimer(minutes: minutes) }
                    }
                    if automations.sleepAt != nil {
                        Button("Cancel") { automations.cancelSleepTimer() }
                    }
                }
                if let end = automations.sleepAt {
                    Text("TV turns off at \(end.formatted(date: .omitted, time: .shortened)) (\(Text(end, style: .relative)) left).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section("Wake up") {
                HStack(spacing: 10) {
                    Toggle("Turn the TV on at", isOn: $automations.wakeEnabled).toggleStyle(.checkbox)
                    DatePicker("", selection: wakeTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!automations.wakeEnabled)
                }
                Picker("Then open", selection: $automations.wakeApp) {
                    Text("Nothing").tag(String?.none)
                    ForEach(favourites.pinned.filter { $0.link != nil }) { app in
                        Text(app.name).tag(Optional(app.package))
                    }
                }
                .disabled(!automations.wakeEnabled)
                .frame(maxWidth: 260)
            }

            section("Auto pause") {
                Toggle("Pause when I lock the Mac", isOn: $automations.pauseOnLock).toggleStyle(.checkbox)
                Toggle("Pause when another app uses the microphone (calls)", isOn: $automations.pauseOnCall)
                    .toggleStyle(.checkbox)
                Toggle("Play again afterwards", isOn: $automations.resumeAfterPause).toggleStyle(.checkbox)
            }

            section("Scenes") {
                ForEach(scenes.scenes) { scene in
                    HStack {
                        Text(scene.name).fontWeight(.medium)
                        Spacer()
                        if scenes.running == scene.id {
                            Button("Stop") { scenes.stop() }
                        } else {
                            Button("Run") { scenes.run(scene) }
                        }
                        Button { editing = scene } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit \(scene.name)")
                    }
                }
                Button { editing = TVScene(name: "New scene", steps: [.turnOn]) } label: {
                    Label("New scene", systemImage: "plus")
                }
            }

            Text("Timers and auto pause work while the Mac is awake.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { scene in
            SceneEditor(scene: scene, favourites: favourites,
                        onSave: { scenes.save($0); editing = nil },
                        onDelete: { scenes.delete($0); editing = nil },
                        onCancel: { editing = nil })
        }
    }

    private var wakeTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: automations.wakeMinute / 60, minute: automations.wakeMinute % 60,
                                         second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                automations.wakeMinute = (parts.hour ?? 7) * 60 + (parts.minute ?? 0)
            })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Edit a scene's name and steps.
private struct SceneEditor: View {
    @State var scene: TVScene
    let favourites: Favourites
    let onSave: (TVScene) -> Void
    let onDelete: (TVScene) -> Void
    let onCancel: () -> Void

    private static let waits = [1, 2, 3, 5, 10, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Scene name", text: $scene.name).textFieldStyle(.roundedBorder)

            List {
                ForEach(Array(scene.steps.enumerated()), id: \.offset) { index, step in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(step.label)
                        Spacer()
                        Button { scene.steps.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this step")
                    }
                }
                .onMove { scene.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 180)

            Menu {
                Button("Turn the TV on") { scene.steps.append(.turnOn) }
                Button("Turn the TV off") { scene.steps.append(.turnOff) }
                Menu("Open app") {
                    ForEach(favourites.pinned) { app in
                        Button(app.name) { scene.steps.append(.openApp(package: app.package)) }
                    }
                }
                Menu("Press a button") {
                    ForEach(RemoteKey.allCases, id: \.self) { key in
                        Button(key.title) { scene.steps.append(.press(key)) }
                    }
                }
                Menu("Wait") {
                    ForEach(Self.waits, id: \.self) { seconds in
                        Button("\(seconds) seconds") { scene.steps.append(.wait(seconds: seconds)) }
                    }
                }
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .fixedSize()

            HStack {
                Button("Delete Scene", role: .destructive) { onDelete(scene) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(scene) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scene.name.trimmingCharacters(in: .whitespaces).isEmpty || scene.steps.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
