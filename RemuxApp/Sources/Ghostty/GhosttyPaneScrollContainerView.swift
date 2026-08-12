import CoreGraphics
import QuartzCore
import UIKit

struct GhosttyPaneScrollPosition: Equatable {
    let row: UInt64
    let cellOffset: Double

    func approximatelyEquals(_ other: GhosttyPaneScrollPosition?) -> Bool {
        guard let other else { return false }
        return row == other.row && abs(cellOffset - other.cellOffset) < 0.000_001
    }
}

enum GhosttyPaneScrollGeometry {
    static func position(for state: GhosttySurfaceScrollState) -> GhosttyPaneScrollPosition {
        let row = min(state.offset, state.maxRow)
        let cellOffset = row == state.maxRow
            ? 0
            : min(max(state.cellOffset, 0), 0.999_999_999)
        return GhosttyPaneScrollPosition(row: row, cellOffset: cellOffset)
    }

    static func displayViewportSize(for bounds: CGRect) -> CGSize? {
        guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGSize(width: bounds.width, height: bounds.height)
    }

    static func documentHeight(
        viewportHeight: CGFloat,
        cellHeight: CGFloat,
        state: GhosttySurfaceScrollState
    ) -> CGFloat {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return 1 }
        guard cellHeight.isFinite, cellHeight > 0 else { return viewportHeight }

        let gridHeight = CGFloat(state.total) * cellHeight
        let viewportGridHeight = CGFloat(state.len) * cellHeight
        let padding = max(0, viewportHeight - viewportGridHeight)
        return max(viewportHeight, gridHeight + padding)
    }

    static func contentOffsetY(
        for state: GhosttySurfaceScrollState,
        cellHeight: CGFloat,
        maxContentOffsetY: CGFloat
    ) -> CGFloat {
        guard cellHeight.isFinite, cellHeight > 0 else { return 0 }

        let row = min(state.offset, state.maxRow)
        if row == state.maxRow {
            return max(maxContentOffsetY, 0)
        }
        let cellOffset = row == state.maxRow
            ? 0
            : min(max(state.cellOffset, 0), 0.999_999_999)
        let rawOffset = (CGFloat(row) + CGFloat(cellOffset)) * cellHeight
        return min(max(rawOffset, 0), max(maxContentOffsetY, 0))
    }

    static func position(
        forContentOffsetY contentOffsetY: CGFloat,
        cellHeight: CGFloat,
        state: GhosttySurfaceScrollState,
        maxContentOffsetY: CGFloat
    ) -> GhosttyPaneScrollPosition? {
        guard cellHeight.isFinite, cellHeight > 0 else { return nil }

        let clampedOffset = min(max(contentOffsetY, 0), max(maxContentOffsetY, 0))
        let rowDouble = floor(clampedOffset / cellHeight)
        let maxRow = state.maxRow
        guard rowDouble < CGFloat(maxRow) else {
            return GhosttyPaneScrollPosition(row: maxRow, cellOffset: 0)
        }

        let row = min(UInt64(max(rowDouble, 0)), maxRow)
        let fractional = Double((clampedOffset / cellHeight) - rowDouble)
        return GhosttyPaneScrollPosition(
            row: row,
            cellOffset: min(max(fractional, 0), 0.999_999_999)
        )
    }
}

@MainActor
final class GhosttyPaneScrollContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let rendererRecoveryImageView = UIImageView()

    /// The viewport borrows the one retained pane surface it currently shows.
    /// `TmuxTerminalSession` owns that surface independently of UIKit attachment.
    private var surface: GhosttyManagedSurface?
    private var displayScale: CGFloat = max(UIScreen.main.scale, 1)
    private var displayLink: CADisplayLink?
    private var pendingContentOffset: CGPoint?
    private var isApplyingProgrammaticUpdate = false
    private var lastAppliedScrollRoute: GhosttySurfaceScrollRoute?
    private var isUserViewportScrolling = false
    private var lastSentViewportScrollPosition: GhosttyPaneScrollPosition?
    private var submitRouteForwardedMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitRouteForwardedMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?

    /// UIKit-native scroll physics for the forwarded scroll routes:
    /// pan and deceleration of this hidden scroll view produce the
    /// offset deltas forwarded as precise scroll events, so flicks
    /// coast on Apple's deceleration curve exactly like a trackpad.
    /// On the mouse-report route the events become wheel reports; on
    /// the alt-screen-cursor route the engine converts them to cursor
    /// keys (the same wheel-with-inertia semantics desktop terminals
    /// give alternate-scroll apps). The route is revalidated on every
    /// delta, so leftover momentum never becomes input for whatever
    /// mode comes next.
    private let physicsScrollView = GhosttyScrollPhysicsView()
    private var physicsForwardingGesture = GhosttyRouteForwardingScrollGesture(
        preciseScale: GhosttyScrollTuning.routeForwardedGain
    )
    private var physicsDeltaBudget = GhosttyScrollDeltaBudget(unitsPerSecond: 0)
    private var physicsTailCutoff = GhosttyScrollTailCutoff()
    private var physicsVelocityGain = GhosttyScrollVelocityGain()
    private var physicsPeakMultiplier: Double = 1
    private var physicsReportedOffsetY: CGFloat?
    private var isPhysicsGestureActive = false
    private var isRecenteringPhysicsScroll = false

    /// Set when a touch catches a live deceleration. The tap that
    /// lands from that touch is the catch itself, not an intentional
    /// click — native scroll views swallow it. The tree view's tap
    /// handler consumes this before forwarding mouse actions.
    private var lastMomentumCatchAt: TimeInterval?
    private static let momentumCatchTapWindow: TimeInterval = 0.4

    /// Caps on reports one gesture may produce per second, per route.
    /// On the mouse-report route each tick costs the remote TUI a
    /// full repaint (opencode: ~6KB/frame), so headroom over the
    /// proven-comfortable ~45/s is modest. On the alt-screen-cursor
    /// route a tick is one cursor key and pagers repaint ~one line
    /// (~100B), so the ceiling is set by feel, not cost — and one
    /// tick is a single line, so fast flicks need the rate.
    private static let maxMouseReportTicksPerSecond: Double = 60
    private static let maxAltScreenTicksPerSecond: Double = 150


    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
        }
    }

    @discardableResult
    func update(
        surface: GhosttyManagedSurface,
        displayScale: CGFloat,
        submitRouteForwardedMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitRouteForwardedMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    ) -> Bool {
        let normalizedDisplayScale = max(displayScale, 1)
        let didChangeScale = self.displayScale != normalizedDisplayScale
        self.displayScale = normalizedDisplayScale
        self.submitRouteForwardedMouseScroll = submitRouteForwardedMouseScroll
        self.submitRouteForwardedMousePosition = submitRouteForwardedMousePosition

        var needsLayout = didChangeScale
        if self.surface !== surface {
            GhosttyRuntimeTrace.diagnostics(
                "scroll.update attach old=\(ghosttyDiagnosticShortID(self.surface?.id)) new=\(ghosttyDiagnosticShortID(surface.id)) bounds=\(ghosttyDiagnosticRect(bounds)) surface={\(surface.diagnosticSummary())}"
            )
            haltPhysicsScroll()
            self.surface?.onScrollStateChange = nil
            self.surface?.onRendererRecoveryChange = nil
            resetViewportScrollInteractionState()
            self.surface = surface

            if surface.view.superview !== contentView {
                surface.view.removeFromSuperview()
                contentView.addSubview(surface.view)
            }

            surface.onScrollStateChange = { [weak self, weak surface] in
                guard let self, self.surface === surface else { return }
                self.synchronizeFromSurface()
            }
            surface.onRendererRecoveryChange = { [weak self, weak surface] in
                guard let self, self.surface === surface else { return }
                self.synchronizeRendererRecovery()
            }
            needsLayout = true
        }
        surface.view.isHidden = false
        surface.view.alpha = 1
        surface.view.layer.opacity = 1
        synchronizeRendererRecovery()

        needsLayout = synchronizeRoute() || needsLayout
        if needsLayout {
            setNeedsLayout()
        }
        return needsLayout
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        physicsScrollView.frame = bounds
        rendererRecoveryImageView.frame = bounds
        physicsScrollView.synchronizeVirtualContent()
        recenterPhysicsScrollIfIdle()
        synchronizeFromSurface()
    }

    func detachSurfaceIfNeeded(_ surface: GhosttyManagedSurface) {
        guard self.surface === surface else { return }
        haltPhysicsScroll()
        surface.onScrollStateChange = nil
        surface.onRendererRecoveryChange = nil
        self.surface = nil
        submitRouteForwardedMouseScroll = nil
        submitRouteForwardedMousePosition = nil
        lastAppliedScrollRoute = nil
        resetViewportScrollInteractionState()
        surface.view.isHidden = true
        surface.view.removeFromSuperview()
    }

    func detachCurrentSurfaceForRemoval() {
        guard let surface else { return }
        detachSurfaceIfNeeded(surface)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === physicsScrollView {
            forwardPhysicsScrollDelta()
            return
        }

        pinSurfaceToVisibleBounds()
        guard !isApplyingProgrammaticUpdate else { return }
        guard surface?.scrollRoute == .viewport else { return }

        pendingContentOffset = scrollView.contentOffset
        ensureDisplayLink()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === physicsScrollView {
            if physicsScrollView.isDecelerating {
                lastMomentumCatchAt = CACurrentMediaTime()
            }
            beginPhysicsGesture()
            return
        }

        guard surface?.scrollRoute == .viewport else { return }
        isUserViewportScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === physicsScrollView {
            if !decelerate {
                endPhysicsGesture(phase: .ended)
            }
            return
        }

        guard surface?.scrollRoute == .viewport else { return }
        guard !decelerate else { return }
        finishUserViewportScroll()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === physicsScrollView {
            // Deceleration ending while a touch is tracking means that
            // touch caught the fling (a natural end has no touch).
            if physicsScrollView.isTracking {
                lastMomentumCatchAt = CACurrentMediaTime()
            }
            endPhysicsGesture(phase: .ended)
            return
        }

        guard surface?.scrollRoute == .viewport else { return }
        finishUserViewportScroll()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === physicsScrollView.panGestureRecognizer else { return true }
        guard surface?.scrollRoute != .viewport else { return false }

        let pan = physicsScrollView.panGestureRecognizer
        return GhosttySurfacePanGesture.routeForwardingScrollShouldBegin(
            forVelocity: pan.velocity(in: self),
            translation: pan.translation(in: self)
        )
    }


    private func configure() {
        clipsToBounds = true
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bounces = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        physicsScrollView.delegate = self
        physicsScrollView.backgroundColor = .clear
        physicsScrollView.contentInsetAdjustmentBehavior = .never
        physicsScrollView.isDirectionalLockEnabled = true
        physicsScrollView.showsVerticalScrollIndicator = false
        physicsScrollView.showsHorizontalScrollIndicator = false
        physicsScrollView.alwaysBounceVertical = false
        physicsScrollView.alwaysBounceHorizontal = false
        addSubview(physicsScrollView)
        // The physics view is hit-test transparent; its pan tracks
        // touches on the container while driving the scroll view's
        // native deceleration.
        addGestureRecognizer(physicsScrollView.panGestureRecognizer)

        rendererRecoveryImageView.backgroundColor = .clear
        rendererRecoveryImageView.contentMode = .scaleToFill
        rendererRecoveryImageView.isUserInteractionEnabled = false
        rendererRecoveryImageView.isHidden = true
        addSubview(rendererRecoveryImageView)
    }

    private func synchronizeRendererRecovery() {
        guard let surface else {
            rendererRecoveryImageView.image = nil
            rendererRecoveryImageView.isHidden = true
            isUserInteractionEnabled = true
            return
        }
        rendererRecoveryImageView.image = surface.rendererRecoverySnapshot.map {
            UIImage(cgImage: $0, scale: displayScale, orientation: .up)
        }
        rendererRecoveryImageView.backgroundColor = surface.rendererRecoverySnapshot == nil
            && !surface.rendererIsAvailable
            ? surface.view.backgroundColor
            : .clear
        rendererRecoveryImageView.isHidden = surface.rendererIsAvailable
        isUserInteractionEnabled = surface.rendererIsAvailable
    }

    @discardableResult
    private func synchronizeRoute() -> Bool {
        let route = surface?.scrollRoute ?? .viewport
        let didChangeRoute = route != lastAppliedScrollRoute
        lastAppliedScrollRoute = route
        let usesNativeViewportScroll = route == .viewport
        scrollView.isScrollEnabled = usesNativeViewportScroll
        scrollView.showsVerticalScrollIndicator = usesNativeViewportScroll
        physicsScrollView.panGestureRecognizer.isEnabled = !usesNativeViewportScroll
        if usesNativeViewportScroll {
            haltPhysicsScroll()
        } else if didChangeRoute {
            // Route changed between forwarded modes (e.g. the app
            // toggled mouse reporting): momentum for the old mode must
            // not become input for the new one.
            haltPhysicsScroll()
            resetViewportScrollInteractionState()
        }
        return didChangeRoute
    }

    private func synchronizeFromSurface() {
        guard let surface else { return }
        synchronizeRoute()

        let viewportHeight = max(bounds.height, 1)
        let cellHeight = cellHeight(for: surface)
        let contentHeight = GhosttyPaneScrollGeometry.documentHeight(
            viewportHeight: viewportHeight,
            cellHeight: cellHeight,
            state: surface.scrollState
        )
        let contentSize = CGSize(width: max(bounds.width, 1), height: contentHeight)
        let maxOffsetY = max(0, contentHeight - viewportHeight)

        if isActiveViewportScrollInteraction {
            synchronizeContentSize(contentSize)
            pinSurfaceToVisibleBounds()
            return
        }

        withProgrammaticScrollSynchronization {
            synchronizeContentSize(contentSize)
            let offsetY = GhosttyPaneScrollGeometry.contentOffsetY(
                for: surface.scrollState,
                cellHeight: cellHeight,
                maxContentOffsetY: maxOffsetY
            )
            applyProgrammaticContentOffset(CGPoint(x: 0, y: offsetY))
            lastSentViewportScrollPosition = GhosttyPaneScrollGeometry.position(for: surface.scrollState)
            pinSurfaceToVisibleBounds()
        }
    }

    private func pinSurfaceToVisibleBounds() {
        guard let surface else { return }
        guard let viewportSize = GhosttyPaneScrollGeometry.displayViewportSize(for: bounds) else { return }

        pinSurfaceToVisibleBounds(surface: surface, viewportSize: viewportSize)
    }

    private func pinSurfaceToVisibleBounds(
        surface: GhosttyManagedSurface,
        viewportSize: CGSize
    ) {
        let origin = CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y)
        let frame = CGRect(origin: origin, size: viewportSize)
        guard surface.view.frame != frame else { return }
        surface.view.frame = frame
    }

    private func applyProgrammaticContentOffset(_ offset: CGPoint) {
        guard scrollView.contentOffset != offset else { return }
        scrollView.setContentOffset(offset, animated: false)
    }

    private func synchronizeContentSize(_ contentSize: CGSize) {
        guard scrollView.contentSize != contentSize else { return }
        scrollView.contentSize = contentSize
        contentView.frame = CGRect(origin: .zero, size: contentSize)
    }

    private func withProgrammaticScrollSynchronization(_ body: () -> Void) {
        pendingContentOffset = nil
        invalidateDisplayLink()
        isApplyingProgrammaticUpdate = true
        body()
        isApplyingProgrammaticUpdate = false
        pendingContentOffset = nil
        invalidateDisplayLink()
    }

    private func cellHeight(for surface: GhosttyManagedSurface) -> CGFloat {
        let size = surface.controlSurface.currentSize()
        let scale = max(displayScale, 1)
        if size.cell_height_px > 0 {
            return CGFloat(size.cell_height_px) / scale
        }
        if surface.scrollState.len > 0 {
            return max(bounds.height, 1) / CGFloat(surface.scrollState.len)
        }
        return 0
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func resetViewportScrollInteractionState() {
        isUserViewportScrolling = false
        lastSentViewportScrollPosition = nil
        pendingContentOffset = nil
        invalidateDisplayLink()
    }

    private var isActiveViewportScrollInteraction: Bool {
        guard surface?.scrollRoute == .viewport else { return false }
        return isUserViewportScrolling ||
            scrollView.isTracking ||
            scrollView.isDragging ||
            scrollView.isDecelerating
    }

    private func finishUserViewportScroll() {
        flushPendingViewportScrollOffset()
        isUserViewportScrolling = false
        synchronizeFromSurface()
    }

    @objc
    private func displayLinkTick() {
        guard flushPendingViewportScrollOffset() else {
            invalidateDisplayLink()
            return
        }
    }

    @discardableResult
    private func flushPendingViewportScrollOffset() -> Bool {
        guard let offset = pendingContentOffset else { return false }
        pendingContentOffset = nil

        guard let surface, surface.scrollRoute == .viewport else { return false }
        let viewportHeight = max(bounds.height, 1)
        let maxOffsetY = max(0, scrollView.contentSize.height - viewportHeight)
        guard let position = GhosttyPaneScrollGeometry.position(
            forContentOffsetY: offset.y,
            cellHeight: cellHeight(for: surface),
            state: surface.scrollState,
            maxContentOffsetY: maxOffsetY
        ) else {
            return false
        }

        guard !position.approximatelyEquals(lastSentViewportScrollPosition) else { return false }
        lastSentViewportScrollPosition = position

        surface.scrollToPosition(
            row: position.row,
            cellOffset: position.cellOffset
        )
        return true
    }

    // MARK: Mouse-report scroll physics

    /// A new drag, including catching a live deceleration. Closing any
    /// previous stream first keeps the event phases well-formed.
    private func beginPhysicsGesture() {
        if isPhysicsGestureActive {
            endPhysicsGesture(phase: .cancelled)
        }

        guard let surface, surface.scrollRoute != .viewport,
              submitRouteForwardedMouseScroll != nil
        else {
            haltPhysicsScroll()
            return
        }

        // Wheel reports encode at the pointer position, and touch UIs
        // never report one: anchor the pointer at the gesture's touch
        // point so the encoder does not drop the events
        // (mouse_encode.zig out-of-viewport rule).
        let location = physicsScrollView.panGestureRecognizer.location(in: surface.view)
        GhosttyRuntimeTrace.diagnostics(
            "scroll.physics begin surface=\(ghosttyDiagnosticShortID(surface.id)) location=\(location.x),\(location.y) offset=\(physicsScrollView.contentOffset.y)"
        )
        _ = submitRouteForwardedMousePosition?(surface.id, location, [])

        let cellHeightPixels = max(cellHeight(for: surface), 1) * displayScale
        let ticksPerSecond = surface.scrollRoute == .altScreenCursor
            ? Self.maxAltScreenTicksPerSecond
            : Self.maxMouseReportTicksPerSecond
        let budgetUnitsPerSecond = ticksPerSecond
            * cellHeightPixels
            / physicsForwardingGesture.preciseScale
        GhosttyRuntimeTrace.diagnostics(
            "scroll.physics budget cellPts=\(cellHeight(for: surface)) scale=\(displayScale) cellPx=\(cellHeightPixels) unitsPerSec=\(budgetUnitsPerSecond)"
        )
        physicsDeltaBudget.rearm(unitsPerSecond: budgetUnitsPerSecond)
        physicsTailCutoff.reset()
        physicsVelocityGain.reset()
        physicsPeakMultiplier = 1
        physicsReportedOffsetY = physicsScrollView.contentOffset.y
        isPhysicsGestureActive = true
    }

    /// Convert the offset delta since the last callback into the same
    /// precise scroll events the contact pan produces. The route is
    /// revalidated on every delta: the remote app can change terminal
    /// modes mid-deceleration, and leftover momentum must not turn
    /// into input for whatever mode comes next.
    private func forwardPhysicsScrollDelta() {
        guard !isRecenteringPhysicsScroll, isPhysicsGestureActive else { return }

        guard let surface, surface.scrollRoute != .viewport,
              let submitRouteForwardedMouseScroll
        else {
            haltPhysicsScroll()
            return
        }

        let offsetY = physicsScrollView.contentOffset.y
        let reported = physicsReportedOffsetY ?? offsetY
        physicsReportedOffsetY = offsetY

        // Finger moving down drags the virtual offset down; positive
        // translation means scroll up, matching the contact pan.
        let delta = Double(reported - offsetY)
        let now = CACurrentMediaTime()

        // While decelerating (finger up), stop once the coast falls
        // below the cell-quantization floor: the remaining tail would
        // emit isolated whole-cell ticks hundreds of milliseconds
        // apart — jitter, not motion. Never cuts off an active drag.
        if physicsScrollView.isDecelerating,
           physicsTailCutoff.shouldStop(
               delta: delta,
               at: now,
               cellHeightPoints: Double(max(cellHeight(for: surface), 1))
           ) {
            GhosttyRuntimeTrace.diagnostics(
                "scroll.physics tailCutoff surface=\(ghosttyDiagnosticShortID(surface.id))"
            )
            haltPhysicsScroll()
            return
        }
        if !physicsScrollView.isDecelerating {
            physicsTailCutoff.reset()
        }

        // Velocity acceleration before the budget, so the per-route
        // tick cap bounds the effective output.
        let multiplier = physicsVelocityGain.multiplier(delta: delta, at: now)
        physicsPeakMultiplier = max(physicsPeakMultiplier, multiplier)
        let accelerated = delta * multiplier
        let budgeted = physicsDeltaBudget.clamp(accelerated, at: now)
        guard budgeted != 0 else { return }

        let events = physicsForwardingGesture.events(
            forTranslation: CGPoint(x: 0, y: budgeted),
            phase: .changed
        )
        for event in events {
            _ = submitRouteForwardedMouseScroll(surface.id, event)
        }
    }

    private func endPhysicsGesture(phase: GhosttySurfacePanGesture.Phase) {
        guard isPhysicsGestureActive else { return }
        isPhysicsGestureActive = false
        physicsReportedOffsetY = nil

        if let surface, let submitRouteForwardedMouseScroll {
            let events = physicsForwardingGesture.events(
                forTranslation: .zero,
                phase: phase
            )
            for event in events {
                _ = submitRouteForwardedMouseScroll(surface.id, event)
            }
        } else {
            physicsForwardingGesture.reset()
        }

        GhosttyRuntimeTrace.diagnostics(
            "scroll.physics end surface=\(ghosttyDiagnosticShortID(surface?.id)) phase=\(phase) peakGain=\(String(format: "%.2f", physicsPeakMultiplier))"
        )
        recenterPhysicsScrollIfIdle()
    }

    /// Stop any tracking or deceleration immediately (route flips,
    /// surface detach, teardown) and close the local event stream.
    private func haltPhysicsScroll() {
        let wasMoving = physicsScrollView.isTracking ||
            physicsScrollView.isDragging ||
            physicsScrollView.isDecelerating
        if wasMoving {
            isRecenteringPhysicsScroll = true
            physicsScrollView.setContentOffset(physicsScrollView.contentOffset, animated: false)
            isRecenteringPhysicsScroll = false
        }
        if isPhysicsGestureActive {
            endPhysicsGesture(phase: .cancelled)
        } else if wasMoving {
            recenterPhysicsScrollIfIdle()
        }
    }

    /// True exactly once for the tap produced by a fling-catch touch;
    /// consuming keeps an immediate deliberate follow-up tap clickable.
    func consumeMomentumCatchTap(at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard let caughtAt = lastMomentumCatchAt else { return false }
        lastMomentumCatchAt = nil
        return now - caughtAt < Self.momentumCatchTapWindow
    }

    private func recenterPhysicsScrollIfIdle() {
        guard !physicsScrollView.isTracking,
              !physicsScrollView.isDragging,
              !physicsScrollView.isDecelerating
        else { return }

        let centered = CGPoint(x: 0, y: physicsScrollView.centeredContentOffsetY)
        guard physicsScrollView.contentOffset != centered else { return }
        isRecenteringPhysicsScroll = true
        physicsScrollView.setContentOffset(centered, animated: false)
        isRecenteringPhysicsScroll = false
        physicsReportedOffsetY = nil
    }

}
