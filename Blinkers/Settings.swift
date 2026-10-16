import AppKit
import KeyboardShortcuts
import SwiftUI

enum WidthMode: String, CaseIterable, Identifiable {
    case pixels, window, sides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixels: "Pixels"
        case .window: "Window"
        case .sides: "Sides"
        }
    }
}

/// `@AppStorage` keys and defaults. Views bind to these keys directly;
/// `FocusController` reads the current values through `Settings.current`.
enum Settings {
    enum Key {
        static let centerWindow = "centerWindow"
        static let widthMode = "widthMode"
        static let pixelsWidth = "pixelsWidth"
        static let windowPercent = "windowPercent"
        static let sidesPercent = "sidesPercent"
        static let colorHex = "colorHex"
        static let opacity = "opacity"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    enum Default {
        static let centerWindow = true
        static let widthMode = WidthMode.window
        static let pixelsWidth = 1600.0
        static let windowPercent = 60.0
        static let sidesPercent = 40.0
        static let colorHex = "#000000"
        static let opacity = 100.0
    }

    static let pixelsMin = 400.0
    static let pixelsStep = 10.0
    static let windowRange = 20.0...100.0
    static let sidesRange = 0.0...80.0
    static let percentStep = 5.0

    /// Space between the window and the top/bottom of the usable area.
    static let verticalGap: CGFloat = 12
    static let fadeDuration: TimeInterval = 0.25

    struct Snapshot {
        var centerWindow = Default.centerWindow
        var widthMode: WidthMode
        var pixelsWidth: Double
        var windowPercent: Double
        var sidesPercent: Double
        var color: NSColor
        var opacity: Double

        /// Window width on a screen that is `screenWidth` points wide.
        func windowWidth(screenWidth s: CGFloat) -> CGFloat {
            let width: CGFloat = switch widthMode {
            case .pixels: max(pixelsWidth, Settings.pixelsMin)
            case .window: s * windowPercent / 100
            case .sides: s * (100 - sidesPercent) / 100
            }
            return min(width, s)
        }
    }

    static var current: Snapshot {
        let d = UserDefaults.standard
        return Snapshot(
            centerWindow: d.object(forKey: Key.centerWindow) as? Bool ?? Default.centerWindow,
            widthMode: d.string(forKey: Key.widthMode).flatMap(WidthMode.init(rawValue:)) ?? Default.widthMode,
            pixelsWidth: d.object(forKey: Key.pixelsWidth) as? Double ?? Default.pixelsWidth,
            windowPercent: d.object(forKey: Key.windowPercent) as? Double ?? Default.windowPercent,
            sidesPercent: d.object(forKey: Key.sidesPercent) as? Double ?? Default.sidesPercent,
            color: NSColor(hex: d.string(forKey: Key.colorHex) ?? Default.colorHex) ?? .black,
            opacity: d.object(forKey: Key.opacity) as? Double ?? Default.opacity
        )
    }
}

extension KeyboardShortcuts.Name {
    static let toggleFocus = Self("toggleFocus", initial: .init(.b, modifiers: [.control, .option]))

    /// ⌃⌥F was the first default, but Rectangle uses it for "Center Third".
    /// Moves a shortcut still on that old default to the new one, once.
    static func migrateOldDefault() {
        let key = "migratedShortcutFromControlOptionF"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if KeyboardShortcuts.getShortcut(for: .toggleFocus) == .init(.f, modifiers: [.control, .option]) {
            KeyboardShortcuts.setShortcut(.init(.b, modifiers: [.control, .option]), for: .toggleFocus)
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? .black
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
