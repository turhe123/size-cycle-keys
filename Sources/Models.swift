import Carbon
import Foundation

/// A window-sizing command that can be bound to a hotkey or triggered from the menu.
enum Action: String, CaseIterable, Codable, Identifiable {
    case left, right, up, down, maximize, center, nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left (cycle)"
        case .right: return "Right (cycle)"
        case .up: return "Top (cycle)"
        case .down: return "Bottom (cycle)"
        case .maximize: return "Maximize / Restore"
        case .center: return "Center (60% / 80% / original)"
        case .nextDisplay: return "Next Display"
        }
    }

    /// The screen edge this action snaps to, if it is one of the four cycling directions.
    var direction: Direction? { Direction(rawValue: rawValue) }
}

/// One of the four screen edges a cycling action anchors a window to.
enum Direction: String, CaseIterable, Codable, Identifiable {
    case left, right, up, down

    var id: String { rawValue }

    var name: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Top"
        case .down: return "Bottom"
        }
    }
}

/// A fraction of the display's visible area that a cycle step occupies.
enum Fraction: String, CaseIterable, Codable, Identifiable {
    case quarter = "1/4", third = "1/3", half = "1/2", twoThirds = "2/3", threeQuarters = "3/4"

    var id: String { rawValue }

    var value: CGFloat {
        switch self {
        case .quarter: return 0.25
        case .third: return 1.0 / 3.0
        case .half: return 0.5
        case .twoThirds: return 2.0 / 3.0
        case .threeQuarters: return 0.75
        }
    }
}

/// A Carbon key code plus modifier mask, with a human-readable key label captured at record time.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let ctrlOpt = UInt32(controlKey | optionKey)

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// True when Option is the only modifier — such shortcuts are skipped while typing in text fields.
    var isOptionOnly: Bool { modifiers == UInt32(optionKey) }

    func sameKeys(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    /// A warning when this combination is likely to clash with a macOS system shortcut.
    var conflictWarning: String? {
        let arrows: Set<UInt32> = [123, 124, 125, 126]
        let ctrl = UInt32(controlKey), cmd = UInt32(cmdKey), shift = UInt32(shiftKey)
        if modifiers == ctrl && arrows.contains(keyCode) {
            return "Conflicts with Mission Control / Spaces (⌃ + arrow)."
        }
        if modifiers == ctrl && keyCode == 49 { return "Conflicts with input-source switching (⌃Space)." }
        if modifiers == cmd && [49, 48, 12, 13, 4, 46, 50].contains(keyCode) {
            return "Conflicts with a standard system shortcut."
        }
        if modifiers == cmd | shift && [20, 21, 23].contains(keyCode) { return "Conflicts with screenshot shortcuts." }
        if isOptionOnly { return "Option-only shortcuts are ignored while typing in text fields." }
        return nil
    }

    static func label(forKeyCode code: UInt16, characters: String?) -> String {
        let special: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 49: "Space", 48: "⇥", 51: "⌫", 117: "⌦",
            53: "⎋", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[code] { return name }
        let chars = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return chars.isEmpty ? "Key \(code)" : chars
    }

    static let defaults: [Action: Shortcut] = [
        .left: Shortcut(keyCode: 123, modifiers: ctrlOpt, keyLabel: "←"),
        .right: Shortcut(keyCode: 124, modifiers: ctrlOpt, keyLabel: "→"),
        .up: Shortcut(keyCode: 126, modifiers: ctrlOpt, keyLabel: "↑"),
        .down: Shortcut(keyCode: 125, modifiers: ctrlOpt, keyLabel: "↓"),
        .maximize: Shortcut(keyCode: 36, modifiers: ctrlOpt, keyLabel: "↩"),
        .center: Shortcut(keyCode: 8, modifiers: ctrlOpt, keyLabel: "C"),
        .nextDisplay: Shortcut(keyCode: 45, modifiers: ctrlOpt, keyLabel: "N"),
    ]
}

/// Persists shortcuts and cycle sequences as Codable JSON in UserDefaults and publishes changes.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let defaultCycle: [Fraction] = [.half, .twoThirds, .third]

    private let defaults = UserDefaults.standard

    @Published var shortcuts: [Action: Shortcut] { didSet { saveShortcuts() } }
    @Published var cycles: [Direction: [Fraction]] { didSet { saveCycles() } }

    private init() {
        UserDefaults.standard.register(defaults: ["resetTimeout": 2.0, "showHUD": true, "gap": 0])
        var loadedShortcuts: [Action: Shortcut] = [:]
        var loadedCycles: [Direction: [Fraction]] = [:]
        let decoder = JSONDecoder()
        for action in Action.allCases {
            if let data = defaults.data(forKey: "shortcut.\(action.rawValue)") {
                loadedShortcuts[action] = try? decoder.decode(Shortcut.self, from: data)
            } else if !defaults.bool(forKey: "shortcut.\(action.rawValue).cleared") {
                loadedShortcuts[action] = Shortcut.defaults[action]
            }
        }
        for direction in Direction.allCases {
            let data = defaults.data(forKey: "cycle.\(direction.rawValue)")
            let list = data.flatMap { try? decoder.decode([Fraction].self, from: $0) } ?? []
            loadedCycles[direction] = list.isEmpty ? Self.defaultCycle : list
        }
        shortcuts = loadedShortcuts
        cycles = loadedCycles
    }

    func cycle(for direction: Direction) -> [Fraction] {
        let list = cycles[direction] ?? []
        return list.isEmpty ? Self.defaultCycle : list
    }

    func resetShortcuts() { shortcuts = Shortcut.defaults }
    func resetCycles() { cycles = Dictionary(uniqueKeysWithValues: Direction.allCases.map { ($0, Self.defaultCycle) }) }

    private func saveShortcuts() {
        let encoder = JSONEncoder()
        for action in Action.allCases {
            let key = "shortcut.\(action.rawValue)"
            if let shortcut = shortcuts[action], let data = try? encoder.encode(shortcut) {
                defaults.set(data, forKey: key)
                defaults.set(false, forKey: key + ".cleared")
            } else {
                defaults.removeObject(forKey: key)
                defaults.set(true, forKey: key + ".cleared")
            }
        }
    }

    private func saveCycles() {
        let encoder = JSONEncoder()
        for (direction, list) in cycles {
            if let data = try? encoder.encode(list) { defaults.set(data, forKey: "cycle.\(direction.rawValue)") }
        }
    }
}
