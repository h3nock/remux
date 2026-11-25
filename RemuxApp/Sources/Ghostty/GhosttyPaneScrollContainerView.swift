import CoreGraphics
import QuartzCore
import UIKit

struct GhosttyPaneScrollPosition: Equatable {
    let row: UInt64
    let cellOffset: Double

    /// Whether this position is further back in history, toward the oldest rows.
    func isOlder(than other: GhosttyPaneScrollPosition) -> Bool {
        row < other.row || (row == other.row && cellOffset < other.cellOffset)
    }

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

    /// The terminal position for a scroll view offset. The scroll view rests on whole device pixels and a cell is a
    /// whole number of them, so the offset is worked out in pixels: the scroll view resting at its end is exactly the
    /// last row. Divided in points, an offset at rest one rounding step short of the end read as the row before it plus
    /// 0.999999999 of a row, which pinned the terminal there, short of the bottom, so it stopped following output.
    static func position(
        forContentOffsetY contentOffsetY: CGFloat,
        cellHeight: CGFloat,
        displayScale: CGFloat,
        state: GhosttySurfaceScrollState,
        maxContentOffsetY: CGFloat
    ) -> GhosttyPaneScrollPosition? {
        guard cellHeight.isFinite, cellHeight > 0, contentOffsetY.isFinite, maxContentOffsetY.isFinite else {
            return nil
        }

        let scale = max(displayScale.isFinite ? displayScale : 1, 1)
        let cellPixels = max((cellHeight * scale).rounded(), 1)
        let maxPixels = (max(maxContentOffsetY, 0) * scale).rounded()
        let offsetPixels = min(max((contentOffsetY * scale).rounded(), 0), maxPixels)
        let maxRow = state.maxRow
        let row = (offsetPixels / cellPixels).rounded(.down)
        guard offsetPixels < maxPixels, row < CGFloat(maxRow) else {
            return GhosttyPaneScrollPosition(row: maxRow, cellOffset: 0)
        }

        return GhosttyPaneScrollPosition(
            row: UInt64(row),
            cellOffset: Double((offsetPixels - row * cellPixels) / cellPixels)
        )
    }
}

@MainActor
final class GhosttyPaneScrollContainerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Called after the pane's surface changes where it is scrolled to.
    var onSurfaceScrollStateChange: (() -> Void)?
    /// Called when the user scrolls the pane toward older rows of its history.
    var onScrollTowardHistory: (() -> Void)?
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
    /// Whether the gesture's speed scales its travel; not where a step is a known line.
    private var physicsUsesVelocityGain = true
    private var physicsPeakMultiplier: Double = 1
    private var physicsReportedOffsetY: CGFloat?
    private var isPhysicsGestureActive = false
    private var isRecenteringPhysicsScroll = false

    /// Over a program that reads the mouse, when the pane's backend reports its rows, a touch scroll follows the
    /// hidden scroll view by measuring what the program does with each wheel batch. The follower keeps what it learned
    /// of the program while the pane stays on that route.
    private var scrollFollower: GhosttyScrollFollower?
    private var isFollowingGesture = false
    /// Whether the pane's backend is reporting its rows to the follower.
    private var isObservingRows = false
    /// The scroll view's travel in rows since the follower's session began, positive toward earlier rows.
    private var followTravel: Double = 0
    /// Where the latest touch began: its 1-based grid row, and its x in the surface view.
    private var followTouch: (row: Int, x: CGFloat) = (1, 0)
    /// The pane's rows as last reported; a session starts from them.
    private var followRows: [String]?
    private var followLink: CADisplayLink?
    /// Names the batch whose reply the follower waits for; a reply to any other is dropped.
    private var followBatchTag: UInt64 = 0

    /// Set when a touch catches a live deceleration. The tap from that touch is
    /// the catch, not a click, as in native scroll views; the composite
    /// viewport's tap handler consumes it before forwarding mouse actions.
    private var lastMomentumCatchAt: TimeInterval?
    private static let momentumCatchTapWindow: TimeInterval = 0.4

    /// Per-route caps on reports per second of one gesture. Each mouse-report
    /// tick makes the remote TUI repaint, and each remote-history tick makes the
    /// server send a new frame, so those caps stay low. An alt-screen-cursor tick
    /// is one cursor key moving one line, so fast flicks need a higher cap.
    private static let maxMouseReportTicksPerSecond: Double = 60
    private static let maxAltScreenTicksPerSecond: Double = 150

    /// When this view last forwarded a scroll. A server's history position that
    /// changes soon after shows the scroll indicator; one that moves with new
    /// output while nobody scrolls doesn't.
    private var lastForwardedScrollAt: TimeInterval?
    private var lastRemoteLinesFromBottom: UInt64?
    private static let remoteScrollIndicatorWindow: TimeInterval = 1


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
            followLink?.invalidate()
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
            scrollFollower = nil
            self.surface?.onScrollStateChange = nil
            self.surface?.onStopScrolling = nil
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
                self.onSurfaceScrollStateChange?()
            }
            surface.onStopScrolling = { [weak self, weak surface] in
                guard let self, self.surface === surface else { return }
                self.stopScrolling()
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
        // The pane's frames are cell geometry and never animate, even in a layout pass that
        // runs inside another animation.
        UIView.performWithoutAnimation {
            scrollView.frame = bounds
            physicsScrollView.frame = bounds
            rendererRecoveryImageView.frame = bounds
            physicsScrollView.synchronizeVirtualContent()
            recenterPhysicsScrollIfIdle()
            synchronizeFromSurface()
        }
    }

    func detachSurfaceIfNeeded(_ surface: GhosttyManagedSurface) {
        guard self.surface === surface else { return }
        haltPhysicsScroll()
        scrollFollower = nil
        surface.onScrollStateChange = nil
        surface.onStopScrolling = nil
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
                scrollFollower?.caught(target: followTravel)
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
        scrollView.showsVerticalScrollIndicator = usesNativeViewportScroll || route == .remoteHistory
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
        // What the follower learned is about the program that read the mouse; whatever reads it next starts afresh.
        if didChangeRoute { scrollFollower = nil }
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
        showRemoteScrollIndicatorIfScrolled(surface.scrollState)
    }

    private func showRemoteScrollIndicatorIfScrolled(_ state: GhosttySurfaceScrollState) {
        guard surface?.scrollRoute == .remoteHistory else {
            lastRemoteLinesFromBottom = nil
            return
        }
        let linesFromBottom = state.maxRow - min(state.offset, state.maxRow)
        defer { lastRemoteLinesFromBottom = linesFromBottom }
        guard let lastRemoteLinesFromBottom, linesFromBottom != lastRemoteLinesFromBottom,
              let lastForwardedScrollAt,
              isPhysicsGestureActive
                || CACurrentMediaTime() - lastForwardedScrollAt < Self.remoteScrollIndicatorWindow
        else { return }
        scrollView.flashScrollIndicators()
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
        lastForwardedScrollAt = nil
        lastRemoteLinesFromBottom = nil
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

    /// Ends a scroll in motion where it is, as a touch ends a fling. A forwarded scroll sends nothing more; the pane's
    /// own scroll stops on the position the surface shows, and a step not yet sent to the surface, never drawn, is
    /// dropped. While a scroll moves, the scroll view leads and a position the surface takes from elsewhere waits,
    /// so the surface's position is taken up once it stops.
    private func stopScrolling() {
        let isViewportMoving = isActiveViewportScrollInteraction
        let isPhysicsMoving = isPhysicsGestureActive || physicsScrollView.isTracking || physicsScrollView.isDecelerating
            || scrollFollower?.isLive == true
        guard isViewportMoving || isPhysicsMoving else { return }
        GhosttyRuntimeTrace.diagnostics(
            "scroll.stop surface=\(ghosttyDiagnosticShortID(surface?.id)) viewportMoving=\(isViewportMoving) viewportDecelerating=\(scrollView.isDecelerating) physicsMoving=\(isPhysicsMoving)"
        )
        haltPhysicsScroll()
        guard isViewportMoving else { return }
        withProgrammaticScrollSynchronization {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        isUserViewportScrolling = false
        synchronizeFromSurface()
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
            displayScale: displayScale,
            state: surface.scrollState,
            maxContentOffsetY: maxOffsetY
        ) else {
            return false
        }

        guard !position.approximatelyEquals(lastSentViewportScrollPosition) else { return false }
        lastSentViewportScrollPosition = position

        let isTowardHistory = position.isOlder(than: GhosttyPaneScrollGeometry.position(for: surface.scrollState))
        surface.scrollToPosition(
            row: position.row,
            cellOffset: position.cellOffset
        )
        if isTowardHistory { onScrollTowardHistory?() }
        return true
    }

    // MARK: Route-forwarded scroll physics

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

        if surface.scrollRoute == .mouseReport, beginFollowing(surface) {
            return
        }

        // Remote wheel reports are encoded at the pointer position, and the
        // terminal surface rejects a remote scroll with no pointer. Touch input
        // never moves the pointer, so anchor it at the touch point.
        let location = physicsScrollView.panGestureRecognizer.location(in: surface.view)
        GhosttyRuntimeTrace.diagnostics(
            "scroll.physics begin surface=\(ghosttyDiagnosticShortID(surface.id)) location=\(location.x),\(location.y) offset=\(physicsScrollView.contentOffset.y)"
        )
        _ = submitRouteForwardedMousePosition?(surface.id, location, [])

        // On the alternate-screen route a step is one line, so a row of finger travel is one step and the lines move
        // with the finger, as a list does. The terminal counts a step per cell height in pixels; finger travel is in
        // points. The remote-history route, where Herdr scrolls three lines a step, keeps its tuned gain.
        let linesFollowFinger = surface.scrollRoute == .altScreenCursor
        physicsForwardingGesture = GhosttyRouteForwardingScrollGesture(
            preciseScale: linesFollowFinger ? displayScale : GhosttyScrollTuning.routeForwardedGain
        )
        physicsUsesVelocityGain = !linesFollowFinger
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
        if isFollowingGesture {
            followTravel += delta / Double(max(cellHeight(for: surface), 1))
            return
        }
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
        let multiplier = physicsUsesVelocityGain ? physicsVelocityGain.multiplier(delta: delta, at: now) : 1
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
        if !events.isEmpty { lastForwardedScrollAt = now }
        // A positive translation scrolls up: on a server's history, as Herdr's, that is toward older rows.
        if surface.scrollRoute == .remoteHistory, budgeted > 0, !events.isEmpty { onScrollTowardHistory?() }
    }

    private func endPhysicsGesture(phase: GhosttySurfacePanGesture.Phase) {
        guard isPhysicsGestureActive else { return }
        isPhysicsGestureActive = false
        physicsReportedOffsetY = nil
        if isFollowingGesture {
            // The follower goes on until it has landed what the scroll view travelled.
            isFollowingGesture = false
            DispatchQueue.main.async { [weak self] in
                self?.recenterPhysicsScrollIfIdle()
            }
            return
        }

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
        // A drag that ends without momentum ends inside scrollViewDidEndDragging, where UIKit
        // still reports tracking; it clears by the next main-queue turn.
        DispatchQueue.main.async { [weak self] in
            self?.recenterPhysicsScrollIfIdle()
        }
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
        endFollowing()
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

    // MARK: Following a program that reads the mouse

    /// False when the pane's backend doesn't report its rows; the gesture then goes as scroll events.
    private func beginFollowing(_ surface: GhosttyManagedSurface) -> Bool {
        let cellHeight = cellHeight(for: surface)
        let gridRows = Int(surface.scrollState.len)
        guard cellHeight > 0, gridRows > 0 else { return false }
        if scrollFollower?.gridRows != gridRows {
            endFollowing()
            var memory = scrollFollower?.memory ?? .init()
            if let previous = scrollFollower { memory.resize(fromRows: previous.gridRows, toRows: gridRows) }
            scrollFollower = GhosttyScrollFollower(gridRows: gridRows, memory: memory)
        }
        if !isObservingRows {
            guard surface.observeRows({ [weak self, weak surface] event in
                guard let self, let surface, self.surface === surface else { return }
                self.followerReceived(event)
            }) else { return false }
            isObservingRows = true
        }
        if scrollFollower?.isLive == true {
            // A touch stops what the follower still moves, as a touch stops a coasting list: what it still owed is
            // dropped, a batch on its way lands where it lands, and the new gesture starts from the rows shown. Travel
            // owed past an edge, which nothing can deliver, goes with it.
            scrollFollower?.end()
            followBatchTag &+= 1
        }
        followTravel = 0
        let location = physicsScrollView.panGestureRecognizer.location(in: surface.view)
        followTouch = (
            row: min(max(Int(location.y / cellHeight) + 1, 1), gridRows),
            x: min(max(location.x, 0), max(surface.view.bounds.width - 1, 0))
        )
        GhosttyRuntimeTrace.diagnostics(
            "scroll.follow begin surface=\(ghosttyDiagnosticShortID(surface.id)) row=\(followTouch.row) live=\(scrollFollower?.isLive == true)"
        )
        physicsReportedOffsetY = physicsScrollView.contentOffset.y
        isPhysicsGestureActive = true
        isFollowingGesture = true
        if followLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(followTick))
            link.add(to: .main, forMode: .common)
            followLink = link
        }
        return true
    }

    /// The pane's rows, in the order its server sent what they show.
    private func followerReceived(_ event: GhosttyPaneRowsEvent) {
        guard isObservingRows, let gridRows = scrollFollower?.gridRows else { return }
        let now = CACurrentMediaTime()
        switch event {
        case .frame(let text):
            guard let text else { return }
            let rows = GhosttyScrollLedger.rows(fromViewportText: text, gridRows: gridRows)
            followRows = rows
            scrollFollower?.frame(rows, now: now)
        case .reply(let tag, let delivered, let text):
            guard tag == followBatchTag else { return }
            guard delivered else {
                endFollowing()
                return
            }
            let rows = text.map { GhosttyScrollLedger.rows(fromViewportText: $0, gridRows: gridRows) }
            if let rows { followRows = rows }
            scrollFollower?.receipt(rows: rows, now: now)
        }
    }

    /// One display frame of the follower: what to send, from the scroll view's travel and what the pane has shown.
    @objc
    private func followTick() {
        guard var follower = scrollFollower, let surface, surface.scrollRoute == .mouseReport,
              Int(surface.scrollState.len) == follower.gridRows
        else {
            // The route or the grid changed under the session: what it measured no longer applies.
            endFollowing()
            return
        }
        let active = physicsScrollView.isTracking || physicsScrollView.isDragging || physicsScrollView.isDecelerating
        // A session starts from the rows the pane's backend reports first; a gesture over before any came starts none.
        guard followRows != nil || follower.isLive else {
            if !active { endFollowing() }
            return
        }
        let seen = follower.seen
        let step = follower.tick(
            target: followTravel,
            active: active,
            touchRow: followTouch.row,
            now: CACurrentMediaTime(),
            rows: followRows
        )
        scrollFollower = follower
        switch step {
        case .ended:
            GhosttyRuntimeTrace.diagnostics(
                "scroll.follow end target=\(String(format: "%.2f", followTravel)) seen=\(seen)"
            )
            endFollowing()
        case .live(nil):
            break
        case .live(let send?):
            GhosttyRuntimeTrace.diagnostics(
                "scroll.follow send t=\(String(format: "%.3f", CACurrentMediaTime())) target=\(String(format: "%.2f", followTravel)) seen=\(follower.seen) reports=\(send.reports) up=\(send.up) row=\(send.row)"
            )
            followBatchTag &+= 1
            let batch = GhosttySurfaceWheelBatch(
                reports: send.reports,
                up: send.up,
                pointer: CGPoint(x: followTouch.x, y: (CGFloat(send.row) - 0.5) * cellHeight(for: surface))
            )
            if !surface.sendWheelReports(batch, tag: followBatchTag) { endFollowing() }
        }
    }

    /// Ends the follower's session, sending nothing more; what it learned of the program is kept.
    private func endFollowing() {
        scrollFollower?.end()
        isFollowingGesture = false
        followTravel = 0
        followRows = nil
        followBatchTag &+= 1
        followLink?.invalidate()
        followLink = nil
        if isObservingRows {
            isObservingRows = false
            surface?.stopObservingRows()
        }
    }

}
