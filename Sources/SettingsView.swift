import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// The Settings window with Shortcuts, Cycles and General tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CyclesTab().tabItem { Label("Cycles", systemImage: "arrow.triangle.2.circlepath") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 470)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Lists a recorder field for every action.
private struct ShortcutsTab: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(Action.allCases) { ShortcutRecorder(action: $0) }
            } footer: {
                HStack {
                    Text("Click a field and press a key combination. Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { prefs.resetShortcuts() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Records a key combination for one action and flags system or duplicate conflicts.
private struct ShortcutRecorder: View {
    let action: Action
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var prefs = Preferences.shared
    @State private var recording = false
    @State private var monitor: Any?

    private var warning: String? {
        guard let shortcut = prefs.shortcuts[action] else { return nil }
        if let other = Action.allCases.first(where: { $0 != action && prefs.shortcuts[$0]?.sameKeys(as: shortcut) == true }) {
            return "Also assigned to \(other.title)."
        }
        return shortcut.conflictWarning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recording ? "Press keys…" : (prefs.shortcuts[action]?.display ?? "None")) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 110)
                Button { prefs.shortcuts[action] = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Clear shortcut")
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        appState.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = Self.carbonModifiers(event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape) && mods == 0 {
                stop()
                return nil
            }
            guard mods != 0 else { NSSound.beep(); return nil }
            let label = Shortcut.label(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            prefs.shortcuts[action] = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: label)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { appState.isRecording = false }
        recording = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}

/// Edits the ordered list of fractions each direction cycles through.
private struct CyclesTab: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            ForEach(Direction.allCases) { direction in
                Section(direction.name) {
                    let steps = prefs.cycle(for: direction)
                    ForEach(steps.indices, id: \.self) { i in
                        HStack {
                            Text("Step \(i + 1)").foregroundStyle(.secondary)
                            Picker("", selection: binding(direction, i)) {
                                ForEach(Fraction.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Button { move(direction, i) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless).disabled(i == 0).help("Move up")
                            Button { remove(direction, i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).disabled(steps.count <= 1).help("Remove step")
                        }
                    }
                    Button("Add Step") { prefs.cycles[direction] = steps + [.half] }
                        .disabled(steps.count >= 6)
                }
            }
            Button("Restore Default Cycles (1/2 → 2/3 → 1/3)") { prefs.resetCycles() }
        }
        .formStyle(.grouped)
    }

    private func binding(_ direction: Direction, _ index: Int) -> Binding<Fraction> {
        Binding(
            get: { prefs.cycle(for: direction).indices.contains(index) ? prefs.cycle(for: direction)[index] : .half },
            set: { value in
                var list = prefs.cycle(for: direction)
                guard list.indices.contains(index) else { return }
                list[index] = value
                prefs.cycles[direction] = list
            }
        )
    }

    private func move(_ direction: Direction, _ index: Int) {
        var list = prefs.cycle(for: direction)
        guard index > 0, list.indices.contains(index) else { return }
        list.swapAt(index, index - 1)
        prefs.cycles[direction] = list
    }

    private func remove(_ direction: Direction, _ index: Int) {
        var list = prefs.cycle(for: direction)
        guard list.count > 1, list.indices.contains(index) else { return }
        list.remove(at: index)
        prefs.cycles[direction] = list
    }
}

/// Cycle timeout, HUD, gap size, launch at login, permissions and support.
private struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("resetTimeout") private var resetTimeout = 2.0
    @AppStorage("showHUD") private var showHUD = true
    @AppStorage("gap") private var gap = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Cycling") {
                VStack(alignment: .leading) {
                    Text("Reset cycle after \(resetTimeout, specifier: "%.1f") s")
                    Slider(value: $resetTimeout, in: 0.5...5, step: 0.1)
                }
                Toggle("Show layout HUD", isOn: $showHUD)
                Stepper("Gap between windows: \(gap) pt", value: $gap, in: 0...40, step: 2)
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Image(systemName: appState.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appState.isTrusted ? .green : .orange)
                    Text(appState.isTrusted ? "Accessibility access granted"
                         : "Accessibility access is needed to move windows. Shortcuts are disabled until granted.")
                    Spacer()
                    if !appState.isTrusted {
                        Button("Grant…") { appState.requestAccessibility() }
                    }
                }
            }
            Section {
                HStack {
                    Text("SizeCycleKeys is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { AppState.openDonate() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
