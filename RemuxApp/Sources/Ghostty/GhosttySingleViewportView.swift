import GhosttyKit
import SwiftUI
import UIKit

/// Hosts every visible pane in the active tmux window at its authoritative
/// grid rectangle using one shared, unscaled cell metric.
struct GhosttyCompositeViewportView: View {
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let projection: GhosttyTerminalViewportPresentationProjection
    let terminalTheme: TerminalTheme
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let onSurfaceTap: ((UUID, Bool) -> Void)?
    let onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let sendKeyEventToSurface: (GhosttySurfaceKeyEvent, UUID) -> Bool
    let onTrackpadFeedbackChange: (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?

    var body: some View {
        GhosttyCompositeViewportRepresentable(
            surfaceLookup: surfaceLookup,
            projection: projection,
            terminalTheme: terminalTheme,
            trackpadDriver: trackpadDriver,
            onSurfaceTap: onSurfaceTap,
            onPreviewSelection: onPreviewSelection,
            onWindowSwipe: onWindowSwipe,
            sendKeyEventToSurface: sendKeyEventToSurface,
            onTrackpadFeedbackChange: onTrackpadFeedbackChange,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttyCompositeViewportRepresentable: UIViewRepresentable {
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let projection: GhosttyTerminalViewportPresentationProjection
    let terminalTheme: TerminalTheme
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let onSurfaceTap: ((UUID, Bool) -> Void)?
    let onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let sendKeyEventToSurface: (GhosttySurfaceKeyEvent, UUID) -> Bool
    let onTrackpadFeedbackChange: (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?

    func makeUIView(context: Context) -> GhosttyCompositeViewportContainerView {
        let view = GhosttyCompositeViewportContainerView()
        view.backgroundColor = terminalTheme.terminalBackgroundUIColor
        view.updateSelectionHandleStyle(
            terminalTheme.terminalChromeStyle,
            separatorColor: terminalTheme.terminalCompositeSeparatorUIColor
        )
        return view
    }

    func updateUIView(_ view: GhosttyCompositeViewportContainerView, context: Context) {
        view.backgroundColor = terminalTheme.terminalBackgroundUIColor
        view.updateSelectionHandleStyle(
            terminalTheme.terminalChromeStyle,
            separatorColor: terminalTheme.terminalCompositeSeparatorUIColor
        )
        view.update(
            projection: projection,
            surfaceLookup: surfaceLookup,
            trackpadDriver: trackpadDriver,
            onSurfaceTap: onSurfaceTap,
            onPreviewSelection: onPreviewSelection,
            onWindowSwipe: onWindowSwipe,
            sendKeyEventToSurface: sendKeyEventToSurface,
            onTrackpadFeedbackChange: onTrackpadFeedbackChange,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll
        )
    }

    static func dismantleUIView(
        _ view: GhosttyCompositeViewportContainerView,
        coordinator: ()
    ) {
        view.dismantle()
    }
}

private final class GhosttyCompositeViewportContainerView: UIView,
    UIGestureRecognizerDelegate,
    @preconcurrency UIEditMenuInteractionDelegate
{
    private var surfaceLookup = GhosttyManagedSurfaceLookup.empty
    private var projection = GhosttyTerminalViewportPresentationProjection.empty
    private var containersBySurfaceID: [UUID: GhosttyPaneScrollContainerView] = [:]
    private var focusedSeparatorColor = UIColor.clear.cgColor
    private var separatorColor = UIColor.clear
    private var trackpadDriver: GhosttyKeyboardCursorTrackpadDriver?

    private var onSurfaceTap: ((UUID, Bool) -> Void)?
    private var onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    private var onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    private var sendKeyEventToSurface: ((GhosttySurfaceKeyEvent, UUID) -> Bool)?
    private var onTrackpadFeedbackChange: ((GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void)?
    private var isMouseCaptured: (UUID) -> Bool = { _ in false }
    private var submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?

    private var activePanAxis: GhosttySurfacePanGesture.Axis?
    private var didNavigateForActivePan = false
    private weak var localSelectionSurface: GhosttyManagedSurface?
    private weak var localSelectionControlSurface: GhosttyKitControlSurface?
    private var longPressOriginalPoint: CGPoint?
    private var selectionSnapshot = GhosttyLocalSelectionSnapshot.inactive
    private var previewSelectionContext = TerminalPreviewSelectionContext()

    private lazy var startSelectionHandle = makeSelectionHandle(
        endpoint: GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START
    )
    private lazy var endSelectionHandle = makeSelectionHandle(
        endpoint: GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END
    )

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleSurfacePan(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var surfaceTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSurfaceTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var selectionLongPressRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.45
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        contentMode = .redraw
        panRecognizer.delegate = self
        surfaceTapRecognizer.require(toFail: selectionLongPressRecognizer)
        addGestureRecognizer(panRecognizer)
        addGestureRecognizer(selectionLongPressRecognizer)
        addGestureRecognizer(surfaceTapRecognizer)
        addInteraction(selectionEditMenuInteraction)
        addSubview(startSelectionHandle)
        addSubview(endSelectionHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let inset = (GhosttySelectionHandleView.hitTargetSize - startSelectionHandle.bounds.width) / 2
        guard !startSelectionHandle.isHidden,
              !endSelectionHandle.isHidden,
              startSelectionHandle.frame.insetBy(dx: -inset, dy: -inset).contains(point),
              endSelectionHandle.frame.insetBy(dx: -inset, dy: -inset).contains(point)
        else { return super.hitTest(point, with: event) }

        let startDistance = point.squaredDistance(to: startSelectionHandle.center)
        let endDistance = point.squaredDistance(to: endSelectionHandle.center)
        let handle = startDistance <= endDistance
            ? startSelectionHandle
            : endSelectionHandle
        return handle.hitTest(convert(point, to: handle), with: event)
    }

    func updateSelectionHandleStyle(
        _ style: GhosttyTerminalChromeStyle,
        separatorColor: UIColor
    ) {
        let fillColor = UIColor(style.accent)
        let borderColor = UIColor(style.accentForeground).cgColor
        let styleChanged = focusedSeparatorColor != fillColor.cgColor
            || !self.separatorColor.isEqual(separatorColor)
            || startSelectionHandle.layer.borderColor != borderColor
        guard styleChanged else { return }
        focusedSeparatorColor = fillColor.cgColor
        self.separatorColor = separatorColor
        startSelectionHandle.backgroundColor = fillColor
        endSelectionHandle.backgroundColor = fillColor
        startSelectionHandle.layer.borderColor = borderColor
        endSelectionHandle.layer.borderColor = borderColor
        setNeedsDisplay()
    }

    func update(
        projection: GhosttyTerminalViewportPresentationProjection,
        surfaceLookup: GhosttyManagedSurfaceLookup,
        trackpadDriver: GhosttyKeyboardCursorTrackpadDriver,
        onSurfaceTap: ((UUID, Bool) -> Void)?,
        onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?,
        onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?,
        sendKeyEventToSurface: @escaping (GhosttySurfaceKeyEvent, UUID) -> Bool,
        onTrackpadFeedbackChange: @escaping (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void,
        isMouseCaptured: @escaping (UUID) -> Bool,
        submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    ) {
        let topologyChanged = self.projection != projection
        self.projection = projection
        self.surfaceLookup = surfaceLookup
        self.trackpadDriver = trackpadDriver
        self.onSurfaceTap = onSurfaceTap
        self.onPreviewSelection = onPreviewSelection
        self.onWindowSwipe = onWindowSwipe
        self.sendKeyEventToSurface = sendKeyEventToSurface
        self.onTrackpadFeedbackChange = onTrackpadFeedbackChange
        self.isMouseCaptured = isMouseCaptured
        self.submitMouseButton = submitMouseButton
        self.submitMousePosition = submitMousePosition
        self.submitMouseScroll = submitMouseScroll

        if topologyChanged {
            setNeedsDisplay()
        }

        if activePanAxis == .horizontal, !projection.canNavigateWindows {
            resetActivePanState()
        }
        syncVisibleSurfaces()
        if localSelectionSurface != nil {
            if exactLocalSelectionSurface() == nil {
                cancelLocalSelectionInteraction()
            } else {
                layoutSelectionHandles()
            }
        }
        if localSelectionSurface == nil {
            restoreLocalSelectionIfPresent()
        }
        flushLayoutIfPossible()
    }

    func dismantle() {
        disableInteractions()
        resetActivePanState()
        for container in containersBySurfaceID.values {
            retire(container: container)
        }
        containersBySurfaceID.removeAll()
        surfaceLookup = .empty
        projection = .empty

    }

    private func disableInteractions() {
        cancelLocalSelectionInteraction()
        onSurfaceTap = nil
        onPreviewSelection = nil
        onWindowSwipe = nil
        sendKeyEventToSurface = nil
        onTrackpadFeedbackChange = nil
        isMouseCaptured = { _ in false }
        submitMouseButton = nil
        submitMousePosition = nil
        submitMouseScroll = nil
        trackpadDriver = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutVisibleSurfaces()
        layoutSelectionHandles()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)

        let visiblePanes = projection.panes.filter { $0.visibleFrame != nil }
        guard visiblePanes.count > 1,
              let grid = projection.windowGrid,
              let cell = projection.cellMetrics,
              let layout = GhosttyCompositeViewportLayout(
                  bounds: bounds,
                  grid: grid,
                  cellMetrics: cell
              ),
              let context = UIGraphicsGetCurrentContext()
        else { return }

        let canvas = CGRect(origin: layout.origin, size: layout.canvasSize)
        let separatorLineWidth: CGFloat = 1
        let focusedSeparatorLineWidth: CGFloat = 2
        let separators = GhosttyPaneSeparatorLayout.segments(
            for: visiblePanes.compactMap { pane in
                pane.visibleFrame.map {
                    GhosttyPaneSeparatorLayout.Pane(id: pane.id, frame: $0)
                }
            }
        )
        let separatorPath = CGMutablePath()
        for separator in separators {
            addSeparator(
                to: separatorPath,
                frame: separator.frame(
                    origin: layout.origin,
                    cellSize: layout.cellSize,
                    lineWidth: separatorLineWidth
                ),
                clippedTo: canvas
            )
        }

        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.setFillColor(separatorColor.cgColor)
        context.addPath(separatorPath)
        context.fillPath()

        let focusedPaneID = visiblePanes.first(where: \.isFocused)?.id
        let focusedPath = CGMutablePath()
        for separator in separators {
            guard let range = separator.focusedRange(
                focusedPaneID: focusedPaneID,
                paneCount: visiblePanes.count
            ) else { continue }
            addSeparator(
                to: focusedPath,
                frame: separator.frame(
                    origin: layout.origin,
                    cellSize: layout.cellSize,
                    lineWidth: focusedSeparatorLineWidth,
                    range: range
                ),
                clippedTo: canvas
            )
        }
        context.setFillColor(focusedSeparatorColor)
        context.addPath(focusedPath)
        context.fillPath()
    }

    private func addSeparator(
        to path: CGMutablePath,
        frame: CGRect,
        clippedTo canvas: CGRect
    ) {
        let clipped = frame.intersection(canvas)
        guard !clipped.isNull, !clipped.isEmpty else { return }

        let scale = effectiveScale
        let pixelAligned = CGRect(
            x: (clipped.minX * scale).rounded() / scale,
            y: (clipped.minY * scale).rounded() / scale,
            width: max((clipped.width * scale).rounded() / scale, 1 / scale),
            height: max((clipped.height * scale).rounded() / scale, 1 / scale)
        ).intersection(canvas)
        guard !pixelAligned.isNull, !pixelAligned.isEmpty else { return }
        path.addRect(pixelAligned)
    }

    private func syncVisibleSurfaces() {
        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos()
            : nil
        defer {
            if let startedAt {
                GhosttyRuntimeTrace.perf(
                    "viewport.sync panes=\(projection.panes.count) attached=\(containersBySurfaceID.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
                )
            }
        }

        let desiredIDs = Set(projection.panes.compactMap { pane in
            pane.visibleFrame == nil ? nil : pane.id
        })
        let retiredSurfaceIDs = containersBySurfaceID.keys.filter {
            !desiredIDs.contains($0)
        }
        for surfaceID in retiredSurfaceIDs {
            guard let container = containersBySurfaceID.removeValue(forKey: surfaceID)
            else { continue }
            retire(container: container)
        }

        for pane in projection.panes where pane.visibleFrame != nil {
            guard let surface = surfaceLookup.managedSurface(for: pane.id) else {
                if let container = containersBySurfaceID.removeValue(forKey: pane.id) {
                    retire(container: container)
                }
                continue
            }
            let container = containersBySurfaceID[pane.id] ?? GhosttyPaneScrollContainerView()
            containersBySurfaceID[pane.id] = container
            container.backgroundColor = .clear
            _ = container.update(
                surface: surface,
                displayScale: effectiveScale,
                submitRouteForwardedMouseScroll: submitMouseScroll,
                submitRouteForwardedMousePosition: submitMousePosition
            )
            if container.superview !== self {
                container.removeFromSuperview()
                addSubview(container)
            }
        }
        bringSubviewToFront(startSelectionHandle)
        bringSubviewToFront(endSelectionHandle)
    }

    private func retire(container: GhosttyPaneScrollContainerView) {
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    private func layoutVisibleSurfaces() {
        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos()
            : nil
        guard let grid = projection.windowGrid,
              let cell = projection.cellMetrics,
              let layout = GhosttyCompositeViewportLayout(
                  bounds: bounds,
                  grid: grid,
                  cellMetrics: cell
              )
        else { return }
        var changed = false
        for pane in projection.panes {
            guard let visibleFrame = pane.visibleFrame,
                  let container = containersBySurfaceID[pane.id]
            else { continue }
            let targetFrame = layout.frame(for: visibleFrame)
            guard container.frame != targetFrame else { continue }
            container.frame = targetFrame
            changed = true
        }
        if let startedAt {
            GhosttyRuntimeTrace.perf(
                "viewport.layout bounds=\(ghosttyDiagnosticRect(bounds)) panes=\(containersBySurfaceID.count) changed=\(changed) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
            )
        }
    }

    private func flushLayoutIfPossible() {
        guard bounds.width > 1, bounds.height > 1 else {
            setNeedsLayout()
            return
        }
        layoutVisibleSurfaces()
    }

    @objc
    private func handleSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginTerminalLongPress(recognizer)
        case .changed:
            updateTerminalLongPress(recognizer)
        case .ended:
            endTerminalLongPress()
        case .cancelled, .failed:
            reconcileLocalSelectionAfterLongPress()
        case .possible:
            break
        @unknown default:
            cancelLocalSelectionInteraction()
        }
    }

    private func beginTerminalLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let driver = trackpadDriver,
              let (_, surface, _) = visibleSurface(
                  at: recognizer.location(in: self)
              )
        else { return }

        cancelLocalSelectionInteraction()
        localSelectionSurface = surface
        localSelectionControlSurface = surface.controlSurface
        longPressOriginalPoint = recognizer.location(in: surface.view)
        surface.onLocalSelectionGeometryChange = { [weak self] in
            self?.refreshLocalSelectionGeometry()
        }
        driver.begin(
            owner: self,
            at: recognizer.location(in: surface.view),
            sendKeyEvent: { [weak self] event in
                guard self?.exactLocalSelectionSurface() != nil else { return false }
                return self?.sendKeyEventToSurface?(event, surface.id) == true
            },
            onFeedbackChange: { [weak self] state in
                self?.onTrackpadFeedbackChange?(state)
            }
        )
    }

    private func updateTerminalLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let driver = trackpadDriver,
              let (surface, _) = exactLocalSelectionSurface()
        else {
            cancelLocalSelectionInteraction()
            return
        }
        _ = driver.update(owner: self, at: recognizer.location(in: surface.view))
    }

    private func endTerminalLongPress() {
        guard let driver = trackpadDriver else {
            cancelLocalSelectionInteraction()
            return
        }
        let didSteer = driver.end(owner: self)
        guard didSteer == false else {
            reconcileLocalSelectionAfterLongPress()
            return
        }

        guard let point = longPressOriginalPoint,
              let (_, control) = exactLocalSelectionSurface()
        else {
            cancelLocalSelectionInteraction()
            return
        }

        switch control.selectLink(at: point) {
        case .match(let snapshot, let explicitTarget):
            longPressOriginalPoint = nil
            previewSelectionContext.setAutomaticSelection(
                visibleText: control.readSelection(),
                explicitTarget: explicitTarget
            )
            applySelectionOutcome(.snapshot(snapshot), presentMenu: true)
        case .noMatch:
            longPressOriginalPoint = nil
            previewSelectionContext.selectionDidChange()
            applySelectionOutcome(control.selectWord(at: point), presentMenu: true)
        case .unavailable:
            reconcileLocalSelectionAfterLongPress()
        }
    }

    private func presentSelectionCopyMenu() {
        guard selectionSnapshot.isActive,
              exactLocalSelectionSurface() != nil,
              let anchor = selectionMenuAnchorHandle
        else { return }
        selectionEditMenuInteraction.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: anchor.center
            )
        )
    }

    private var selectionMenuAnchorHandle: GhosttySelectionHandleView? {
        if !endSelectionHandle.isHidden { return endSelectionHandle }
        if !startSelectionHandle.isHidden { return startSelectionHandle }
        return nil
    }

    @objc
    private func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let (surfaceID, surface, container) = visibleSurface(
                  at: recognizer.location(in: self)
              )
        else { return }

        if selectionSnapshot.isActive,
           let (_, control) = exactLocalSelectionSurface() {
            _ = control.clearSelection()
            cancelLocalSelectionInteraction()
            return
        }

        let visiblePaneCount = projection.panes.lazy.filter {
            $0.visibleFrame != nil
        }.count
        let shouldShowKeyboard = visiblePaneCount == 1
            || projection.focusedSurfaceID == surfaceID
        if !shouldShowKeyboard {
            onSurfaceTap?(surfaceID, false)
            return
        }

        let mouseCaptured = isMouseCaptured(surfaceID)
        if container.consumeMomentumCatchTap() == true {
            return
        }
        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: surface.view),
            mouseCaptured: mouseCaptured
        ) {
            switch action {
            case .activateInput:
                onSurfaceTap?(surfaceID, true)
            case .mousePosition(let position):
                _ = submitMousePosition?(surfaceID, position, [])
            case .mouseButton(let event):
                _ = submitMouseButton?(surfaceID, event)
            }
        }
    }

    @objc
    private func handleSurfacePan(_ recognizer: UIPanGestureRecognizer) {
        guard let phase = GhosttySurfacePanGesture.Phase(recognizer.state) else { return }

        if phase == .began {
            resetActivePanState()
        }
        defer { resetActivePanStateIfEnded(phase) }

        guard visibleSurface(at: recognizer.location(in: self)) != nil
        else { return }

        if longPressOriginalPoint != nil {
            return
        }

        let translation = recognizer.translation(in: self)
        activePanAxis = GhosttySurfacePanGesture.axis(
            forTranslation: translation,
            currentAxis: activePanAxis
        )
        if activePanAxis == .horizontal {
            routeHorizontalNavigation(
                translation: translation,
                velocity: recognizer.velocity(in: self)
            )
        }
    }

    private func routeHorizontalNavigation(translation: CGPoint, velocity: CGPoint) {
        guard projection.canNavigateWindows,
              let direction = GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: translation,
                velocity: velocity,
                axis: .horizontal,
                didNavigate: didNavigateForActivePan
              )
        else { return }

        didNavigateForActivePan = true
        onWindowSwipe?(direction.runtimeSelectionDirection)
    }

    private func resetActivePanStateIfEnded(_ phase: GhosttySurfacePanGesture.Phase) {
        if phase == .ended || phase == .cancelled {
            resetActivePanState()
        }
    }

    private func resetActivePanState() {
        activePanAxis = nil
        didNavigateForActivePan = false
    }

    private func exactLocalSelectionSurface()
        -> (GhosttyManagedSurface, GhosttyKitControlSurface)? {
        guard let recordedSurface = projectedLocalSelectionSurface(),
              let recordedControl = localSelectionControlSurface,
              recordedSurface.controlSurface === recordedControl
        else { return nil }
        return (recordedSurface, recordedControl)
    }

    private func projectedLocalSelectionSurface() -> GhosttyManagedSurface? {
        guard let recordedSurface = localSelectionSurface,
              projection.panes.contains(where: {
                  $0.id == recordedSurface.id && $0.visibleFrame != nil
              }),
              containersBySurfaceID[recordedSurface.id] != nil,
              surfaceLookup.managedSurface(for: recordedSurface.id) === recordedSurface,
              recordedSurface.view.isDescendant(of: self)
        else { return nil }
        return recordedSurface
    }

    private func refreshLocalSelectionGeometry() {
        guard let surface = projectedLocalSelectionSurface() else {
            cancelLocalSelectionInteraction()
            return
        }
        let control = surface.controlSurface
        localSelectionControlSurface = control
        // Output during neutral/steering must not resurrect an older selection.
        guard longPressOriginalPoint == nil, selectionSnapshot.isActive else { return }
        applySelectionOutcome(control.selectionSnapshot(), presentMenu: false)
    }

    private func reconcileLocalSelectionAfterLongPress() {
        _ = trackpadDriver?.cancel(owner: self)
        longPressOriginalPoint = nil
        guard let surface = projectedLocalSelectionSurface() else {
            cancelLocalSelectionInteraction()
            return
        }
        localSelectionControlSurface = surface.controlSurface
        applySelectionOutcome(
            surface.controlSurface.selectionSnapshot(),
            presentMenu: false
        )
    }

    private func restoreLocalSelectionIfPresent() {
        guard localSelectionSurface == nil,
              let surfaceID = projection.focusedSurfaceID,
              containersBySurfaceID[surfaceID] != nil,
              let surface = surfaceLookup.managedSurface(for: surfaceID),
              surface.view.isDescendant(of: self),
              case .snapshot(let snapshot) = surface.controlSurface.selectionSnapshot(),
              snapshot.isActive
        else { return }

        localSelectionSurface = surface
        localSelectionControlSurface = surface.controlSurface
        previewSelectionContext.selectionDidChange()
        surface.onLocalSelectionGeometryChange = { [weak self] in
            self?.refreshLocalSelectionGeometry()
        }
        selectionSnapshot = snapshot
        layoutSelectionHandles()
    }

    private func applySelectionOutcome(
        _ outcome: GhosttyLocalSelectionOutcome,
        presentMenu: Bool
    ) {
        guard case .snapshot(let snapshot) = outcome else {
            cancelLocalSelectionInteraction()
            return
        }
        selectionSnapshot = snapshot
        guard selectionSnapshot.isActive else {
            cancelLocalSelectionInteraction()
            return
        }
        layoutSelectionHandles()
        if presentMenu { presentSelectionCopyMenu() }
    }

    private func cancelLocalSelectionInteraction() {
        _ = trackpadDriver?.cancel(owner: self)
        localSelectionSurface?.onLocalSelectionGeometryChange = nil
        selectionEditMenuInteraction.dismissMenu()
        localSelectionSurface = nil
        localSelectionControlSurface = nil
        longPressOriginalPoint = nil
        selectionSnapshot = .inactive
        previewSelectionContext.selectionDidChange()
        startSelectionHandle.isHidden = true
        endSelectionHandle.isHidden = true
    }

    private func makeSelectionHandle(
        endpoint: ghostty_terminal_surface_selection_endpoint_e
    ) -> GhosttySelectionHandleView {
        let handle = GhosttySelectionHandleView(endpoint: endpoint)
        handle.isHidden = true
        handle.addGestureRecognizer(UIPanGestureRecognizer(
            target: self,
            action: #selector(handleSelectionEndpointPan(_:))
        ))
        return handle
    }

    @objc
    private func handleSelectionEndpointPan(_ recognizer: UIPanGestureRecognizer) {
        guard let handle = recognizer.view as? GhosttySelectionHandleView,
              let (surface, control) = exactLocalSelectionSurface()
        else {
            cancelLocalSelectionInteraction()
            return
        }
        if recognizer.state == .began {
            previewSelectionContext.selectionDidChange()
            selectionEditMenuInteraction.dismissMenu()
        }
        if recognizer.state == .changed {
            applySelectionOutcome(
                control.setSelectionEndpoint(
                    handle.endpoint,
                    at: recognizer.location(in: surface.view)
                ),
                presentMenu: false
            )
        } else if recognizer.state == .ended || recognizer.state == .cancelled {
            presentSelectionCopyMenu()
        }
    }

    private func layoutSelectionHandles() {
        guard selectionSnapshot.isActive,
              let (surface, _) = exactLocalSelectionSurface()
        else {
            startSelectionHandle.isHidden = true
            endSelectionHandle.isHidden = true
            return
        }
        position(startSelectionHandle, surface: surface)
        position(endSelectionHandle, surface: surface)
    }

    private func position(
        _ handle: GhosttySelectionHandleView,
        surface: GhosttyManagedSurface
    ) {
        let isStart = handle.endpoint == GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START
        let rect = isStart ? selectionSnapshot.start : selectionSnapshot.end
        guard let rect else {
            handle.isHidden = true
            return
        }
        let anchor = isStart
            ? CGPoint(x: rect.minX, y: rect.minY)
            : CGPoint(x: rect.maxX, y: rect.maxY)
        let rawCenter = surface.view.convert(anchor, to: self)
        let inset = handle.bounds.width / 2
        handle.center = CGPoint(
            x: min(max(rawCenter.x, bounds.minX + inset), bounds.maxX - inset),
            y: min(max(rawCenter.y, bounds.minY + inset), bounds.maxY - inset)
        )
        handle.isHidden = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panRecognizer || otherGestureRecognizer === panRecognizer else {
            return false
        }
        return gestureRecognizer is UIPanGestureRecognizer &&
            otherGestureRecognizer is UIPanGestureRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        _ = gestureRecognizer
        guard let touchedView = touch.view else { return true }
        return !touchedView.isDescendant(of: startSelectionHandle)
            && !touchedView.isDescendant(of: endSelectionHandle)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panRecognizer else { return true }
        return GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
            topLevelCount: projection.windowCount,
            velocity: panRecognizer.velocity(in: self)
        )
    }

    private var effectiveScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }

    private func visibleSurface(
        at point: CGPoint
    ) -> (UUID, GhosttyManagedSurface, GhosttyPaneScrollContainerView)? {
        for pane in projection.panes.reversed() where pane.visibleFrame != nil {
            guard let container = containersBySurfaceID[pane.id],
                  container.frame.contains(point),
                  let surface = surfaceLookup.managedSurface(for: pane.id),
                  surface.rendererIsAvailable
            else { continue }
            return (pane.id, surface, container)
        }
        return nil
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        _ = interaction
        _ = configuration
        _ = suggestedActions
        guard selectionSnapshot.isActive,
              exactLocalSelectionSurface() != nil,
              selectionMenuAnchorHandle != nil
        else { return nil }

        guard let (_, control) = exactLocalSelectionSurface(),
              let selectedText = control.readSelection(),
              !selectedText.isEmpty
        else { return nil }

        var actions: [UIMenuElement] = []
        if onPreviewSelection != nil,
           previewSelectionContext.candidate(for: selectedText) != nil {
            actions.append(UIAction(
                title: "Preview",
                image: UIImage(systemName: "eye")
            ) { [weak self] _ in
                guard let self,
                      let (surface, control) = self.exactLocalSelectionSurface(),
                      let selectedText = control.readSelection(),
                      let candidate = self.previewSelectionContext.candidate(
                          for: selectedText
                      )
                else { return }
                self.onPreviewSelection?(surface.id, candidate)
            })
        }
        actions.append(
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let (_, control) = self?.exactLocalSelectionSurface(),
                      let text = control.readSelection(),
                      !text.isEmpty
                else { return }
                UIPasteboard.general.string = text
            }
        )
        return UIMenu(children: actions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        _ = interaction
        _ = configuration
        return selectionMenuAnchorHandle?.frame ?? .zero
    }
}

private final class GhosttySelectionHandleView: UIView {
    static let hitTargetSize: CGFloat = 44
    let endpoint: ghostty_terminal_surface_selection_endpoint_e

    init(endpoint: ghostty_terminal_surface_selection_endpoint_e) {
        self.endpoint = endpoint
        super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        layer.borderWidth = 1
        layer.cornerRadius = 9
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        _ = event
        let inset = (Self.hitTargetSize - bounds.width) / 2
        return bounds.insetBy(dx: -inset, dy: -inset).contains(point)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

private extension GhosttySurfacePanGesture.WindowNavigationDirection {
    var runtimeSelectionDirection: GhosttyRuntimeSelectionDirection {
        switch self {
        case .previous: .previous
        case .next: .next
        }
    }
}
