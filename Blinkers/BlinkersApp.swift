import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct BlinkersApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = FocusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; keep the hotkey and permission prompt out of them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        KeyboardShortcuts.Name.migrateOldDefault()
        KeyboardShortcuts.onKeyDown(for: .toggleFocus) { [controller] in controller.toggle(fromShortcut: true) }
        controller.settingsChanged()

        if Onboarding.shouldShow { Onboarding.shared.show(controller: controller) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.prepareForTermination()
    }
}

/// `rectangle.center.inset.filled` while focus is on; a matching outline drawn
/// by hand while it is off, since SF Symbols has no outline variant.
private struct MenuBarIcon: View {
    let controller: FocusController

    var body: some View {
        Image(nsImage: Self.image(filled: controller.isActive, offset: controller.iconShakeOffset))
            .accessibilityLabel("Blinkers")
    }

    private static let padding: CGFloat = 2

    static func image(filled: Bool, offset: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let name = filled ? "rectangle.center.inset.filled" : "rectangle"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Blinkers")!
            .withSymbolConfiguration(config)!

        let size = NSSize(width: symbol.size.width + 2 * padding, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: padding + offset, y: 0, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: rect)
            if !filled { drawInnerOutline(in: rect) }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Strokes the inner rectangle where the filled symbol has its fill.
    /// Proportions measured from the symbol itself.
    private static func drawInnerOutline(in rect: NSRect) {
        let line = rect.width * 0.062
        let inner = NSRect(
            x: rect.minX + rect.width * 0.276,
            y: rect.minY + rect.height * 0.277,
            width: rect.width * 0.453,
            height: rect.height * 0.434
        ).insetBy(dx: line / 2, dy: line / 2)
        let path = NSBezierPath(roundedRect: inner, xRadius: line * 0.7, yRadius: line * 0.7)
        path.lineWidth = line
        NSColor.black.setStroke()
        path.stroke()
    }
}
