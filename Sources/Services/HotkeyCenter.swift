import Carbon
import Foundation

/// Registers global hotkeys through Carbon `RegisterEventHotKey` and forwards presses as `Action`s.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onPress: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: Action] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature = OSType(0x5343_4B59) // "SCKY"

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if result == noErr {
                DispatchQueue.main.async { HotkeyCenter.shared.fire(hotKeyID.id) }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("SizeCycleKeys: InstallEventHandler failed (\(status))") }
    }

    /// Replaces all registered hotkeys with the given bindings.
    func register(_ bindings: [Action: Shortcut]) {
        unregisterAll()
        installHandlerIfNeeded()
        for (index, action) in Action.allCases.enumerated() {
            guard let shortcut = bindings[action] else { continue }
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id.id] = action
            } else {
                NSLog("SizeCycleKeys: could not register \(shortcut.display) for \(action.rawValue) (\(status))")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    private func fire(_ id: UInt32) {
        guard let action = actionsByID[id] else { return }
        onPress?(action)
    }
}
