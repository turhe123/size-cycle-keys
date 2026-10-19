import AppKit
import ApplicationServices

/// Hashable wrapper so AX window elements can key per-window dictionaries.
private struct WindowKey: Hashable {
    let element: AXUIElement
    static func == (a: WindowKey, b: WindowKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Remembers the last cycling action so a repeated press advances to the next step.
private struct CycleState {
    var action: Action
    var window: WindowKey
    var index: Int
    var time: Date
    var applied: CGRect
}

/// Reads and moves the focused window via the Accessibility API and implements the cycling logic.
/// All geometry is computed in AppKit coordinates and converted to Quartz (top-left origin) for AX.
final class WindowEngine {
    static let shared = WindowEngine()

    private var state: CycleState?
    private var maximizeOriginals: [WindowKey: CGRect] = [:]
    private var centerOriginals: [WindowKey: CGRect] = [:]

    private var timeout: TimeInterval { max(0.5, UserDefaults.standard.double(forKey: "resetTimeout")) }
    private var gap: CGFloat { CGFloat(max(0, UserDefaults.standard.integer(forKey: "gap"))) }

    // MARK: Entry point

    func perform(_ action: Action, optionOnly: Bool = false) {
        guard AXIsProcessTrusted() else { return }
        if optionOnly && isTypingInTextField() { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(appElement, kAXFocusedWindowAttribute),
              let quartzFrame = frame(of: window) else {
            HUD.shared.show("No window", on: NSScreen.main)
            return
        }
        if boolValue(window, "AXFullScreen") {
            HUD.shared.show("Full screen — skipped", on: NSScreen.main)
            return
        }
        pruneClosedWindows()
        let current = flip(quartzFrame)
        guard let screen = bestScreen(for: current) else { return }
        let key = WindowKey(element: window)
        let resizable = isSettable(window, kAXSizeAttribute)

        switch action {
        case .left, .right, .up, .down:
            guard let direction = action.direction else { return }
            let steps = Preferences.shared.cycle(for: direction).map { fraction in
                ("\(direction.name) \(fraction.rawValue)", region(direction, fraction.value, in: screen.visibleFrame))
            }
            runCycle(action, key: key, current: current, steps: steps, resizable: resizable, screen: screen)
        case .center:
            let repeating = isRepeat(action, key: key, current: current)
            if !repeating { centerOriginals[key] = current }
            let original = centerOriginals[key] ?? current
            let v = screen.visibleFrame
            let steps = [0.6, 0.8].map { f -> (String, CGRect) in
                let size = CGSize(width: v.width * f, height: v.height * f)
                return ("Center \(Int(f * 100))%", CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2,
                                                         width: size.width, height: size.height))
            } + [("Original Size", original)]
            runCycle(action, key: key, current: current, steps: steps, resizable: resizable, screen: screen)
        case .maximize:
            let target = inset(screen.visibleFrame, within: screen.visibleFrame)
            state = nil
            if let original = maximizeOriginals[key], isClose(current, target) {
                maximizeOriginals[key] = nil
                apply(original, to: window, resizable: resizable, current: current)
                HUD.shared.show("Restored", on: screen)
            } else {
                maximizeOriginals[key] = current
                apply(target, to: window, resizable: resizable, current: current)
                HUD.shared.show("Maximized", on: screen)
            }
        case .nextDisplay:
            moveToNextDisplay(window, current: current, from: screen, resizable: resizable)
        }
    }

    // MARK: Cycling

    private func isRepeat(_ action: Action, key: WindowKey, current: CGRect) -> Bool {
        guard let s = state else { return false }
        return s.action == action && s.window == key
            && Date().timeIntervalSince(s.time) < timeout && isClose(s.applied, current)
    }

    private func runCycle(_ action: Action, key: WindowKey, current: CGRect,
                          steps: [(String, CGRect)], resizable: Bool, screen: NSScreen) {
        guard !steps.isEmpty else { return }
        var start = 0
        if isRepeat(action, key: key, current: current), let s = state { start = (s.index + 1) % steps.count }
        // Windows with a minimum size may refuse a step; detect it by rereading and skip ahead.
        for attempt in 0..<steps.count {
            let index = (start + attempt) % steps.count
            let (name, target) = steps[index]
            let result = apply(target, to: key.element, resizable: resizable, current: current)
            let fits = !resizable || isClose(result, target)
            if fits || attempt == steps.count - 1 {
                state = CycleState(action: action, window: key, index: index, time: Date(), applied: result)
                HUD.shared.show(name, on: screen)
                return
            }
        }
    }

    // MARK: Geometry

    private func region(_ direction: Direction, _ f: CGFloat, in v: CGRect) -> CGRect {
        let r: CGRect
        switch direction {
        case .left: r = CGRect(x: v.minX, y: v.minY, width: v.width * f, height: v.height)
        case .right: r = CGRect(x: v.maxX - v.width * f, y: v.minY, width: v.width * f, height: v.height)
        case .up: r = CGRect(x: v.minX, y: v.maxY - v.height * f, width: v.width, height: v.height * f)
        case .down: r = CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height * f)
        }
        return inset(r, within: v)
    }

    /// Applies the gap: a full gap on display edges and half a gap on interior edges.
    private func inset(_ r: CGRect, within v: CGRect) -> CGRect {
        let g = gap
        let left = abs(r.minX - v.minX) < 1 ? g : g / 2
        let right = abs(r.maxX - v.maxX) < 1 ? g : g / 2
        let bottom = abs(r.minY - v.minY) < 1 ? g : g / 2
        let top = abs(r.maxY - v.maxY) < 1 ? g : g / 2
        return CGRect(x: r.minX + left, y: r.minY + bottom,
                      width: max(1, r.width - left - right), height: max(1, r.height - top - bottom))
    }

    private func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Converts between AppKit (bottom-left) and Quartz (top-left) global coordinates; the mapping is its own inverse.
    private func flip(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private func bestScreen(for r: CGRect) -> NSScreen? {
        let best = NSScreen.screens.max { a, b in
            area(a.visibleFrame.intersection(r)) < area(b.visibleFrame.intersection(r))
        }
        if let best, area(best.visibleFrame.intersection(r)) > 0 { return best }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private func moveToNextDisplay(_ window: AXUIElement, current: CGRect, from screen: NSScreen, resizable: Bool) {
        let screens = NSScreen.screens
        guard screens.count > 1, let index = screens.firstIndex(of: screen) else {
            HUD.shared.show("Only one display", on: screen)
            return
        }
        let next = screens[(index + 1) % screens.count]
        let a = screen.visibleFrame, b = next.visibleFrame
        var width = resizable ? current.width / a.width * b.width : current.width
        var height = resizable ? current.height / a.height * b.height : current.height
        width = min(width, b.width)
        height = min(height, b.height)
        var x = b.minX + (current.minX - a.minX) / a.width * b.width
        var y = b.minY + (current.minY - a.minY) / a.height * b.height
        x = min(max(x, b.minX), b.maxX - width)
        y = min(max(y, b.minY), b.maxY - height)
        state = nil
        apply(CGRect(x: x, y: y, width: width, height: height), to: window, resizable: resizable, current: current)
        HUD.shared.show(next.localizedName, on: next)
    }

    // MARK: Accessibility

    /// Sets the window frame (AppKit coordinates) and returns the frame the window actually took.
    @discardableResult
    private func apply(_ target: CGRect, to window: AXUIElement, resizable: Bool, current: CGRect) -> CGRect {
        // Non-resizable windows are only moved, anchored at the target's top-left corner.
        let goal = resizable ? target
            : CGRect(x: target.minX, y: target.maxY - current.height, width: current.width, height: current.height)
        let q = flip(goal)
        if resizable { setValue(window, kAXSizeAttribute, size: q.size) }
        setValue(window, kAXPositionAttribute, point: q.origin)
        if resizable { setValue(window, kAXSizeAttribute, size: q.size) }
        return frame(of: window).map(flip) ?? goal
    }

    private func setValue(_ el: AXUIElement, _ attr: String, point: CGPoint? = nil, size: CGSize? = nil) {
        var p = point ?? .zero, s = size ?? .zero
        let value = point != nil ? AXValueCreate(.cgPoint, &p) : AXValueCreate(.cgSize, &s)
        if let value { AXUIElementSetAttributeValue(el, attr as CFString, value) }
    }

    private func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func axValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let p = axValue(window, kAXPositionAttribute), let s = axValue(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func boolValue(_ el: AXUIElement, _ attr: String) -> Bool {
        (copy(el, attr) as? Bool) ?? false
    }

    private func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }

    private func isTypingInTextField() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focused = element(system, kAXFocusedUIElementAttribute),
              let role = copy(focused, kAXRoleAttribute) as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    /// Drops remembered frames for windows that no longer exist.
    private func pruneClosedWindows() {
        func alive(_ key: WindowKey) -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(key.element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
        }
        maximizeOriginals = maximizeOriginals.filter { alive($0.key) }
        centerOriginals = centerOriginals.filter { alive($0.key) }
    }
}
