import AppKit
import KeyboardShortcuts
import SwiftUI

/// A small note under the menu bar icon, shown when another app seems to react
/// to Blinkers' shortcut too. It doesn't take focus and goes away by itself.
final class ConflictNotice {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: NoticeView(shortcut: shortcutText) { [weak self] in self?.hide() })
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        hideTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 0 } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private var shortcutText: String {
        KeyboardShortcuts.getShortcut(for: .toggleFocus)?.description ?? "the shortcut"
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Just below Blinkers' menu bar icon, kept on screen.
    private func origin(for size: CGSize) -> CGPoint {
        let item = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }?.frame
        let screen = NSScreen.screens.first { item.map($0.frame.intersects) ?? false } ?? NSScreen.main ?? NSScreen.screens[0]
        let anchor = item ?? CGRect(x: screen.frame.maxX - 40, y: screen.visibleFrame.maxY, width: 0, height: 0)
        let x = min(max(anchor.midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        return CGPoint(x: x, y: anchor.minY - size.height - 6)
    }
}

private struct NoticeView: View {
    let shortcut: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Another app moved the window")
                    .font(.headline)
                Text("Another app probably also reacts to \(shortcut). Choose a different shortcut in the Blinkers menu.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
