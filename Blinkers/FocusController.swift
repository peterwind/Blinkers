import AppKit
import Observation
import os

/// Owns the focus state: which window has focus, where it came from, and the
/// curtain's moves between states.
@Observable
final class FocusController {
    private(set) var isActive = false
    private(set) var isTrusted = WindowMover.isTrusted
    /// Horizontal offset of the menu bar icon, used for the "no window" shake.
    private(set) var iconShakeOffset: CGFloat = 0
    /// Another app seems to react to the same shortcut. Shown in the popover
    /// until the shortcut changes or the note is dismissed.
    private(set) var shortcutConflict = false

    @ObservationIgnored private var target: WindowMover?
    @ObservationIgnored private var savedFrame: CGRect?
    /// Whether Blinkers moved the target, and so has to put it back.
    @ObservationIgnored private var centeredByUs = false
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var isTransitioning = false
    /// A key press that came in mid-transition; it's played once the transition ends,
    /// so quick presses are never lost.
    @ObservationIgnored private var toggleQueued = false
    /// Windows recently sent back, and where to. A window can take a moment to
    /// land, so if it's focused again meanwhile, this is its real original frame.
    @ObservationIgnored private var restoring: [(window: WindowMover, frame: CGRect, until: Date)] = []
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private lazy var curtain = CurtainPanels { [weak self] in self?.turnOff() }
    @ObservationIgnored private let transition = CurtainTransition()
    @ObservationIgnored private let watcher = FrontWindowWatcher()
    @ObservationIgnored private let notice = ConflictNotice()
    @ObservationIgnored private var lastNotice: Date?
    /// When Blinkers itself last moved a window, to tell its own moves from other apps'.
    @ObservationIgnored private var ownMoves: [(window: WindowMover, time: Date)] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.peterwind.Blinkers", category: "Focus")

    /// Durations and curves for the curtain's moves.
    private enum Motion {
        /// The hole closes over the window so it can jump unseen.
        static let cover = 0.16
        static let coverCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        /// The hole opens around the window's new place.
        static let reveal = 0.34
        static let revealCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        /// The hole glides between frames without covering the window.
        static let glide = 0.36
        static let glideCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    }

    init() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApp = front }
        observeSystem()
        if !isTrusted { pollTrust() }
        recoverFromPreviousRun()
        if isTrusted, let lastExternalApp { watcher.follow(lastExternalApp) }
    }

    // MARK: Actions

    /// `fromShortcut` is set for the global shortcut, which another app may
    /// also react to; Blinkers then checks whether the window moved on its own.
    func toggle(fromShortcut: Bool = false) {
        guard !isTransitioning else {
            toggleQueued.toggle()
            return
        }
        guard isTrusted else {
            WindowMover.promptForTrust()
            return
        }

        let window = lastExternalApp.flatMap(WindowMover.focusedWindow(of:))
        if fromShortcut, let window { checkForConflict(on: window) }
        if isActive {
            if let window, let target, !window.isSameWindow(as: target) {
                switchTo(window)
            } else {
                turnOff()
            }
        } else if let window {
            turnOn(window)
        } else {
            shakeIcon()
        }
    }

    func dismissShortcutConflict() {
        shortcutConflict = false
        notice.hide()
    }

    // MARK: Shortcut conflicts

    /// Another app moving the window on the same key press means it shares the
    /// shortcut. That app often gets there first, so Blinkers looks just before
    /// the press, and again shortly after in case its move arrives late. Either
    /// way the window goes back where it was and the user is told.
    private func checkForConflict(on window: WindowMover) {
        let press = Date.now
        if let change = foreignChange(of: window, from: press.addingTimeInterval(-0.35), to: press) {
            move(window, to: change.previous)
            reportConflict(change)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard let change = foreignChange(of: window, from: press, to: .now) else { return }
            // The frame Blinkers saved may already be the other app's.
            if let target, target.isSameWindow(as: window) {
                if let savedFrame, savedFrame.isClose(to: change.frame) { self.savedFrame = change.previous }
                if !centeredByUs { move(window, to: change.previous) }
            } else if !isActive {
                move(window, to: change.previous)
            }
            reportConflict(change)
        }
    }

    /// The first move of `window` in the span that Blinkers didn't make.
    private func foreignChange(of window: WindowMover, from start: Date, to end: Date) -> FrontWindowWatcher.Change? {
        watcher.changes(of: window, from: start, to: end).first { change in
            !ownMoves.contains { $0.window.isSameWindow(as: window) && change.time >= $0.time && change.time < $0.time.addingTimeInterval(0.5) }
        }
    }

    private func reportConflict(_ change: FrontWindowWatcher.Change) {
        logger.notice("Another app moved the window from \(change.previous.debugDescription, privacy: .public) to \(change.frame.debugDescription, privacy: .public) on the shortcut")
        shortcutConflict = true
        // Once is enough while the user is still pressing away.
        if let lastNotice, lastNotice > .now.addingTimeInterval(-30) { return }
        lastNotice = .now
        notice.show()
    }

    /// Every frame change Blinkers makes goes through here, so it can tell its
    /// own moves from another app's.
    private func move(_ window: WindowMover, to frame: CGRect) {
        ownMoves.removeAll { $0.time < .now.addingTimeInterval(-3) }
        ownMoves.append((window, .now))
        window.setFrame(frame)
    }

    /// The popover's switch: on or off only, never a switch to another window.
    func setFocus(_ on: Bool) {
        if on {
            if !isActive { toggle() }
        } else {
            turnOff()
        }
    }

    /// Called from `applicationWillTerminate`: put everything back at once.
    func prepareForTermination() {
        defer { FocusRecovery.clear() }
        transition.end()
        guard isActive else { return }
        isActive = false
        target?.stopObserving()
        if centeredByUs, let target, let savedFrame { move(target, to: savedFrame) }
        curtain.hideImmediately()
    }

    /// Re-applies the settings while focus is active. Changes apply at once,
    /// without moves, so sliders follow the hand.
    func settingsChanged() {
        let settings = Settings.current
        curtain.setAppearance(color: settings.color, opacity: settings.opacity)
        guard isActive, !isTransitioning, let target, let screen else { return }

        if settings.centerWindow {
            moveToCenter()
        } else if centeredByUs, let savedFrame {
            // Centering was just turned off: the window goes back where it was.
            restore(target, to: savedFrame)
            centeredByUs = false
        }
        if let frame = target.frame { curtain.layout(around: frame, in: curtainArea(of: screen)) }
        persistRecovery()
    }

    // MARK: Transitions

    private func turnOn(_ window: WindowMover) {
        isActive = true
        begin(window)
        let settings = Settings.current
        curtain.setAppearance(color: settings.color, opacity: settings.opacity)
        guard let screen, let frame = window.frame else { return }
        let area = curtainArea(of: screen)
        let opacity = Float(settings.opacity / 100)

        isTransitioning = true
        if settings.centerWindow {
            // Fade in while the hole closes over the window, jump it unseen, open around its new place.
            transition.begin(in: area, color: settings.color, opacity: 0, hole: CurtainTransition.hole(around: frame))
            transition.animate(to: CurtainTransition.closed(at: frame), opacity: opacity,
                               duration: Motion.cover, timing: Motion.coverCurve) { [weak self] in
                self?.revealCentered(in: area)
            }
        } else {
            // The curtain closes in from the screen's edges and stops around the window.
            transition.begin(in: area, color: settings.color, opacity: 0, hole: CurtainTransition.open(around: area))
            transition.animate(to: CurtainTransition.hole(around: frame), opacity: opacity,
                               duration: Motion.glide, timing: Motion.glideCurve) { [weak self] in
                self?.finishTransition()
            }
        }
    }

    func turnOff() {
        guard !isTransitioning else {
            // Clicked the curtain mid-transition: turn off once it's done.
            if isActive { toggleQueued = true }
            return
        }
        guard isActive else { return }
        logger.debug("Focus off; window at \(self.target?.frame?.debugDescription ?? "?", privacy: .public), saved \(self.savedFrame?.debugDescription ?? "?", privacy: .public)")
        isActive = false
        guard let target, let frame = target.frame, let screen else {
            releaseTarget()
            curtain.hide()
            return persistRecovery()
        }
        let area = curtainArea(of: screen)
        let settings = Settings.current
        let wasCentered = centeredByUs
        let saved = savedFrame

        isTransitioning = true
        transition.begin(in: area, color: settings.color, opacity: Float(settings.opacity / 100),
                         hole: CurtainTransition.hole(around: frame))
        curtain.hideImmediately()

        if wasCentered, let saved {
            // Close over the window, send it home unseen, then open from there while fading out.
            transition.animate(to: CurtainTransition.closed(at: frame), duration: Motion.cover,
                               timing: Motion.coverCurve) { [weak self] in
                guard let self else { return }
                self.releaseTarget()
                self.transition.set(hole: CurtainTransition.closed(at: saved))
                self.transition.animate(to: CurtainTransition.open(around: area), opacity: 0,
                                        duration: Motion.reveal, timing: Motion.revealCurve) { [weak self] in
                    self?.endTransition()
                }
            }
        } else {
            // The window stays put; the curtain draws back to the screen's edges.
            releaseTarget()
            transition.animate(to: CurtainTransition.open(around: area), opacity: 0,
                               duration: Motion.glide, timing: Motion.glideCurve) { [weak self] in
                self?.endTransition()
            }
        }
        persistRecovery()
    }

    private func switchTo(_ window: WindowMover) {
        guard let target, let frame = target.frame, let screen else {
            releaseTarget()
            return begin(window)
        }
        let area = curtainArea(of: screen)
        let settings = Settings.current

        isTransitioning = true
        transition.begin(in: area, color: settings.color, opacity: Float(settings.opacity / 100),
                         hole: CurtainTransition.hole(around: frame))
        curtain.hideImmediately()

        if settings.centerWindow {
            transition.animate(to: CurtainTransition.closed(at: frame), duration: Motion.cover,
                               timing: Motion.coverCurve) { [weak self] in
                guard let self else { return }
                self.releaseTarget()
                self.begin(window)
                self.revealCentered(in: area)
            }
        } else {
            // The hole travels from one window to the other.
            releaseTarget()
            begin(window)
            guard let newFrame = window.frame else { return finishTransition() }
            transition.animate(to: CurtainTransition.hole(around: newFrame), duration: Motion.glide,
                               timing: Motion.glideCurve) { [weak self] in
                self?.finishTransition()
            }
        }
    }

    /// With the window covered, centers it and opens the hole around where it landed.
    private func revealCentered(in area: CGRect) {
        guard isActive, let landed = moveToCenter() else {
            // The window went away while covered.
            return transition.animate(to: CurtainTransition.open(around: area), opacity: 0,
                                      duration: Motion.glide, timing: Motion.glideCurve) { [weak self] in
                self?.endTransition()
            }
        }
        transition.set(hole: CurtainTransition.closed(at: landed))
        transition.animate(to: CurtainTransition.hole(around: landed), duration: Motion.reveal,
                           timing: Motion.revealCurve) { [weak self] in
            self?.finishTransition()
        }
    }

    /// Hands over from the transition to the real curtain panels.
    private func finishTransition() {
        guard isActive, let target, let frame = target.frame, let screen else { return endTransition() }
        curtain.show(around: frame, in: curtainArea(of: screen), fading: false)
        persistRecovery()
        // The real panels are on screen now; remove the transition a beat later
        // so there's never a frame with neither.
        let run = transition.run
        Task { [transition] in transition.end(run: run) }
        transitionEnded()
    }

    private func endTransition() {
        transition.end()
        transitionEnded()
    }

    private func transitionEnded() {
        isTransitioning = false
        // Catch up with anything that moved meanwhile, then play a queued press.
        if isActive { followTarget() }
        if toggleQueued {
            toggleQueued = false
            toggle()
        }
    }

    // MARK: Target

    private func begin(_ window: WindowMover) {
        target = window
        restoring.removeAll { $0.until < .now }
        if let index = restoring.firstIndex(where: { $0.window.isSameWindow(as: window) }) {
            // Still on its way back from last time; its current frame is a halfway point.
            savedFrame = restoring.remove(at: index).frame
        } else {
            savedFrame = window.frame
        }
        logger.debug("Focus window of pid \(window.pid) at \(window.frame?.debugDescription ?? "?", privacy: .public)")
        centeredByUs = false
        screen = Self.screen(containing: savedFrame) ?? NSScreen.main
        _ = window.windowID // Look it up while the window is still where the window server last saw it.
        curtain.windowID = window.windowID
        window.startObserving { [weak self] event in self?.handle(event) }
    }

    /// Lets go of the current target, putting it back first if Blinkers moved it.
    private func releaseTarget() {
        defer {
            target = nil
            savedFrame = nil
            centeredByUs = false
        }
        guard let target else { return }
        target.stopObserving()
        if centeredByUs, let savedFrame { restore(target, to: savedFrame) }
    }

    /// Sets the frame, then checks that it held. Some apps apply a new frame
    /// late or nudge it, so the frame is set again if the window didn't land.
    /// A window that doesn't stay put is logged; every step is logged at debug
    /// level, visible with `log stream --level debug --predicate 'subsystem == "com.peterwind.Blinkers"'`.
    private func restore(_ window: WindowMover, to frame: CGRect) {
        let before = window.frame
        move(window, to: frame)
        restoring.removeAll { $0.window.isSameWindow(as: window) }
        restoring.append((window, frame, .now.addingTimeInterval(1.5)))
        logger.debug("Restore to \(frame.debugDescription, privacy: .public) from \(before?.debugDescription ?? "?", privacy: .public); landed at \(window.frame?.debugDescription ?? "?", privacy: .public)")
        Task {
            for delay in [100, 300, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                // Focused again in the meantime: the window is no longer ours to put back.
                if let target, target.isSameWindow(as: window) { return }
                guard let actual = window.frame else { return }
                if actual.isClose(to: frame) { continue }
                logger.notice("After \(delay) ms the window is at \(actual.debugDescription, privacy: .public), not \(frame.debugDescription, privacy: .public)")
                if delay < 1000 { move(window, to: frame) }
            }
        }
    }

    // MARK: Layout

    /// The part of the screen below the menu bar. The curtain always covers this.
    private func curtainArea(of screen: NSScreen) -> CGRect {
        var area = screen.frame
        area.size.height = screen.visibleFrame.maxY - screen.frame.minY
        return area
    }

    /// Where the window may go: below the menu bar and above the Dock. A Dock
    /// that hides itself only takes room while it's showing, so it's ignored.
    private func layoutArea(of screen: NSScreen) -> CGRect {
        Self.dockHidesItself ? curtainArea(of: screen) : screen.visibleFrame
    }

    private static var dockHidesItself: Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }

    private func destination(on screen: NSScreen) -> CGRect {
        let area = layoutArea(of: screen)
        let width = Settings.current.windowWidth(screenWidth: area.width)
        let height = area.height - 2 * Settings.verticalGap
        return Self.centered(CGSize(width: width, height: height), in: area)
    }

    /// Moves the target to the middle of the screen in one step and returns
    /// where it landed. Some apps refuse the size; whatever they accept is centered.
    @discardableResult
    private func moveToCenter() -> CGRect? {
        guard let target, let screen = screen ?? NSScreen.main else { return nil }
        let destination = destination(on: screen)
        let before = target.frame
        move(target, to: destination)
        centeredByUs = true

        guard let landed = target.frame, landed.size != destination.size else { return target.frame }
        if landed.size != before?.size {
            // The app picked a size of its own (Terminal rounds to its grid): center that.
            recenter(target, size: landed.size, on: screen)
        } else {
            // Unchanged so far: either refused, or applied a moment later. Look again shortly
            // rather than mistaking a late window for a refusal.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard self.isActive, self.target === target, let now = target.frame, now.size != destination.size else { return }
                self.recenter(target, size: now.size, on: screen)
                if !self.isTransitioning { self.followTarget() }
            }
        }
        logger.debug("Center to \(destination.debugDescription, privacy: .public); landed at \(target.frame?.debugDescription ?? "?", privacy: .public)")
        return target.frame
    }

    private func recenter(_ target: WindowMover, size: CGSize, on screen: NSScreen) {
        move(target, to: Self.centered(size, in: layoutArea(of: screen)))
    }

    private func followTarget() {
        guard let target, let frame = target.frame else { return }
        logger.debug("Window moved to \(frame.debugDescription, privacy: .public)")
        // A full-screen window owns its own Space; leave it there.
        if target.isFullScreen { return targetGone() }
        // The window was dragged to another screen: the curtain moves with it.
        if let newScreen = Self.screen(containing: frame) { screen = newScreen }
        guard let screen else { return }
        curtain.layout(around: frame, in: curtainArea(of: screen))
        persistRecovery()
    }

    private func handle(_ event: WindowMover.Event) {
        switch event {
        case .frameChanged:
            // Blinkers' own jump mid-transition is not the user moving the window.
            if !isTransitioning { followTarget() }
        case .closed, .minimized:
            targetGone()
        }
    }

    /// The window can't or shouldn't be restored (closed, minimized, full screen,
    /// app quit); only the curtain goes away.
    private func targetGone() {
        target?.stopObserving()
        target = nil
        savedFrame = nil
        guard isActive else { return }
        isActive = false
        curtain.hide()
        persistRecovery()
    }

    // MARK: Crash recovery

    /// Records where the window came from, so it can be put back if Blinkers
    /// dies without reaching `applicationWillTerminate` (crash, force quit, kill).
    private func persistRecovery() {
        guard isActive, centeredByUs, let target else { return FocusRecovery.clear() }
        FocusRecovery(pid: target.pid, savedFrame: savedFrame, currentFrame: target.frame).save()
    }

    /// Puts back what a previous run left behind. The window is recognised by
    /// its owner and its last known frame, so a reused pid or a window the user
    /// has since moved is left alone.
    private func recoverFromPreviousRun() {
        guard let recovery = FocusRecovery.load() else { return }
        FocusRecovery.clear()

        guard isTrusted, let pid = recovery.pid, let saved = recovery.savedFrame,
              let current = recovery.currentFrame,
              NSRunningApplication(processIdentifier: pid) != nil else { return }
        let window = WindowMover.windows(ofPID: pid).first { $0.frame?.isClose(to: current) == true }
        if let window { move(window, to: saved) }
    }

    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    private static func screen(containing frame: CGRect?) -> NSScreen? {
        guard let frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
    }

    // MARK: System events

    private func observeSystem() {
        #if DEBUG
        // Lets a developer toggle focus from the shell, without the hotkey, to test window moves.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.peterwind.Blinkers.debug.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle(fromShortcut: true) }
        })
        #endif

        let workspace = NSWorkspace.shared.notificationCenter
        let ownPID = ProcessInfo.processInfo.processIdentifier

        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastExternalApp = app
                if self.isTrusted { self.watcher.follow(app) }
                // Activating an app raises its windows above the corner panel.
                if self.target?.pid == pid { self.curtain.orderCornersBehindWindow() }
            }
        })

        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.target?.pid == pid else { return }
                self.targetGone()
            }
        })

        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let target = self.target, target.isFullScreen else { return }
                self.targetGone()
            }
        })

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.screen = Self.screen(containing: self.target?.frame) ?? NSScreen.main
                self.settingsChanged()
            }
        })
    }

    private func pollTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, WindowMover.isTrusted else { return }
                self.isTrusted = true
                if let app = self.lastExternalApp { self.watcher.follow(app) }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
            }
        }
    }

    private func shakeIcon() {
        Task {
            for offset: CGFloat in [-2, 2, -2, 2, -1, 1, 0] {
                iconShakeOffset = offset
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 2 && abs(minY - other.minY) < 2
            && abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}

/// Where the focused window came from, stored so the next launch can put it
/// back after a crash.
struct FocusRecovery: Codable, Equatable {
    var pid: pid_t?
    var savedFrame: CGRect?
    var currentFrame: CGRect?

    private static let key = "focusRecovery"

    static func load(from defaults: UserDefaults = .standard) -> FocusRecovery? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FocusRecovery.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
