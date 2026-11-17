import CoreGraphics
import Foundation
import Observation
import QuartzCore
import UIKit

/// Turns a held thumb's travel into arrow keys by following it. Travel is measured along one axis from where the
/// current run began: the hold, or the last place the thumb turned back. Within the precise reach one arrow goes per
/// row (or column) of travel, so the count is the distance and nothing is timed. Past the reach, and near the screen's
/// edge while still heading toward it, arrows repeat, faster the further the thumb goes. Turning back stops a repeat
/// at once and steps precisely again from the turn. Points are in window coordinates.
struct GhosttyKeyboardCursorTrackpad {
    enum Direction: Equatable, CaseIterable {
        case left
        case right
        case up
        case down
    }

    enum Metrics {
        /// Thumb travel per arrow: a row going up or down, a column going sideways.
        static let rowTravel: CGFloat = 16
        static let columnTravel: CGFloat = 7.8
        /// How far a run steps precisely before arrows repeat: six rows.
        static let preciseReach: CGFloat = 96
        /// Travel from the hold before the axis is chosen.
        static let axisLock: CGFloat = 6
        /// Travel from a run's start before it has a direction.
        static let runStart: CGFloat = 4
        /// Coming back this far from a run's furthest point turns it around.
        static let turnBack: CGFloat = 8
        /// The recent path that decides a switch of axis, and how much of it the other axis must make up.
        static let axisSwitchPath: CGFloat = 28
        static let axisSwitchTravel: CGFloat = 14
        /// Repeats go 4 a second where repeating starts, up to 15 a second this much further.
        static let repeatRange: CGFloat = 60
        static let slowestRepeatRate: Double = 4
        static let fastestRepeatRate: Double = 15
        static let firstRepeatDelay: TimeInterval = 0.12
        static let firstEdgeRepeatDelay: TimeInterval = 0.15
        /// The bands at the screen's edges that repeat, never starting closer than `edgeMinimumTravel` to the hold.
        static let verticalEdgeBand: CGFloat = 56
        static let horizontalEdgeBand: CGFloat = 32
        static let edgeMinimumTravel: CGFloat = 24
    }

    /// What one move of the thumb sends.
    struct Step: Equatable {
        var direction: Direction?
        var arrows = 0
        /// Repeating began with this move: past the precise reach, or into an edge band.
        var startsRepeating = false
    }

    private struct Run {
        /// Where the run began, along the axis, relative to the hold.
        var anchor: CGFloat = 0
        /// +1 toward down or right, -1 toward up or left, 0 before the run has a direction.
        var sign: CGFloat = 0
        /// The furthest the run has gone.
        var peak: CGFloat = 0
        /// Arrows the run has sent by travel.
        var sent = 0
    }

    private struct Repetition {
        enum Cause { case reach, edge }

        var cause: Cause
        var direction: Direction
        /// 0 to 1: how deep past where repeating starts, which sets the rate.
        var depth: CGFloat
        var nextAt: TimeInterval
    }

    private let origin: CGPoint
    /// The area whose top and bottom (or sides) are the screen's edges; nil leaves edge repeats out.
    private let edges: CGRect?
    private var last: CGPoint
    private var isVertical: Bool?
    private var recentPath: [CGVector] = []
    private var run = Run()
    private var repetition: Repetition?
    /// The way the arrows are going.
    private(set) var direction: Direction?
    /// 0 to 1: how far the current run has gone toward repeating.
    private(set) var progress: CGFloat = 0

    init(at point: CGPoint, edges: CGRect?) {
        origin = point
        last = point
        self.edges = edges
    }

    /// The thumb has moved far enough to choose an axis.
    var hasMoved: Bool { isVertical != nil }

    var isRepeating: Bool { repetition != nil }

    mutating func move(to point: CGPoint, at time: TimeInterval) -> Step {
        let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
        guard delta.dx != 0 || delta.dy != 0 else { return Step() }
        last = point
        rememberPath(delta)

        var step = followRun(to: point, at: time)
        if updateEdgeRepeat(at: time) { step.startsRepeating = true }
        if let repetition { direction = repetition.direction }
        return step
    }

    /// The arrow a repeat sends at `time`, if one is due.
    mutating func repeatArrow(at time: TimeInterval) -> Direction? {
        guard var repetition, time >= repetition.nextAt else { return nil }
        let rate = Metrics.slowestRepeatRate
            + (Metrics.fastestRepeatRate - Metrics.slowestRepeatRate) * Double(repetition.depth)
        repetition.nextAt = time + 1 / rate
        self.repetition = repetition
        return repetition.direction
    }

    private mutating func rememberPath(_ delta: CGVector) {
        recentPath.append(delta)
        var length: CGFloat = 0
        for index in recentPath.indices.reversed() {
            length += hypot(recentPath[index].dx, recentPath[index].dy)
            if length > Metrics.axisSwitchPath {
                recentPath.removeFirst(index)
                break
            }
        }
    }

    private mutating func followRun(to point: CGPoint, at time: TimeInterval) -> Step {
        if let isVertical {
            // A clear turn onto the other axis switches it, except while repeating past the reach.
            if repetition?.cause != .reach {
                let sideways = recentPath.reduce(0) { $0 + abs($1.dx) }
                let upright = recentPath.reduce(0) { $0 + abs($1.dy) }
                if isVertical, sideways > 2 * upright, sideways >= Metrics.axisSwitchTravel {
                    self.isVertical = false
                    run = Run(anchor: point.x - origin.x, peak: point.x - origin.x)
                } else if !isVertical, upright > 2 * sideways, upright >= Metrics.axisSwitchTravel {
                    self.isVertical = true
                    run = Run(anchor: point.y - origin.y, peak: point.y - origin.y)
                }
            }
        } else {
            let travel = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
            guard hypot(travel.dx, travel.dy) >= Metrics.axisLock else { return Step() }
            isVertical = abs(travel.dy) >= abs(travel.dx)
        }
        guard let isVertical else { return Step() }

        let position = isVertical ? point.y - origin.y : point.x - origin.x
        let travelPerArrow = isVertical ? Metrics.rowTravel : Metrics.columnTravel
        let forward: Direction = isVertical ? .down : .right
        let backward: Direction = isVertical ? .up : .left

        if run.sign == 0 {
            let travel = position - run.anchor
            guard abs(travel) >= Metrics.runStart else {
                progress = 0
                return Step()
            }
            run.sign = travel > 0 ? 1 : -1
            run.peak = position
        }

        let retreat = (position - run.peak) * run.sign
        if repetition?.cause == .reach {
            if retreat > 0 { run.peak = position }
            let travel = (position - run.anchor) * run.sign
            if retreat >= -Metrics.turnBack, travel > Metrics.preciseReach {
                repetition?.depth = min(1, (travel - Metrics.preciseReach) / Metrics.repeatRange)
                progress = 1
                return Step()
            }
            // Turned back while repeating: the repeat stops at once, and stepping is precise again from the turn.
            repetition = nil
            turnBack(at: position)
        } else if retreat < -Metrics.turnBack {
            turnBack(at: position)
        } else if retreat > 0 {
            run.peak = position
        }

        let heading = run.sign > 0 ? forward : backward
        let travel = max(0, (position - run.anchor) * run.sign)
        direction = heading
        var step = Step(direction: heading)
        if travel > Metrics.preciseReach {
            // The rows of the reach not yet sent go first, then the repeat takes over.
            step.arrows = sendByTravel(upTo: Int(Metrics.preciseReach / travelPerArrow))
            repetition = Repetition(
                cause: .reach,
                direction: heading,
                depth: min(1, (travel - Metrics.preciseReach) / Metrics.repeatRange),
                nextAt: time + Metrics.firstRepeatDelay
            )
            step.startsRepeating = true
            progress = 1
            return step
        }
        step.arrows = sendByTravel(upTo: Int(travel / travelPerArrow))
        progress = min(1, travel / Metrics.preciseReach)
        return step
    }

    private mutating func sendByTravel(upTo target: Int) -> Int {
        let arrows = max(0, target - run.sent)
        run.sent += arrows
        return arrows
    }

    private mutating func turnBack(at position: CGFloat) {
        run = Run(anchor: run.peak, sign: -run.sign, peak: position)
    }

    /// Held in an edge band while the run heads toward that edge, arrows keep coming, as iOS scrolls when a
    /// selection reaches the screen's edge. Returns whether this repeat began now.
    private mutating func updateEdgeRepeat(at time: TimeInterval) -> Bool {
        guard repetition?.cause != .reach else { return false }
        guard let (direction, depth) = edgeBand(), direction == runDirection else {
            if repetition?.cause == .edge { repetition = nil }
            return false
        }
        if let current = repetition, current.direction == direction {
            repetition?.depth = depth
            return false
        }
        repetition = Repetition(
            cause: .edge,
            direction: direction,
            depth: depth,
            nextAt: time + Metrics.firstEdgeRepeatDelay
        )
        return true
    }

    private var runDirection: Direction? {
        guard let isVertical, run.sign != 0 else { return nil }
        if isVertical { return run.sign > 0 ? .down : .up }
        return run.sign > 0 ? .right : .left
    }

    /// The edge band the thumb is in, and how deep, along the run's axis.
    private func edgeBand() -> (Direction, CGFloat)? {
        guard let edges, let isVertical else { return nil }
        let band = isVertical ? Metrics.verticalEdgeBand : Metrics.horizontalEdgeBand
        let (low, high, at, start) = isVertical
            ? (edges.minY, edges.maxY, last.y, origin.y)
            : (edges.minX, edges.maxX, last.x, origin.x)
        let highStart = max(high - band, start + Metrics.edgeMinimumTravel)
        let lowStart = min(low + band, start - Metrics.edgeMinimumTravel)
        if at > highStart {
            return (isVertical ? .down : .right, min(1, (at - highStart) / max(1, high - highStart)))
        }
        if at < lowStart {
            return (isVertical ? .up : .left, min(1, (lowStart - at) / max(1, lowStart - low)))
        }
        return nil
    }
}

extension GhosttyKeyboardCursorTrackpad {
    /// What the stick shows. Hidden when `anchor` is nil.
    struct FeedbackState: Equatable {
        enum Anchor: Equatable {
            /// A hold on the terminal, where the thumb was, in window coordinates.
            case thumb(CGPoint)
            /// A hold on the space bar, which reports no thumb position.
            case keyboard
        }

        var anchor: Anchor?
        var direction: Direction?
        var progress: CGFloat = 0
        var isRepeating = false
        /// Counts the arrows sent since the hold, so each one can be shown as it goes.
        var arrowsSent = 0
        /// Set after a drag is let go: the stick fades out over this long, the re-grip window.
        var fadeOut: TimeInterval?

        var isVisible: Bool { anchor != nil }

        static let hidden = FeedbackState()
    }
}

/// The stick's state, observed only by the stick, so a drag redraws the stick and nothing else.
@MainActor
@Observable
final class GhosttyKeyboardCursorTrackpadFeedback {
    fileprivate(set) var state = GhosttyKeyboardCursorTrackpad.FeedbackState.hidden
}

/// Owns the one arrow-key gesture: its sending, repeats, haptics, the re-grip window after a terminal drag, and
/// the stick's state.
@MainActor
final class GhosttyKeyboardCursorTrackpadDriver {
    enum Source: Equatable {
        case terminal
        case spaceBar
    }

    enum Ending: Equatable {
        /// The gesture sent arrows, or tried to.
        case steered
        /// Nothing was sent: a terminal hold left in place goes on to select, as before.
        case stationary
        /// A touch inside the re-grip window lifted without moving: it ends the window and does nothing else.
        case endedRegrip
    }

    enum HapticCue: Equatable {
        case holdStarted
        case arrowSent
        case repeatStarted
    }

    /// After a terminal drag that sent arrows is let go, a new touch within this long carries on without the hold.
    static let regripWindow: TimeInterval = 1
    private static let arrowHapticSpacing: TimeInterval = 0.03

    let feedback = GhosttyKeyboardCursorTrackpadFeedback()

    private let playHaptic: (HapticCue) -> Void
    private weak var owner: AnyObject?
    private var source = Source.terminal
    private var edges: CGRect?
    private var sendKeyEvent: ((GhosttySurfaceKeyEvent) -> Bool)?
    /// Where the stick sits, from the hold until the gesture and its re-grip window end.
    private var anchor: FeedbackState.Anchor?
    /// Present while a touch is down.
    private var trackpad: GhosttyKeyboardCursorTrackpad?
    private var arrowsSent = 0
    private var didSteer = false
    /// The touch down is a re-grip: lifted before it moves, it is a tap that ends the window.
    private var isRegripTouch = false
    private var regripDeadline: Task<Void, Never>?
    private var regripUntil: TimeInterval?
    private var repeatLink: CADisplayLink?
    private var lastArrowHapticAt: TimeInterval = -.infinity

    init(
        playHaptic: @escaping (HapticCue) -> Void = { cue in
            switch cue {
            case .holdStarted: Haptic.tap(.soft)
            case .arrowSent: Haptic.selection()
            case .repeatStarted: Haptic.tap(.medium)
            }
        }
    ) {
        self.playHaptic = playHaptic
    }

    /// The edges a terminal drag repeats at: the window, below its top safe area.
    static func edges(of window: UIWindow) -> CGRect {
        window.bounds.inset(by: UIEdgeInsets(top: window.safeAreaInsets.top, left: 0, bottom: 0, right: 0))
    }

    /// Starts a gesture at `point`, in window coordinates.
    func begin(
        owner: AnyObject,
        at point: CGPoint,
        edges: CGRect?,
        source: Source,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool
    ) {
        cancelCurrentGesture()
        self.owner = owner
        self.source = source
        self.edges = edges
        self.sendKeyEvent = sendKeyEvent
        anchor = source == .terminal ? .thumb(point) : .keyboard
        trackpad = GhosttyKeyboardCursorTrackpad(at: point, edges: edges)
        publish()
        playHaptic(.holdStarted)
    }

    /// Whether a touch now, on `owner`, carries on the drag just let go.
    func canRegrip(owner: AnyObject, at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        self.owner === owner && trackpad == nil && regripUntil.map { now < $0 } == true
    }

    /// Carries on the drag from a touch inside the re-grip window: the stick stays where it is, and the arrows go
    /// to the same terminal.
    func regrip(owner: AnyObject, at point: CGPoint, now: TimeInterval = CACurrentMediaTime()) {
        guard canRegrip(owner: owner, at: now) else { return }
        regripDeadline?.cancel()
        regripDeadline = nil
        regripUntil = nil
        isRegripTouch = true
        trackpad = GhosttyKeyboardCursorTrackpad(at: point, edges: edges)
        publish()
    }

    func update(owner: AnyObject, at point: CGPoint, now: TimeInterval = CACurrentMediaTime()) {
        guard self.owner === owner, var trackpad else { return }
        let step = trackpad.move(to: point, at: now)
        self.trackpad = trackpad
        if let direction = step.direction {
            for _ in 0..<step.arrows {
                guard emit(direction, now: now) else { return }
            }
        }
        // After the rows that finish the precise reach, so the tap marks the repeat taking over.
        if step.startsRepeating { playHaptic(.repeatStarted) }
        updateRepeatLink()
        publish()
    }

    /// Sends the repeat's arrow if one is due.
    func repeatTick(at now: TimeInterval) {
        guard var trackpad, let direction = trackpad.repeatArrow(at: now) else { return }
        self.trackpad = trackpad
        guard emit(direction, now: now) else { return }
        publish()
    }

    /// Ends the touch. A non-owner gets nil, so a terminal hold it doesn't own still goes on to select.
    @discardableResult
    func end(owner: AnyObject, now: TimeInterval = CACurrentMediaTime()) -> Ending? {
        guard self.owner === owner, let trackpad else { return nil }
        if isRegripTouch, !trackpad.hasMoved {
            cancelCurrentGesture()
            return .endedRegrip
        }
        guard didSteer else {
            cancelCurrentGesture()
            return .stationary
        }
        guard source == .terminal else {
            cancelCurrentGesture()
            return .steered
        }
        self.trackpad = nil
        isRegripTouch = false
        updateRepeatLink()
        regripUntil = now + Self.regripWindow
        publish()
        regripDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.regripWindow))
            guard !Task.isCancelled, let self, self.trackpad == nil else { return }
            self.cancelCurrentGesture()
        }
        return .steered
    }

    /// Ends the gesture, or the re-grip window after it, without anything further.
    @discardableResult
    func cancel(owner: AnyObject) -> Bool {
        guard self.owner === owner else { return false }
        cancelCurrentGesture()
        return true
    }

    private typealias FeedbackState = GhosttyKeyboardCursorTrackpad.FeedbackState

    private func emit(_ direction: GhosttyKeyboardCursorTrackpad.Direction, now: TimeInterval) -> Bool {
        didSteer = true
        guard sendKeyEvent?(GhosttySurfaceKeyEvent(keyCode: direction.keyCode)) == true else {
            cancelCurrentGesture()
            return false
        }
        arrowsSent += 1
        if now - lastArrowHapticAt >= Self.arrowHapticSpacing {
            lastArrowHapticAt = now
            playHaptic(.arrowSent)
        }
        return true
    }

    /// The stick's state, built from the gesture's own: while the re-grip window is open it fades.
    private func publish() {
        let state = FeedbackState(
            anchor: anchor,
            direction: trackpad?.direction,
            progress: trackpad?.progress ?? 0,
            isRepeating: trackpad?.isRepeating ?? false,
            arrowsSent: arrowsSent,
            fadeOut: regripUntil == nil ? nil : Self.regripWindow
        )
        guard feedback.state != state else { return }
        feedback.state = state
    }

    private func updateRepeatLink() {
        let repeating = trackpad?.isRepeating == true
        if repeating, repeatLink == nil {
            let link = CADisplayLink(target: RepeatLinkTarget(self), selector: #selector(RepeatLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            repeatLink = link
        } else if !repeating, let link = repeatLink {
            link.invalidate()
            repeatLink = nil
        }
    }

    private func cancelCurrentGesture() {
        trackpad = nil
        updateRepeatLink()
        regripDeadline?.cancel()
        regripDeadline = nil
        regripUntil = nil
        isRegripTouch = false
        owner = nil
        sendKeyEvent = nil
        edges = nil
        anchor = nil
        arrowsSent = 0
        didSteer = false
        publish()
    }
}

/// CADisplayLink holds its target strongly; this keeps the driver out of that cycle.
private final class RepeatLinkTarget {
    private weak var driver: GhosttyKeyboardCursorTrackpadDriver?

    init(_ driver: GhosttyKeyboardCursorTrackpadDriver) {
        self.driver = driver
    }

    @MainActor
    @objc func tick(_ link: CADisplayLink) {
        guard let driver else {
            link.invalidate()
            return
        }
        driver.repeatTick(at: link.timestamp)
    }
}

private extension GhosttyKeyboardCursorTrackpad.Direction {
    var keyCode: GhosttySurfaceKeyEvent.KeyCode {
        switch self {
        case .up: .arrowUp
        case .down: .arrowDown
        case .left: .arrowLeft
        case .right: .arrowRight
        }
    }
}
