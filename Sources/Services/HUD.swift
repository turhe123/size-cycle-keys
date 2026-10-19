import AppKit
import SwiftUI

/// A small, transient, click-through panel that briefly shows the name of the layout just applied.
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var generation = 0

    func show(_ text: String, on screen: NSScreen?) {
        guard UserDefaults.standard.bool(forKey: "showHUD") else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDView(text: text))
        panel.contentView = host
        let size = host.fittingSize
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak panel] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel?.animator().alphaValue = 0 }) {
                if self.generation == current { panel?.orderOut(nil) }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// The rounded content of the HUD panel.
private struct HUDView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
