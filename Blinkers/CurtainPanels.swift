import AppKit

/// Four borderless panels that frame the focused window: left and right span the
/// full height of the area, top and bottom fill the gaps above and below the window.
///
/// A fifth panel sits directly behind the window and fills its rounded corners,
/// which the frame panels can't reach without covering the window itself.
final class CurtainPanels {
    private let panels: [CurtainPanel]
    private let corners = CornerPanel()
    private var allPanels: [NSPanel] { panels + [corners] }
    private var opacity: CGFloat = 1
    private(set) var isShown = false
    /// Bumped on every show/hide so a finished fade-out can't hide a newer show.
    private var generation = 0
    /// The window the corner panel is kept behind.
    var windowID: CGWindowID?

    init(onClick: @escaping () -> Void) {
        panels = (0..<4).map { _ in CurtainPanel(onClick: onClick) }
    }

    func setAppearance(color: NSColor, opacity: Double) {
        self.opacity = CGFloat(opacity / 100)
        panels.forEach { $0.backgroundColor = color }
        corners.color = color
        if isShown { allPanels.forEach { $0.alphaValue = self.opacity } }
    }

    /// Lays the panels out around `window`, covering the rest of `area`.
    func layout(around window: CGRect, in area: CGRect) {
        for (panel, frame) in zip(panels, Self.frames(around: window, in: area)) {
            if frame.isEmpty {
                panel.orderOut(nil)
            } else {
                panel.setFrame(frame, display: true)
                if isShown, !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
        corners.setFrame(window.intersection(area).integral, display: true)
    }

    /// Puts the corner panel directly behind the window again. Needed whenever
    /// the window's app comes forward, since that reorders its windows.
    func orderCornersBehindWindow() {
        guard isShown, let windowID, !corners.frame.isEmpty else { return corners.orderOut(nil) }
        corners.order(.below, relativeTo: Int(windowID))
    }

    /// Left, right, top and bottom frames that together cover `area` except
    /// `window`. Pieces with nothing to cover come back empty.
    static func frames(around window: CGRect, in area: CGRect) -> [CGRect] {
        var hole = window.intersection(area)
        if hole.isNull { hole = CGRect(x: area.midX, y: area.midY, width: 0, height: 0) }

        return [
            CGRect(x: area.minX, y: area.minY, width: hole.minX - area.minX, height: area.height),
            CGRect(x: hole.maxX, y: area.minY, width: area.maxX - hole.maxX, height: area.height),
            CGRect(x: hole.minX, y: hole.maxY, width: hole.width, height: area.maxY - hole.maxY),
            CGRect(x: hole.minX, y: area.minY, width: hole.width, height: hole.minY - area.minY),
        ].map { frame in
            let frame = frame.integral
            return frame.width < 1 || frame.height < 1 ? .zero : frame
        }
    }

    /// Shows the curtain. Without `fading` it appears at full strength at once,
    /// which is how a `CurtainTransition` hands over when it finishes.
    func show(around window: CGRect, in area: CGRect, fading: Bool = true) {
        generation += 1
        let wasShown = isShown
        isShown = true
        if !wasShown { allPanels.forEach { $0.alphaValue = fading ? 0 : opacity } }
        layout(around: window, in: area)
        orderCornersBehindWindow()
        guard fading else {
            allPanels.forEach { $0.alphaValue = opacity }
            return
        }

        let target = opacity
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Settings.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            allPanels.forEach { $0.animator().alphaValue = target }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Settings.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            allPanels.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.allPanels.forEach { $0.orderOut(nil) }
            }
        }
    }

    /// Immediate teardown, used when the app quits.
    func hideImmediately() {
        isShown = false
        generation += 1
        allPanels.forEach { $0.orderOut(nil) }
    }
}

/// Plays the curtain's moves: one panel above everything with the curtain as a
/// shape, so the hole around the window can shrink, grow and travel smoothly.
/// Core Animation runs it in the window server at the display's frame rate.
///
/// The four `CurtainPanels` take over once it's done, since they let clicks
/// reach the window and fill its corners from behind.
final class CurtainTransition {
    private let panel: NSPanel
    private let shape = CAShapeLayer()
    private var area: CGRect = .zero
    private var generation = 0

    /// Corner radius of a hole that frames a window. Smaller than any system
    /// window's, so the hole never cuts into the window itself.
    static let windowRadius: CGFloat = 10

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear

        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        shape.fillRule = .evenOdd
        view.layer?.addSublayer(shape)
        panel.contentView = view
    }

    // MARK: Holes

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

    struct Hole {
        var rect: CGRect
        var radius: CGFloat
    }

    // MARK: Playing

    /// Puts the curtain on screen in its starting state, above the real panels.
    func begin(in area: CGRect, color: NSColor, opacity: Float, hole: Hole) {
        generation += 1
        self.area = area
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: .zero, size: area.size)
        shape.fillColor = color.cgColor
        shape.opacity = opacity
        shape.path = path(hole)
        CATransaction.commit()

        panel.setFrame(area, display: true)
        panel.orderFrontRegardless()
    }

    /// Animates the hole (and optionally the opacity) to a new state.
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

    /// Changes the hole at once, e.g. to move a closed hole to where the window jumped.
    func set(hole: Hole) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.removeAllAnimations()
        shape.path = path(hole)
        CATransaction.commit()
    }

    /// Identifies the current run, so a late `end(run:)` can't end a newer one.
    var run: Int { generation }

    /// Ends the transition, or with `run` only if no newer one has begun since.
    func end(run: Int? = nil) {
        if let run, run != generation { return }
        generation += 1
        panel.orderOut(nil)
    }

    /// The curtain area with the hole cut out. Every hole is a rounded rectangle
    /// with a radius above zero, so all paths have the same structure and
    /// Core Animation can morph between them.
    private func path(_ hole: Hole) -> CGPath {
        let local = hole.rect.offsetBy(dx: -area.minX, dy: -area.minY)
        let radius = max(0.5, min(hole.radius, local.width / 2 - 0.01, local.height / 2 - 0.01))
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: area.size))
        path.addRoundedRect(in: local, cornerWidth: radius, cornerHeight: radius)
        return path
    }
}

/// Sits at normal window level right behind the focused window and paints the
/// curtain color everywhere except a rounded rectangle. The window covers that
/// rectangle, so only its transparent corners show the color.
///
/// The radius is at least as large as any system window's, so the painted area
/// always includes the real corners whatever radius the app uses. The thin
/// overlap with the window's own corner area is hidden behind the window.
private final class CornerPanel: NSPanel {
    var color: NSColor = .black {
        didSet { contentView?.needsDisplay = true }
    }

    static var radius: CGFloat {
        if #available(macOS 26, *) { 32 } else { 12 }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        backgroundColor = .clear
        alphaValue = 0
        contentView = CornerView { [unowned self] in self.color }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CornerView: NSView {
    private let color: () -> NSColor

    init(color: @escaping () -> NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(CornerPanel.radius, bounds.width / 2, bounds.height / 2)
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius))
        path.windingRule = .evenOdd
        color().setFill()
        path.fill()
    }
}

private final class CurtainPanel: NSPanel {
    init(onClick: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .black
        alphaValue = 0
        contentView = ClickView(onClick: onClick)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
