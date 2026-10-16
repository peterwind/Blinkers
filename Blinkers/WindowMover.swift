import AppKit
import ApplicationServices

/// Accessibility wrapper around one window of another app: find it, read and
/// set its frame, and observe it for moves, resizes and closing.
///
/// Frames are in Cocoa screen coordinates (origin at the bottom left of the
/// primary screen). AX uses top-left coordinates; conversion happens here.
final class WindowMover {
    enum Event {
        case frameChanged
        case closed
        case minimized
    }

    let pid: pid_t
    let window: AXUIElement
    private let app: AXUIElement
    private var observer: AXObserver?
    private var onEvent: ((Event) -> Void)?

    /// How long an AX call may wait for the other app. The default is about six
    /// seconds, and AX calls run on the main thread, so a hung app would freeze Blinkers.
    private static let messagingTimeout: Float = 1

    private init(pid: pid_t, window: AXUIElement) {
        self.pid = pid
        self.window = window
        self.app = Self.appElement(pid)
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
    }

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    // MARK: Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to the Accessibility pane.
    static func promptForTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Finding

    /// The focused window of the given app, if it has a movable one.
    static func focusedWindow(of app: NSRunningApplication) -> WindowMover? {
        let application = Self.appElement(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let window = value as! AXUIElement

        guard string(window, kAXRoleAttribute) == kAXWindowRole as String else { return nil }
        let mover = WindowMover(pid: app.processIdentifier, window: window)
        guard mover.frame != nil else { return nil }
        return mover
    }

    /// All standard windows of an app, used to find a window again after a crash.
    static func windows(ofPID pid: pid_t) -> [WindowMover] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        return windows
            .filter { string($0, kAXRoleAttribute) == kAXWindowRole as String }
            .map { WindowMover(pid: pid, window: $0) }
    }

    func isSameWindow(as other: WindowMover) -> Bool {
        CFEqual(window, other.window)
    }

    // MARK: Frame

    var frame: CGRect? {
        guard let position = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return Self.flip(CGRect(origin: position, size: size))
    }

    var isFullScreen: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Moves and resizes the window. Apps may refuse part of the request,
    /// so callers read `frame` afterwards for the result.
    func setFrame(_ frame: CGRect) {
        let target = Self.flip(frame)
        withEnhancedUserInterfaceOff {
            // Size first so the move isn't clamped by the old size, then move,
            // then size again in case the move limited the first resize.
            set(size: target.size)
            set(position: target.origin)
            set(size: target.size)
        }
    }

    /// Apps with "enhanced user interface" on (set by VoiceOver and some
    /// window managers) animate AX resizes themselves and end up in the wrong place.
    private func withEnhancedUserInterfaceOff(_ body: () -> Void) {
        let enhanced = Self.bool(app, "AXEnhancedUserInterface")
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        body()
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// The window server's id for the window, so Blinkers can order a panel
    /// directly behind it. Found by owner and bounds, since AX has no public
    /// attribute for it. Read before the window is moved.
    private(set) lazy var windowID: CGWindowID? = {
        guard let frame else { return nil }
        let bounds = Self.flip(frame)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let match = list.first { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return abs(rect.minX - bounds.minX) < 1 && abs(rect.minY - bounds.minY) < 1
                && abs(rect.width - bounds.width) < 1 && abs(rect.height - bounds.height) < 1
        }
        return (match?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }()

    // MARK: Observing

    func startObserving(_ onEvent: @escaping (Event) -> Void) {
        stopObserving()
        self.onEvent = onEvent

        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(created, window, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    func stopObserving() {
        guard let observer else { return }
        for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverRemoveNotification(observer, window, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        onEvent = nil
    }

    fileprivate func handle(_ notification: String) {
        switch notification {
        case kAXUIElementDestroyedNotification: onEvent?(.closed)
        case kAXWindowMiniaturizedNotification: onEvent?(.minimized)
        default: onEvent?(.frameChanged)
        }
    }

    // MARK: Helpers

    /// Converts between AX (top-left) and Cocoa (bottom-left) coordinates.
    /// The conversion is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func point(_ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func size(_ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private func set(position: CGPoint) {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func set(size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

/// AX delivers notifications on the main run loop, where the observer's source was added.
nonisolated private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let name = notification as String
    let address = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        let pointer = UnsafeMutableRawPointer(bitPattern: address)!
        Unmanaged<WindowMover>.fromOpaque(pointer).takeUnretainedValue().handle(name)
    }
}

/// Follows the focused window of the frontmost app and keeps a short history
/// of its frames, so Blinkers can tell when another app moved it on the same
/// key press. That app usually gets there first, so the history has to start
/// before the press.
final class FrontWindowWatcher {
    struct Change {
        let time: Date
        let frame: CGRect
        /// The frame before this change.
        let previous: CGRect
    }

    private(set) var window: WindowMover?
    private(set) var changes: [Change] = []
    private var lastFrame: CGRect?
    private var pid: pid_t?
    private var appObserver: AXObserver?
    private var appElement: AXUIElement?

    /// Starts following the given app's focused window.
    func follow(_ app: NSRunningApplication) {
        guard app.processIdentifier != pid else { return }
        stopApp()
        pid = app.processIdentifier
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        appElement = element

        var created: AXObserver?
        if AXObserverCreate(app.processIdentifier, frontWindowCallback, &created) == .success, let created {
            AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            appObserver = created
        }
        attachFocusedWindow()
    }

    /// Changes to `window` in the given time span.
    func changes(of window: WindowMover, from start: Date, to end: Date) -> [Change] {
        guard let watched = self.window, watched.isSameWindow(as: window) else { return [] }
        return changes.filter { $0.time >= start && $0.time <= end }
    }

    fileprivate func focusedWindowChanged() {
        attachFocusedWindow()
    }

    private func attachFocusedWindow() {
        window?.stopObserving()
        window = nil
        changes = []
        guard let pid, let app = NSRunningApplication(processIdentifier: pid),
              let focused = WindowMover.focusedWindow(of: app) else { return }
        window = focused
        lastFrame = focused.frame
        focused.startObserving { [weak self, weak focused] event in
            guard let self, let focused, event == .frameChanged, let frame = focused.frame else { return }
            if let lastFrame = self.lastFrame, frame != lastFrame {
                self.changes.append(Change(time: .now, frame: frame, previous: lastFrame))
                self.changes.removeAll { $0.time < .now.addingTimeInterval(-3) }
            }
            self.lastFrame = frame
        }
    }

    private func stopApp() {
        window?.stopObserving()
        window = nil
        changes = []
        if let appObserver, let appElement {
            AXObserverRemoveNotification(appObserver, appElement, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .defaultMode)
        }
        appObserver = nil
        appElement = nil
        pid = nil
    }
}

nonisolated private func frontWindowCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let address = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        let pointer = UnsafeMutableRawPointer(bitPattern: address)!
        Unmanaged<FrontWindowWatcher>.fromOpaque(pointer).takeUnretainedValue().focusedWindowChanged()
    }
}
