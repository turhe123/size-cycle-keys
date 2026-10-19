import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// App entry point: a menu-bar-only app with a Settings window.
@main
struct SizeCycleKeysApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isPaused ? "pause.rectangle" : "rectangle.split.3x1")
        }
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

/// Tracks Accessibility permission and pause/recording state, and keeps Carbon hotkeys in sync.
final class AppState: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published var isPaused = false { didSet { refreshHotkeys() } }
    @Published var isRecording = false { didSet { refreshHotkeys() } }

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init() {
        HotkeyCenter.shared.onPress = { [weak self] action in self?.trigger(action, fromHotkey: true) }
        Preferences.shared.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshHotkeys() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.isTrusted {
                self.isTrusted = trusted
                self.refreshHotkeys()
            }
        }
        refreshHotkeys()
    }

    /// Hotkeys are only active with Accessibility access, when not paused and not recording a shortcut.
    func refreshHotkeys() {
        if isTrusted && !isPaused && !isRecording {
            HotkeyCenter.shared.register(Preferences.shared.shortcuts)
        } else {
            HotkeyCenter.shared.unregisterAll()
        }
    }

    func trigger(_ action: Action, fromHotkey: Bool) {
        let optionOnly = fromHotkey && (Preferences.shared.shortcuts[action]?.isOptionOnly ?? false)
        WindowEngine.shared.perform(action, optionOnly: optionOnly)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshHotkeys()
    }

    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// The MenuBarExtra menu: every action with its hotkey, plus Pause, Settings, Support and Quit.
struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if !appState.isTrusted {
            Text("Accessibility access is required")
            Button("Grant Accessibility Access…") { appState.requestAccessibility() }
            Divider()
        }
        ForEach(Action.allCases) { action in
            Button("\(action.title)    \(prefs.shortcuts[action]?.display ?? "")") {
                appState.trigger(action, fromHotkey: false)
            }
            .disabled(!appState.isTrusted)
        }
        Divider()
        Toggle("Pause Shortcuts", isOn: $appState.isPaused)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Support / Donate ❤️") { AppState.openDonate() }
        Divider()
        Button("Quit SizeCycleKeys") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
