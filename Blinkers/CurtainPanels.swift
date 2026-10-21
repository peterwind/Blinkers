import AppKit

/// A borderless panel filled with the curtain color, except for an optional hole.
/// Core Animation runs its moves in the window server at the display's frame rate.
class CurtainSurface {
    let panel: CurtainPanel
    private let shape = CAShapeLayer()
    private(set) var area: CGRect = .zero
    private var generation = 0

    init(level: NSWindow.Level, onClick: (() -> Void)?) {
        panel = CurtainPanel(onClick: onClick)
        panel.level = level
        panel.ignoresMouseEvents = onClick == nil

        let view = panel.contentView!
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        shape.fillRule = .evenOdd
        view.layer?.addSublayer(shape)
    }

    var isShown: Bool { panel.isVisible }

    /// Identifies the current run, so a late `end(run:)` can't end a newer one.
    var run: Int { generation }

    /// Puts the surface in its starting state over `area`, without showing it yet.
    func prepare(in area: CGRect, color: NSColor, opacity: Float, hole: Hole?) {
        generation += 1
        self.area = area
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.removeAllAnimations()
        shape.frame = CGRect(origin: .zero, size: area.size)
        shape.fillColor = color.cgColor
        shape.opacity = opacity
        shape.path = path(hole)
        CATransaction.commit()
        panel.setFrame(area, display: true)
    }

    func setAppearance(color: NSColor, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = color.cgColor
        if shape.animation(forKey: "opacity") == nil { shape.opacity = opacity }
        CATransaction.commit()
    }

    /// Moves the surface to a new area at once, e.g. when the window changes screen.
    func move(to area: CGRect) {
        guard area != self.area else { return }
        self.area = area
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: .zero, size: area.size)
        shape.path = path(nil)
        CATransaction.commit()
        panel.setFrame(area, display: true)
    }

    /// Animates the hole (and optionally the opacity) to a new state. A `nil`
    /// hole is only set once the move is done, since paths morph only between holes.
    func animate(to hole: Hole, opacity: Float? = nil, duration: TimeInterval,
                 timing: CAMediaTimingFunction, completion: @escaping () -> Void) {
        let current = generation
        let toPath = path(hole)
        let fromPath = shape.presentation()?.path ?? shape.path

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                completion()
            }
        }
        let pathAnimation = CABasicAnimation(keyPath: "path")
        pathAnimation.fromValue = fromPath
        pathAnimation.toValue = toPath
        pathAnimation.duration = duration
        pathAnimation.timingFunction = timing
        shape.path = toPath
        shape.add(pathAnimation, forKey: "path")

        if let opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? shape.opacity
            fade.toValue = opacity
            fade.duration = duration
            fade.timingFunction = timing
            shape.opacity = opacity
            shape.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    /// Changes the hole at once, e.g. to move a closed hole to where the window
    /// jumped, or to close it for good once a move is done.
    func set(hole: Hole?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.removeAllAnimations()
        shape.path = path(hole)
        CATransaction.commit()
    }

    /// Fades the surface out from wherever it is, then takes it off screen.
    func fadeOut(duration: TimeInterval) {
        guard isShown else { return }
        let current = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.end(run: current) }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shape.presentation()?.opacity ?? shape.opacity
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.opacity = 0
        shape.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    /// Takes the surface off screen, or with `run` only if no newer one has begun since.
    func end(run: Int? = nil) {
        if let run, run != generation { return }
        generation += 1
        panel.orderOut(nil)
    }

    // MARK: Holes

    struct Hole {
        var rect: CGRect
        var radius: CGFloat
    }

    /// Corner radius of a hole that frames a window. At least as large as any
    /// system window's, so the curtain also covers the window's transparent
    /// corners; the thin overlap with the window itself is only on screen
    /// while the curtain moves.
    static var windowRadius: CGFloat {
        if #available(macOS 26, *) { 32 } else { 12 }
    }

    /// A hole that frames the window.
    static func hole(around window: CGRect) -> Hole { Hole(rect: window, radius: windowRadius) }

    /// A hole shrunk to a point in the middle of `rect`: the curtain covers everything.
    static func closed(at rect: CGRect) -> Hole {
        Hole(rect: CGRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2), radius: 0.5)
    }

    /// A hole larger than the area: no curtain is visible.
    static func open(around area: CGRect) -> Hole {
        Hole(rect: area.insetBy(dx: -area.width * 0.15, dy: -area.height * 0.15), radius: 120)
    }

    /// The area with the hole cut out. Every hole is a rounded rectangle with a
    /// radius above zero, so all paths with a hole have the same structure and
    /// Core Animation can morph between them.
    private func path(_ hole: Hole?) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: area.size))
        guard let hole else { return path }
        let local = hole.rect.offsetBy(dx: -area.minX, dy: -area.minY)
        let radius = max(0.5, min(hole.radius, local.width / 2 - 0.01, local.height / 2 - 0.01))
        path.addRoundedRect(in: local, cornerWidth: radius, cornerHeight: radius)
        return path
    }
}

/// The curtain at rest: one panel at normal window level, directly behind the
/// focused window. Everything below it is dimmed, while the window, its rounded
/// corners and its shadow sit on top, so there's no hole to keep in step with
/// the window. Clicks on it turn focus off.
final class Backdrop: CurtainSurface {
    /// The window the backdrop is kept behind.
    var windowID: CGWindowID?

    init(onClick: @escaping () -> Void) {
        super.init(level: .normal, onClick: onClick)
    }

    /// Puts the backdrop directly behind the window again. Needed whenever the
    /// window's app comes forward, since that reorders its windows.
    func orderBehindWindow() {
        guard isShown, let windowID else { return }
        panel.order(.below, relativeTo: Int(windowID))
    }

    /// Shows the backdrop behind the window in its starting state. Without a
    /// window to go behind it stays hidden, rather than cover the window.
    func begin(in area: CGRect, color: NSColor, opacity: Float, hole: Hole?) {
        prepare(in: area, color: color, opacity: opacity, hole: hole)
        guard let windowID else { return panel.orderOut(nil) }
        panel.order(.below, relativeTo: Int(windowID))
    }
}

/// Plays the curtain's moves that have to cover the window itself, so it can
/// jump unseen: one panel above everything, with the curtain as a shape. The
/// `Backdrop` takes over once it's done, since it lets clicks reach the window.
final class CurtainTransition: CurtainSurface {
    init() {
        super.init(level: .floating, onClick: nil)
    }

    /// Puts the curtain on screen in its starting state, above everything.
    func begin(in area: CGRect, color: NSColor, opacity: Float, hole: Hole) {
        prepare(in: area, color: color, opacity: opacity, hole: hole)
        panel.orderFrontRegardless()
    }
}

final class CurtainPanel: NSPanel {
    init(onClick: (() -> Void)?) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        contentView = ClickView(onClick: onClick)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickView: NSView {
    private let onClick: (() -> Void)?

    init(onClick: (() -> Void)?) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
