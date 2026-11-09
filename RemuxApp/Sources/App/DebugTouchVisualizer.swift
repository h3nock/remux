#if DEBUG || REMUX_LIVE_UI_TESTING
import UIKit

/// Draws every touch the app receives, for demo recordings, with as little as reads at a glance: a soft circle under
/// the finger that eases after it, a ring that fills while it holds still (complete when the terminal's long-press
/// fires), and a tapered trail that shows which way it moved. A tap is the circle alone, shown briefly. The drawing
/// sits in a window above everything else and takes no touches, so the app behaves exactly as without it, and a screen
/// recording shows what the finger did whether a test or a person is driving.
///
/// Off unless the launch environment has REMUX_DEBUG_SHOW_TOUCHES=1. With REMUX_DEBUG_TOUCH_LOG=<path>, each
/// touch's start and end are appended there as one JSON object a line (wall-clock seconds and the point), so a
/// recording can be lined up with its touches.
@MainActor
final class DebugTouchVisualizer {
    private static var shared: DebugTouchVisualizer?

    static func installIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard shared == nil, environment["REMUX_DEBUG_SHOW_TOUCHES"] == "1" else { return }
        shared = DebugTouchVisualizer(logPath: environment["REMUX_DEBUG_TOUCH_LOG"])
    }

    private let log: FileHandle?
    private var overlay: OverlayWindow?
    /// Fingers that are down, and spots whose finger has lifted but which are still fading or pulling in their trail.
    private var down: [ObjectIdentifier: TouchSpot] = [:]
    private var lifted: [TouchSpot] = []
    private var observer: NSObjectProtocol?
    private var frames: CADisplayLink?
    private lazy var frameTarget = FrameTarget { [weak self] in self?.frame() }

    private init(logPath: String?) {
        if let logPath {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            log = FileHandle(forWritingAtPath: logPath)
        } else {
            log = nil
        }
        // Every window the app shows, now and later: the main one and the banner's. A window appearing is the
        // cue to look over all of them, so the notification itself never crosses into the main actor.
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { DebugTouchVisualizer.shared?.watchAllWindows() }
        }
    }

    private func watchAllWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { watch(window) }
        }
    }

    private func watch(_ window: UIWindow) {
        guard !(window is OverlayWindow),
              !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchObserver })
        else { return }
        window.addGestureRecognizer(TouchObserver(visualizer: self))
        if overlay == nil, let scene = window.windowScene {
            let overlay = OverlayWindow(windowScene: scene)
            overlay.isHidden = false
            self.overlay = overlay
        }
    }

    fileprivate func touchesBegan(_ touches: Set<UITouch>) {
        guard let overlay else { return }
        let now = CACurrentMediaTime()
        for touch in touches {
            let point = touch.location(in: overlay)
            let spot = TouchSpot(at: point, time: now, bounds: overlay.bounds)
            overlay.layer.addSublayer(spot)
            down[ObjectIdentifier(touch)] = spot
            write("began", point)
        }
        runFrames()
    }

    fileprivate func touchesMoved(_ touches: Set<UITouch>) {
        guard let overlay else { return }
        for touch in touches {
            down[ObjectIdentifier(touch)]?.target = touch.location(in: overlay)
        }
    }

    fileprivate func touchesEnded(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let overlay else { return }
        let now = CACurrentMediaTime()
        for touch in touches {
            let point = touch.location(in: overlay)
            guard let spot = down.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            spot.target = point
            spot.lift(at: now)
            lifted.append(spot)
            write(cancelled ? "cancelled" : "ended", point)
        }
    }

    /// Once a frame while anything is on screen: each spot eases toward its finger, ages its trail and runs its
    /// ring and fade; spots that have finished are removed and the frames stop when none are left.
    private func frame() {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for spot in down.values { spot.step(at: now) }
        lifted.removeAll { spot in
            let done = !spot.step(at: now)
            if done { spot.removeFromSuperlayer() }
            return done
        }
        CATransaction.commit()
        if down.isEmpty, lifted.isEmpty {
            frames?.invalidate()
            frames = nil
        }
    }

    private func runFrames() {
        guard frames == nil else { return }
        let link = CADisplayLink(target: frameTarget, selector: #selector(FrameTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        frames = link
    }

    private func write(_ phase: String, _ point: CGPoint) {
        guard let log else { return }
        let line = String(
            format: "{\"t\":%.3f,\"phase\":\"%@\",\"x\":%.1f,\"y\":%.1f}\n",
            Date().timeIntervalSince1970, phase, point.x, point.y
        )
        log.write(Data(line.utf8))
    }
}

/// The display link's target: CADisplayLink calls an Objective-C selector, which the visualizer itself has none of.
@MainActor
private final class FrameTarget: NSObject {
    private let onFrame: () -> Void
    init(onFrame: @escaping () -> Void) { self.onFrame = onFrame }
    @objc func tick() { onFrame() }
}

/// The window the touches are drawn in: above everything, transparent, never key, and never hit by a touch.
private final class OverlayWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 100)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        rootViewController = UIViewController()
        rootViewController?.view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Watches a window's touches without taking part: it never recognizes, never delays or cancels a touch, and
/// can't be prevented by the app's own gestures (a scroll view's pan would otherwise cut a drag's trail short).
private final class TouchObserver: UIGestureRecognizer {
    private weak var visualizer: DebugTouchVisualizer?

    init(visualizer: DebugTouchVisualizer) {
        self.visualizer = visualizer
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        visualizer?.touchesBegan(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        visualizer?.touchesMoved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        visualizer?.touchesEnded(touches, cancelled: false)
        finishIfIdle(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        visualizer?.touchesEnded(touches, cancelled: true)
        finishIfIdle(event)
    }

    /// Once no finger is down the recognizer resets, ready for the next touch, without ever having recognized.
    private func finishIfIdle(_ event: UIEvent) {
        let down = (event.allTouches ?? []).contains { $0.phase != .ended && $0.phase != .cancelled }
        if !down { state = .failed }
    }
}

/// One finger, drawn frame by frame: the soft circle, the ring that fills while it holds still, and the tapered
/// trail it leaves when it moves.
private final class TouchSpot: CALayer {
    private enum Style {
        static let diameter: CGFloat = 44
        static let fill = UIColor.white.withAlphaComponent(0.32)
        /// White edge with a thin dark rim outside it, so the circle shows on light screens as well as dark ones.
        static let edge = UIColor.white.withAlphaComponent(0.7)
        static let rim = UIColor.black.withAlphaComponent(0.22)
        static let ringRadius: CGFloat = 28
        static let ringWidth: CGFloat = 3
        /// The trail: widest just behind the circle, a hairline at its end, fading to nothing along the way.
        static let trailHead: CGFloat = 22
        static let trailTail: CGFloat = 1.5
        static let trailAlpha: CGFloat = 0.34
    }

    private enum Timing {
        static let appear: TimeInterval = 0.12
        /// The ring waits out a tap, then fills to complete when the terminal's long-press fires (0.45 s).
        static let ringStart: TimeInterval = 0.12
        static let ringComplete: TimeInterval = 0.45
        /// The trail keeps the last moments of movement; a fling's trail pulls into the circle over this time.
        static let trailSpan: TimeInterval = 0.22
        /// A tap lasts a few hundredths of a second; its circle stays up this long so a recording shows it.
        static let tapHold: TimeInterval = 0.25
        static let fade: TimeInterval = 0.28
        /// How quickly the ring fades when a hold turns into a drag, so it never vanishes in one frame.
        static let settle: TimeInterval = 0.08
    }

    /// Movement inside this distance still counts as holding still.
    private static let stillTolerance: CGFloat = 8
    /// How much of the way to the finger the circle moves each 60th of a second: close enough to feel attached,
    /// smooth enough that the touch stream's steps don't show.
    private static let follow: CGFloat = 0.55

    var target: CGPoint
    private var position_: CGPoint
    private let origin: CGPoint
    private let began: CFTimeInterval
    private var lastFrame: CFTimeInterval
    private var liftedAt: CFTimeInterval?
    private var moved = false
    private var held = false
    private var ringProgress: Double = 0
    private var ringShown: Double = 1
    private var trailPoints: [(CGPoint, CFTimeInterval)] = []

    private let circle = CALayer()
    private let rimLayer = CALayer()
    private let ring = CAShapeLayer()
    private let trail = CAGradientLayer()
    private let trailShape = CAShapeLayer()

    init(at point: CGPoint, time: CFTimeInterval, bounds: CGRect) {
        target = point
        position_ = point
        origin = point
        began = time
        lastFrame = time
        super.init()
        frame = bounds

        trail.frame = bounds
        trail.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(Style.trailAlpha).cgColor]
        trailShape.fillColor = UIColor.white.cgColor
        trail.mask = trailShape
        addSublayer(trail)

        let d = Style.diameter
        rimLayer.bounds = CGRect(x: 0, y: 0, width: d + 2, height: d + 2)
        rimLayer.cornerRadius = (d + 2) / 2
        rimLayer.borderColor = Style.rim.cgColor
        rimLayer.borderWidth = 1
        addSublayer(rimLayer)

        circle.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        circle.cornerRadius = d / 2
        circle.backgroundColor = Style.fill.cgColor
        circle.borderColor = Style.edge.cgColor
        circle.borderWidth = 1.5
        circle.shadowColor = UIColor.black.cgColor
        circle.shadowOpacity = 0.25
        circle.shadowRadius = 5
        circle.shadowOffset = .zero
        addSublayer(circle)

        ring.path = UIBezierPath(
            arcCenter: .zero, radius: Style.ringRadius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        ring.fillColor = nil
        ring.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        ring.lineWidth = Style.ringWidth
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.25
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        addSublayer(ring)

        trailPoints = [(point, time)]
        step(at: time)
    }

    override init(layer: Any) {
        let other = layer as? TouchSpot
        target = other?.target ?? .zero
        position_ = other?.position_ ?? .zero
        origin = other?.origin ?? .zero
        began = other?.began ?? 0
        lastFrame = other?.lastFrame ?? 0
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func lift(at time: CFTimeInterval) {
        liftedAt = time
    }

    /// Draws this frame. Returns false once a lifted spot has faded and its trail has pulled in.
    @discardableResult
    func step(at now: CFTimeInterval) -> Bool {
        let dt = max(0, now - lastFrame)
        lastFrame = now
        let pull = 1 - pow(1 - Self.follow, CGFloat(dt * 60))
        position_.x += (target.x - position_.x) * pull
        position_.y += (target.y - position_.y) * pull
        if !moved, hypot(target.x - origin.x, target.y - origin.y) > Self.stillTolerance { moved = true }
        for layer in [circle, rimLayer, ring] { layer.position = position_ }

        // Appearing: grow from 70% and fade in.
        let age = now - began
        let shown = min(1, age / Timing.appear)
        let scale = 0.7 + 0.3 * easeOut(shown)
        var alpha = Float(easeOut(shown))

        // The ring belongs to a long-press only. It fills while the finger is down and holding still, and once
        // full stays with the finger, also while it drags. A tap lifts before it starts, so it never shows; a
        // finger that moves first (a drag) or lifts early leaves the ring where it was, fading.
        let downFor = (liftedAt ?? now) - began
        let abandoned = moved && !held
        if !abandoned {
            ringProgress = clamp((downFor - Timing.ringStart) / (Timing.ringComplete - Timing.ringStart))
            if ringProgress >= 1 { held = true }
        }
        let keepRing = !abandoned && (held || liftedAt == nil)
        ringShown += ((keepRing ? 1 : 0) - ringShown) * (1 - exp(-dt / Timing.settle))
        ring.strokeEnd = CGFloat(easeInOut(ringProgress))

        // The trail follows the circle, keeps the last moments of movement, and keeps ageing after the finger
        // lifts, so a fling's trail pulls into the circle.
        if moved {
            trailPoints.append((position_, now))
            trailPoints.removeAll { now - $0.1 > Timing.trailSpan }
            drawTrail()
        }

        var finished = false
        if let liftedAt {
            let wait = !moved && !held ? max(0, Timing.tapHold - (liftedAt - began)) : 0
            let fading = clamp((now - liftedAt - wait) / Timing.fade)
            alpha *= Float(1 - easeOut(fading))
            finished = fading >= 1 && (!moved || trailPoints.count < 2)
        }
        circle.transform = CATransform3DMakeScale(scale, scale, 1)
        rimLayer.transform = circle.transform
        circle.opacity = alpha
        rimLayer.opacity = alpha
        ring.opacity = Float(ringShown) * alpha
        return !finished
    }

    /// A filled, tapered outline along the trail's points, masked over a gradient that runs from its end
    /// (clear) to the circle (brightest). The trail stops at the circle's edge, its end cut to the circle's
    /// curve, so none of it shows through the circle's translucent fill.
    private func drawTrail() {
        let all = trailPoints.map(\.0)
        let radius = Style.diameter / 2
        guard let head = all.last, let tail = all.first else {
            trailShape.path = nil
            return
        }
        let points = all.filter { hypot($0.x - head.x, $0.y - head.y) > radius + 1 }
        guard let near = points.last else {
            trailShape.path = nil
            return
        }
        // Where the trail meets the circle: two points on its edge, either side of the direction back along the
        // trail, at the angles `back - spread` and `back + spread`.
        let back = atan2(near.y - head.y, near.x - head.x)
        let spread = asin(min(1, Style.trailHead / 2 / radius))
        let meetLow = CGPoint(x: head.x + radius * cos(back - spread), y: head.y + radius * sin(back - spread))

        // `side` is the outline along the normal (the forward direction turned a quarter clockwise on screen),
        // `other` the outline opposite it.
        var side: [CGPoint] = []
        var other: [CGPoint] = []
        let ends = points + [CGPoint(x: head.x + radius * cos(back), y: head.y + radius * sin(back))]
        let last = ends.count - 1
        for (i, p) in ends.enumerated().dropLast() {
            let a = ends[max(0, i - 1)]
            let b = ends[min(last, i + 1)]
            let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let t = CGFloat(i) / CGFloat(max(1, last))
            let half = (Style.trailTail + (Style.trailHead - Style.trailTail) * pow(t, 0.8)) / 2
            side.append(CGPoint(x: p.x + normal.x * half, y: p.y + normal.y * half))
            other.append(CGPoint(x: p.x - normal.x * half, y: p.y - normal.y * half))
        }
        // The normal's side reaches the circle at the lower angle; the outline then follows the circle's edge
        // round to the higher angle, the short way past `back`, and returns along the other side.
        guard let first = side.first else {
            trailShape.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: first)
        for p in side.dropFirst() { path.addLine(to: p) }
        path.addLine(to: meetLow)
        path.addArc(withCenter: head, radius: radius, startAngle: back - spread, endAngle: back + spread, clockwise: true)
        for p in other.reversed() { path.addLine(to: p) }
        path.close()
        trailShape.path = path.cgPath
        let size = bounds.size
        trail.startPoint = CGPoint(x: tail.x / size.width, y: tail.y / size.height)
        trail.endPoint = CGPoint(x: head.x / size.width, y: head.y / size.height)
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}
#endif
