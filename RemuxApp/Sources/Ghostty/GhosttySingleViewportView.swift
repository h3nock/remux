import GhosttyKit
import SwiftUI
import UIKit

/// What a pane's selection takes from the backend that keeps the pane's history, beyond what the pane's
/// terminal holds.
struct GhosttyTerminalSelectionSource {
    /// Reads the selection; optional menu inspection suppresses result notices.
    let readText: (_ surfaceID: UUID, _ reportResult: Bool) async -> String?
    /// Expands an automatic selection; true authorizes destination inspection. False can still leave
    /// a valid visible expansion for Copy. Refresh selection geometry regardless of the result.
    let completeLink: (UUID, CGPoint, GhosttyLongPressSelection) async -> Bool
}

/// Hosts every visible pane in the active tmux window at its authoritative
/// grid rectangle using one shared, unscaled cell metric.
struct GhosttyCompositeViewportView: View {
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let projection: GhosttyTerminalViewportPresentationProjection
    /// The terminal's size, which the area this view is given may be shorter than, as while the keyboard or the
    /// composer covers the bottom of the screen; nil to fill the area.
    var canvasSize: CGSize? = nil
    let terminalTheme: TerminalTheme
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let onSurfaceTap: ((UUID, Bool) -> Void)?
    let onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let sendKeyEventToSurface: (GhosttySurfaceKeyEvent, UUID) -> Bool
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let selectionSource: GhosttyTerminalSelectionSource?

    var body: some View {
        GhosttyCompositeViewportRepresentable(
            surfaceLookup: surfaceLookup,
            projection: projection,
            canvasSize: canvasSize,
            terminalTheme: terminalTheme,
            trackpadDriver: trackpadDriver,
            onSurfaceTap: onSurfaceTap,
            onPreviewSelection: onPreviewSelection,
            onWindowSwipe: onWindowSwipe,
            sendKeyEventToSurface: sendKeyEventToSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            selectionSource: selectionSource
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GhosttyCompositeViewportRepresentable: UIViewRepresentable {
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let projection: GhosttyTerminalViewportPresentationProjection
    let canvasSize: CGSize?
    let terminalTheme: TerminalTheme
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let onSurfaceTap: ((UUID, Bool) -> Void)?
    let onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    let onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    let sendKeyEventToSurface: (GhosttySurfaceKeyEvent, UUID) -> Bool
    let isMouseCaptured: (UUID) -> Bool
    let submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let selectionSource: GhosttyTerminalSelectionSource?

    func makeUIView(context: Context) -> GhosttyCompositeViewportHostView {
        let host = GhosttyCompositeViewportHostView()
        host.backgroundColor = terminalTheme.terminalBackgroundUIColor
        host.viewport.backgroundColor = terminalTheme.terminalBackgroundUIColor
        host.viewport.updateSeparatorColor(terminalTheme.terminalCompositeSeparatorUIColor)
        return host
    }

    func updateUIView(_ host: GhosttyCompositeViewportHostView, context: Context) {
        host.backgroundColor = terminalTheme.terminalBackgroundUIColor
        host.canvasSize = canvasSize
        let view = host.viewport
        view.backgroundColor = terminalTheme.terminalBackgroundUIColor
        view.updateSeparatorColor(terminalTheme.terminalCompositeSeparatorUIColor)
        view.update(
            projection: projection,
            surfaceLookup: surfaceLookup,
            trackpadDriver: trackpadDriver,
            onSurfaceTap: onSurfaceTap,
            onPreviewSelection: onPreviewSelection,
            onWindowSwipe: onWindowSwipe,
            sendKeyEventToSurface: sendKeyEventToSurface,
            isMouseCaptured: isMouseCaptured,
            submitMouseButton: submitMouseButton,
            submitMousePosition: submitMousePosition,
            submitMouseScroll: submitMouseScroll,
            selectionSource: selectionSource
        )
    }

    static func dismantleUIView(
        _ host: GhosttyCompositeViewportHostView,
        coordinator: ()
    ) {
        host.viewport.dismantle()
    }
}

/// How far the terminal's canvas moves up inside an area shorter than it, as while the keyboard or the composer covers
/// the bottom of the screen. Worked out afresh when the area, the canvas or the surface taking the input changes: just
/// far enough that `keptLine`, the bottom of the input surface's cursor row or of what is drawn below it, is above the
/// area's bottom edge, but never so far that the cursor's row leaves the top. As output arrives the canvas follows what
/// is drawn lower, and holds while up to `heldRows` rows leave the bottom, such as an agent's hints or status line
/// under its input, so rows that come and go there don't move the whole picture each time; a bigger change works it
/// out afresh. While the input surface shows its history the canvas stays where it is, under the reader. On whole
/// pixels, so the picture isn't resampled.
struct GhosttyKeyboardSlide: Equatable {
    /// What a slide is worked out from, in the canvas's points.
    struct Inputs: Equatable {
        /// The surface taking the input, by its renderer's layer; nil without one.
        var surface: ObjectIdentifier?
        var areaHeight: CGFloat
        var canvasHeight: CGFloat
        /// The line kept above the area's bottom edge; nil keeps the canvas's bottom.
        var keptLine: CGFloat?
        /// How far the cursor's row is below the grid's top, which a move up doesn't exceed; nil without a cursor.
        var cursorRoom: CGFloat?
        /// A row's height, the unit of `heldRows`.
        var rowHeight: CGFloat
        /// Whether the input surface shows its history, above its live rows.
        var isScrolledBack: Bool
        var scale: CGFloat
    }

    /// How many rows may leave the bottom without bringing the canvas back down. Replayed on recordings of real agents
    /// and of a shell, 2 gave the fewest moves among holds that never leave a row drawn below the input covered.
    static let heldRows: CGFloat = 2

    /// How far the canvas moves up.
    let pan: CGFloat
    /// What it was worked out from.
    let inputs: Inputs

    /// The slide for `inputs`, following on from `previous`, the slide shown.
    static func next(after previous: Self?, inputs: Inputs) -> Self {
        let covered = inputs.canvasHeight - inputs.areaHeight
        guard covered > 0 else { return Self(pan: 0, inputs: inputs) }
        let scale = max(inputs.scale, 1)
        let shownPan = previous?.pan ?? 0
        if inputs.isScrolledBack {
            return Self(pan: min(shownPan, (covered * scale).rounded(.down) / scale), inputs: inputs)
        }
        let limit = (min(covered, inputs.cursorRoom ?? covered) * scale).rounded(.down) / scale
        let fresh = min(
            (max((inputs.keptLine ?? inputs.canvasHeight) - inputs.areaHeight, 0) * scale).rounded() / scale,
            limit
        )
        guard let previous,
              previous.inputs.surface == inputs.surface,
              previous.inputs.areaHeight == inputs.areaHeight,
              previous.inputs.canvasHeight == inputs.canvasHeight
        else { return Self(pan: fresh, inputs: inputs) }
        let held = min(shownPan, limit)
        let isWithinHeldRows = held - fresh <= heldRows * inputs.rowHeight + 0.5 / scale
        return Self(pan: isWithinHeldRows ? max(fresh, held) : fresh, inputs: inputs)
    }
}

/// Shows the composite viewport in the terminal area, which clips it. The viewport keeps the canvas size, the
/// terminal's, and moves up as `GhosttyKeyboardSlide` describes while the area is shorter, as while the keyboard or
/// the composer covers the bottom of the screen.
///
/// A change of the area's size moves it in this view's layout, run as soon as the size is set, so inside the
/// keyboard's animation that sets it: the viewport moves with the keyboard and the toolbar on it. A move for new rows,
/// for the input surface returning to its live rows, or for another surface taking the input, is immediate, as a
/// terminal scrolls.
private final class GhosttyCompositeViewportHostView: UIView {
    let viewport = GhosttyCompositeViewportContainerView()
    var canvasSize: CGSize? {
        didSet {
            guard canvasSize != oldValue else { return }
            setNeedsLayout()
        }
    }
    /// The slide shown.
    private var slide: GhosttyKeyboardSlide?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(viewport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The area's size is set inside the keyboard's animation, but on a phone the layout pass it asks for runs later,
    // outside it, where the canvas's move would be a jump. So the canvas is laid out at once, inside the animation the
    // size change runs in, as UIKit resizes autoresizing subviews.
    override var frame: CGRect {
        didSet { layOutForSizeChange(from: oldValue.size, to: frame.size) }
    }

    override var bounds: CGRect {
        didSet { layOutForSizeChange(from: oldValue.size, to: bounds.size) }
    }

    private func layOutForSizeChange(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize != newSize else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = canvasSize ?? bounds.size
        let pan = updateSlide(canvasHeight: size.height, reason: "layout")
        viewport.frame = CGRect(origin: CGPoint(x: 0, y: -pan), size: size)
        // The input surface only moves the canvas while the area covers part of it.
        let isCovered = bounds.height < size.height
        if isCovered != (viewport.onSlideInputChange != nil) {
            viewport.onSlideInputChange = isCovered ? { [weak self] in self?.followSlideInputs() } : nil
        }
    }

    private func followSlideInputs() {
        let previousPan = slide?.pan
        let pan = updateSlide(canvasHeight: viewport.bounds.height, reason: "input")
        guard pan != previousPan else { return }
        UIView.performWithoutAnimation {
            viewport.frame.origin.y = -pan
        }
    }

    private func updateSlide(canvasHeight: CGFloat, reason: String) -> CGFloat {
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        let inputs = viewport.keyboardSlideInputs(areaHeight: bounds.height, canvasHeight: canvasHeight, scale: scale)
        let previousPan = slide?.pan
        let next = GhosttyKeyboardSlide.next(after: slide, inputs: inputs)
        slide = next
        if GhosttyRuntimeTrace.tmuxViewportEnabled {
            GhosttyRuntimeTrace.tmuxViewport(
                "viewport.slide reason=\(reason) area=\(inputs.areaHeight) canvas=\(inputs.canvasHeight) "
                    + "surface=\(inputs.surface.map { String(UInt(bitPattern: $0.hashValue), radix: 16) } ?? "none") "
                    + "held=\(inputs.isScrolledBack) line=\(inputs.keptLine.map { "\($0)" } ?? "nil") "
                    + "room=\(inputs.cursorRoom.map { "\($0)" } ?? "nil") row=\(inputs.rowHeight) "
                    + "pan=\(next.pan) previous=\(previousPan.map { "\($0)" } ?? "nil")"
            )
        }
        return next.pan
    }
}

private final class GhosttyCompositeViewportContainerView: UIView,
    UIGestureRecognizerDelegate,
    @preconcurrency UIEditMenuInteractionDelegate
{
    private var surfaceLookup = GhosttyManagedSurfaceLookup.empty
    private var projection = GhosttyTerminalViewportPresentationProjection.empty
    private var containersBySurfaceID: [UUID: GhosttyPaneScrollContainerView] = [:]
    /// The panes' lines, behind the panes.
    private let linesView = GhosttyPaneLinesUIView()
    /// The backend's popup, in front of the panes while it shows, and behind the selection's handles.
    private let popupView = GhosttyTerminalPopupFrameView()
    private var separatorColor = UIColor.clear
    private var trackpadDriver: GhosttyKeyboardCursorTrackpadDriver?

    private var onSurfaceTap: ((UUID, Bool) -> Void)?
    private var onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    private var onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?
    private var sendKeyEventToSurface: ((GhosttySurfaceKeyEvent, UUID) -> Bool)?
    private var isMouseCaptured: (UUID) -> Bool = { _ in false }
    private var submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    private var submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    private var selectionSource: GhosttyTerminalSelectionSource?

    /// Called on the main thread when what the keyboard slide works from changes: the input surface's renderer
    /// publishes different rows, the surface starts or stops showing its history, or another surface takes the input.
    /// Observed while set.
    var onSlideInputChange: (() -> Void)? {
        didSet { observeSlideInputs(notifying: false) }
    }
    private var inputRowsObserver: GhosttyFrameRowsObserver?
    private var isInputScrolledBack = false

    private var activePanAxis: GhosttySurfacePanGesture.Axis?
    private var didNavigateForActivePan = false
    private weak var localSelectionSurface: GhosttyManagedSurface?
    private weak var localSelectionControlSurface: GhosttyKitControlSurface?
    private var longPressOriginalPoint: CGPoint?
    /// The pane a terminal drag sends arrows to, through its re-grip window.
    private weak var arrowSurface: GhosttyManagedSurface?
    private var selectionSnapshot = GhosttyLocalSelectionSnapshot.inactive
    private var previewSelectionContext = TerminalPreviewSelectionContext()
    private var selectionMenuPreparation: Task<Void, Never>?
    private var selectionGeneration: UInt64 = 0
    private var preparedSelection: (context: SelectionMenuContext, text: String)?

    /// History endpoints identify a server selection; the visible text also protects local selections
    /// and the explicit hyperlink context from being reused after output or an edit.
    private struct SelectionMenuContext {
        let generation: UInt64
        let surface: GhosttyManagedSurface
        let control: GhosttyKitControlSurface
        let history: GhosttyHistorySelection?
        let visibleText: String
        let preview: TerminalPreviewSelectionContext

        var explicitTarget: String? { preview.explicitTarget(for: visibleText) }
    }

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

    /// Inside the re-grip window after a drag that sent arrows, a touch carries on at once, without the hold, so it
    /// begins on touch-down and keeps scrolling and the tap out of it.
    private lazy var arrowRegripRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleArrowRegrip(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(linesView)
        panRecognizer.delegate = self
        surfaceTapRecognizer.require(toFail: selectionLongPressRecognizer)
        surfaceTapRecognizer.require(toFail: arrowRegripRecognizer)
        addGestureRecognizer(panRecognizer)
        addGestureRecognizer(selectionLongPressRecognizer)
        addGestureRecognizer(arrowRegripRecognizer)
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

    func updateSeparatorColor(_ separatorColor: UIColor) {
        guard !self.separatorColor.isEqual(separatorColor) else { return }
        self.separatorColor = separatorColor
        flushLayoutIfPossible()
    }

    func update(
        projection: GhosttyTerminalViewportPresentationProjection,
        surfaceLookup: GhosttyManagedSurfaceLookup,
        trackpadDriver: GhosttyKeyboardCursorTrackpadDriver,
        onSurfaceTap: ((UUID, Bool) -> Void)?,
        onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?,
        onWindowSwipe: ((GhosttyRuntimeSelectionDirection) -> Void)?,
        sendKeyEventToSurface: @escaping (GhosttySurfaceKeyEvent, UUID) -> Bool,
        isMouseCaptured: @escaping (UUID) -> Bool,
        submitMouseButton: ((UUID, GhosttySurfaceMouseButtonEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMousePosition: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?,
        submitMouseScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        selectionSource: GhosttyTerminalSelectionSource?
    ) {
        self.projection = projection
        self.surfaceLookup = surfaceLookup
        self.trackpadDriver = trackpadDriver
        self.onSurfaceTap = onSurfaceTap
        self.onPreviewSelection = onPreviewSelection
        self.onWindowSwipe = onWindowSwipe
        self.sendKeyEventToSurface = sendKeyEventToSurface
        self.isMouseCaptured = isMouseCaptured
        self.submitMouseButton = submitMouseButton
        self.submitMousePosition = submitMousePosition
        self.submitMouseScroll = submitMouseScroll
        self.selectionSource = selectionSource

        if activePanAxis == .horizontal, !projection.canNavigateWindows {
            resetActivePanState()
        }
        syncVisibleSurfaces()
        if let arrowSurface, !isShown(arrowSurface) {
            cancelArrowGesture()
        }
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
        onSlideInputChange = nil
        for container in containersBySurfaceID.values {
            retire(container: container)
        }
        containersBySurfaceID.removeAll()
        retirePopup()
        surfaceLookup = .empty
        projection = .empty
    }

    private func disableInteractions() {
        cancelArrowGesture()
        cancelLocalSelectionInteraction()
        onSurfaceTap = nil
        onPreviewSelection = nil
        onWindowSwipe = nil
        sendKeyEventToSurface = nil
        isMouseCaptured = { _ in false }
        submitMouseButton = nil
        submitMousePosition = nil
        submitMouseScroll = nil
        selectionSource = nil
        trackpadDriver = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutVisibleSurfaces()
        layoutSelectionHandles()
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
            let container = containersBySurfaceID[pane.id] ?? makePaneContainer()
            containersBySurfaceID[pane.id] = container
            container.backgroundColor = .clear
            _ = container.update(
                surface: surface,
                displayScale: paneDisplayScale,
                submitRouteForwardedMouseScroll: submitMouseScroll,
                submitRouteForwardedMousePosition: submitMousePosition
            )
            if container.superview !== self {
                container.removeFromSuperview()
                addSubview(container)
            }
        }
        syncPopup()
        bringSubviewToFront(startSelectionHandle)
        bringSubviewToFront(endSelectionHandle)
        observeSlideInputs(notifying: true)
    }

    /// The surface that takes the terminal's input and shows its cursor: the popup's while one shows, otherwise the
    /// focused pane's.
    private var inputSurface: GhosttyManagedSurface? {
        guard let id = projection.popup?.id ?? projection.focusedSurfaceID else { return nil }
        guard let surface = surfaceLookup.managedSurface(for: id), isShown(surface) else { return nil }
        return surface
    }

    private func observeSlideInputs(notifying: Bool) {
        let layer = onSlideInputChange == nil
            ? nil
            : inputSurface.flatMap { GhosttyIOSurfaceFrame.rendererLayer(in: $0.view.layer) }
        guard inputRowsObserver?.layer !== layer else { return }
        inputRowsObserver = layer.map {
            GhosttyFrameRowsObserver(layer: $0) { [weak self] in self?.onSlideInputChange?() }
        }
        isInputScrolledBack = inputSurface?.scrollState.isScrolledBack ?? false
        if notifying { onSlideInputChange?() }
    }

    private func makePaneContainer() -> GhosttyPaneScrollContainerView {
        let container = GhosttyPaneScrollContainerView()
        container.onSurfaceScrollStateChange = { [weak self] in self?.noteInputScrollStateChange() }
        return container
    }

    /// Returning to the live rows, or leaving them, can leave the published rows as they were, as for a program that
    /// hides its cursor with output down to the last row: the slide hears of it here.
    private func noteInputScrollStateChange() {
        guard onSlideInputChange != nil else { return }
        let isScrolledBack = inputSurface?.scrollState.isScrolledBack ?? false
        guard isScrolledBack != isInputScrolledBack else { return }
        isInputScrolledBack = isScrolledBack
        onSlideInputChange?()
    }

    /// What the keyboard slide works from, in this view's coordinates for a canvas `canvasHeight` high, from the rows
    /// GhosttyKit published with the input surface's frame on screen. The kept line is the bottom of the cursor's row
    /// or of the lowest row with anything drawn on it, whichever is lower, lowered by the margin between the grid's
    /// last row and the canvas's bottom, so a last row in use keeps the whole canvas in view. Without a frame showing
    /// anything, there is no line to keep.
    func keyboardSlideInputs(
        areaHeight: CGFloat,
        canvasHeight: CGFloat,
        scale: CGFloat
    ) -> GhosttyKeyboardSlide.Inputs {
        var inputs = GhosttyKeyboardSlide.Inputs(
            surface: nil,
            areaHeight: areaHeight,
            canvasHeight: canvasHeight,
            keptLine: nil,
            cursorRoom: nil,
            rowHeight: 0,
            isScrolledBack: false,
            scale: scale
        )
        guard areaHeight < canvasHeight,
              let surface = inputSurface,
              let layer = GhosttyIOSurfaceFrame.rendererLayer(in: surface.view.layer)
        else { return inputs }
        inputs.surface = ObjectIdentifier(layer)
        inputs.isScrolledBack = surface.scrollState.isScrolledBack
        guard let grid = projection.windowGrid,
              let cell = projection.cellMetrics,
              let layout = GhosttyCompositeViewportLayout(
                  bounds: CGRect(x: 0, y: 0, width: bounds.width, height: canvasHeight),
                  grid: grid,
                  cellMetrics: cell
              ),
              let rows = GhosttyIOSurfaceFrame.publishedRows(in: layer)
        else { return inputs }
        inputs.rowHeight = layout.cellSize.height
        let cursor = rows.cursor.map {
            layer.convert(CGRect(x: 0, y: $0.lowerBound, width: 1, height: $0.upperBound - $0.lowerBound), to: self.layer)
        }
        let contentBottom = rows.contentBottom.map {
            layer.convert(CGRect(x: 0, y: $0 - 1, width: 1, height: 1), to: self.layer)
        }
        guard let lowest = [cursor, contentBottom].compactMap({ $0?.maxY }).max() else { return inputs }
        // The grid's padding below its last row, under a row: a grid shorter than the canvas by more, as while a
        // resize waits for the server, leaves empty canvas below it that isn't kept in view.
        let belowGrid = max(canvasHeight - layout.origin.y - layout.canvasSize.height, 0)
        let bottomMargin = belowGrid < layout.cellSize.height ? belowGrid : 0
        inputs.keptLine = lowest + bottomMargin
        inputs.cursorRoom = cursor.map { max($0.minY - layout.origin.y, 0) }
        return inputs
    }

    private func retire(container: GhosttyPaneScrollContainerView) {
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    /// The backend's popup covers the panes and takes every touch on the terminal area, as Herdr's client
    /// gives a popup every click. Its terminal is a surface as a pane's is, so a touch and a selection on it
    /// work as on a pane.
    private func syncPopup() {
        guard let popup = projection.popup else {
            retirePopup()
            return
        }
        popupView.show(
            popup,
            surface: surfaceLookup.managedSurface(for: popup.id),
            displayScale: paneDisplayScale,
            submitScroll: submitMouseScroll,
            submitPointer: submitMousePosition
        )
        if popupView.superview !== self { addSubview(popupView) }
        bringSubviewToFront(popupView)
    }

    private func retirePopup() {
        guard popupView.superview != nil else { return }
        popupView.dismantle()
        popupView.removeFromSuperview()
    }

    private func layoutVisibleSurfaces() {
        let startedAt = GhosttyRuntimeTrace.perfEnabled
            ? GhosttyRuntimeTrace.nowNanos()
            : nil
        let inks = GhosttyPaneLinesUIView.Inks(separator: separatorColor, focus: RemuxAccent.uiFill)
        guard let grid = projection.windowGrid,
              let cell = projection.cellMetrics,
              let layout = GhosttyCompositeViewportLayout(
                  bounds: bounds,
                  grid: grid,
                  cellMetrics: cell
              )
        else {
            linesView.update(lines: [], layout: nil, inks: inks)
            UIView.performWithoutAnimation { placePopup() }
            return
        }
        var changed = false
        // Pane frames are exact cell geometry. A layout pass can run inside another animation,
        // such as the system keyboard's; animating a pane there leaves a position animation
        // running that adds its offset to the next authoritative layout. Each moved pane also
        // lays itself out here, so its own frames stay out of that animation too.
        UIView.performWithoutAnimation {
            // Behind the panes, their lines take the grid's canvas the same way (`GhosttyPaneLinesUIView`).
            linesView.frame = CGRect(origin: layout.origin, size: layout.canvasSize)
            linesView.update(lines: projection.paneLines, layout: layout, inks: inks)
            for pane in projection.panes {
                guard let visibleFrame = pane.visibleFrame,
                      let container = containersBySurfaceID[pane.id]
                else { continue }
                let targetFrame = layout.frame(for: visibleFrame)
                guard container.frame != targetFrame else { continue }
                container.frame = targetFrame
                container.layoutIfNeeded()
                changed = true
            }
            placePopup()
        }
        if let startedAt {
            GhosttyRuntimeTrace.perf(
                "viewport.layout bounds=\(ghosttyDiagnosticRect(bounds)) panes=\(containersBySurfaceID.count) changed=\(changed) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
            )
        }
    }

    private func placePopup() {
        guard popupView.superview === self else { return }
        popupView.frame = bounds
        // A popup's frame draws the focus ink as the separator.
        popupView.place(
            cellMetrics: projection.cellMetrics,
            inks: GhosttyPaneLinesUIView.Inks(separator: separatorColor, focus: separatorColor),
            background: backgroundColor ?? .clear
        )
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
            cancelArrowGesture()
            reconcileLocalSelectionAfterLongPress()
        case .possible:
            break
        @unknown default:
            cancelArrowGesture()
            cancelLocalSelectionInteraction()
        }
    }

    private func beginTerminalLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let driver = trackpadDriver,
              let (surfaceID, surface, _) = visibleSurface(
                  at: recognizer.location(in: self)
              )
        else { return }
        // A hold makes its pane the one in use, as a tap does, so the arrows a drag sends and the typing after
        // it go to the pane under the thumb. A popup takes input already.
        if surfaceID != projection.focusedSurfaceID, surfaceID != projection.popup?.id {
            onSurfaceTap?(surfaceID, false)
        }

        cancelLocalSelectionInteraction()
        localSelectionSurface = surface
        localSelectionControlSurface = surface.controlSurface
        longPressOriginalPoint = recognizer.location(in: surface.view)
        surface.onLocalSelectionGeometryChange = { [weak self] in
            self?.refreshLocalSelectionGeometry()
        }
        arrowSurface = surface
        driver.begin(
            owner: self,
            at: recognizer.location(in: nil),
            edges: window.map(GhosttyKeyboardCursorTrackpadDriver.edges(of:)),
            source: .terminal,
            sendKeyEvent: { [weak self, weak surface] event in
                guard let self, let surface, self.isShown(surface) else { return false }
                return self.sendKeyEventToSurface?(event, surface.id) == true
            }
        )
    }

    private func updateTerminalLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let driver = trackpadDriver, exactLocalSelectionSurface() != nil else {
            cancelArrowGesture()
            cancelLocalSelectionInteraction()
            return
        }
        driver.update(owner: self, at: recognizer.location(in: nil))
    }

    private func endTerminalLongPress() {
        guard let driver = trackpadDriver else {
            cancelLocalSelectionInteraction()
            return
        }
        guard driver.end(owner: self) != .steered else {
            reconcileLocalSelectionAfterLongPress()
            return
        }

        guard let point = longPressOriginalPoint,
              let (surface, control) = exactLocalSelectionSurface()
        else {
            cancelLocalSelectionInteraction()
            return
        }

        switch surface.selectLink(at: point) {
        case .match(let snapshot, let explicitTarget):
            longPressOriginalPoint = nil
            previewSelectionContext.setAutomaticSelection(
                visibleText: control.readSelection(),
                explicitTarget: explicitTarget
            )
            applySelectionOutcome(.snapshot(snapshot), presentMenu: false)
            presentSelectionCopyMenu(completing: (point, explicitTarget == nil ? .link : .explicitLink))
        case .noMatch:
            longPressOriginalPoint = nil
            previewSelectionContext.selectionDidChange()
            applySelectionOutcome(surface.selectWord(at: point), presentMenu: false)
            presentSelectionCopyMenu(completing: (point, .word))
        case .unavailable:
            reconcileLocalSelectionAfterLongPress()
        }
    }

    private func invalidateSelectionMenu() {
        selectionMenuPreparation?.cancel()
        selectionMenuPreparation = nil
        preparedSelection = nil
        selectionGeneration &+= 1
    }

    private func selectionMenuContext() -> SelectionMenuContext? {
        guard selectionSnapshot.isActive, let (surface, control) = exactLocalSelectionSurface(),
              let text = control.readSelection(), !text.isEmpty
        else { return nil }
        return SelectionMenuContext(
            generation: selectionGeneration, surface: surface, control: control,
            history: surface.historySelection, visibleText: text, preview: previewSelectionContext
        )
    }

    private func isCurrent(_ context: SelectionMenuContext) -> Bool {
        guard context.generation == selectionGeneration, selectionSnapshot.isActive,
              let (surface, control) = exactLocalSelectionSurface()
        else { return false }
        return surface === context.surface && control === context.control
            && surface.historySelection == context.history
            && control.readSelection() == context.visibleText
            && previewSelectionContext == context.preview
    }

    private func menuSelectionText(for context: SelectionMenuContext) async -> String? {
        guard !Task.isCancelled, isCurrent(context) else { return nil }
        guard let source = selectionSource,
              let text = await source.readText(context.surface.id, false), !text.isEmpty,
              !Task.isCancelled, isCurrent(context)
        else { return nil }
        return text
    }

    /// Embedded destinations need no backend inspection. Plain-text targets use completed backend
    /// text and refresh the existing menu once; dismissed or obsolete selections stay dismissed.
    private func prepareSelectionMenu(completing link: (CGPoint, GhosttyLongPressSelection)?) {
        invalidateSelectionMenu()
        if selectionMenuContext()?.explicitTarget != nil { return }
        guard let (surface, control) = exactLocalSelectionSurface(), let source = selectionSource else { return }
        let generation = selectionGeneration
        selectionMenuPreparation = Task { @MainActor [weak self] in
            defer {
                if let self, self.selectionGeneration == generation { self.selectionMenuPreparation = nil }
            }
            let isComplete: Bool
            if let link, !Task.isCancelled {
                isComplete = await source.completeLink(surface.id, link.0, link.1)
            } else {
                isComplete = true
            }
            guard !Task.isCancelled, let self, self.selectionGeneration == generation,
                  let (currentSurface, currentControl) = self.exactLocalSelectionSurface(),
                  currentSurface === surface, currentControl === control
            else { return }
            self.applySelectionOutcome(surface.selectionSnapshot(), presentMenu: false)
            self.selectionEditMenuInteraction.updateVisibleMenuPosition(animated: true)
            guard isComplete else { return }
            guard let context = self.selectionMenuContext() else { return }
            guard let text = await self.menuSelectionText(for: context),
                  !Task.isCancelled, self.isCurrent(context)
            else { return }
            self.preparedSelection = (context, text)
            self.selectionEditMenuInteraction.reloadVisibleMenu()
            self.selectionEditMenuInteraction.updateVisibleMenuPosition(animated: true)
        }
    }

    private func presentSelectionCopyMenu(completing link: (CGPoint, GhosttyLongPressSelection)? = nil) {
        guard selectionSnapshot.isActive,
              exactLocalSelectionSurface() != nil,
              let anchor = selectionMenuAnchorHandle
        else { return }
        prepareSelectionMenu(completing: link)
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
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        guard let (surfaceID, surface, container) = visibleSurface(at: point) else {
            // The popup takes the input from a tap on its cells before its terminal draws there.
            if let popup = projection.popup, popupView.terminalContains(convert(point, to: popupView)) {
                onSurfaceTap?(popup.id, true)
            }
            return
        }

        if selectionSnapshot.isActive,
           let (selectionSurface, _) = exactLocalSelectionSurface() {
            _ = selectionSurface.clearSelection()
            cancelLocalSelectionInteraction()
            return
        }

        let visiblePaneCount = projection.panes.lazy.filter {
            $0.visibleFrame != nil
        }.count
        let shouldShowKeyboard = surfaceID == projection.popup?.id
            || visiblePaneCount == 1
            || projection.focusedSurfaceID == surfaceID
        let mouseCaptured = isMouseCaptured(surfaceID)
        if shouldShowKeyboard, container.consumeMomentumCatchTap() == true {
            return
        }
        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: recognizer.location(in: surface.view),
            mouseCaptured: mouseCaptured,
            showsKeyboard: shouldShowKeyboard
        ) {
            switch action {
            case .activateInput:
                onSurfaceTap?(surfaceID, true)
            case .focusPane:
                onSurfaceTap?(surfaceID, false)
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
        guard let recordedSurface = localSelectionSurface, isShown(recordedSurface) else { return nil }
        return recordedSurface
    }

    /// The surface is still the one this viewport shows for its pane.
    private func isShown(_ surface: GhosttyManagedSurface) -> Bool {
        shownContainer(for: surface.id) != nil
            && surfaceLookup.managedSurface(for: surface.id) === surface
            && surface.view.isDescendant(of: self)
    }

    private func cancelArrowGesture() {
        _ = trackpadDriver?.cancel(owner: self)
        arrowSurface = nil
    }

    @objc
    private func handleArrowRegrip(_ recognizer: UILongPressGestureRecognizer) {
        guard let driver = trackpadDriver else { return }
        let point = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            driver.regrip(owner: self, at: point)
        case .changed:
            driver.update(owner: self, at: point)
        case .ended:
            driver.end(owner: self)
        case .cancelled, .failed:
            cancelArrowGesture()
        case .possible:
            break
        @unknown default:
            cancelArrowGesture()
        }
    }

    private func refreshLocalSelectionGeometry() {
        guard let surface = projectedLocalSelectionSurface() else {
            cancelLocalSelectionInteraction()
            return
        }
        localSelectionControlSurface = surface.controlSurface
        // Output during neutral/steering must not resurrect an older selection.
        guard longPressOriginalPoint == nil, selectionSnapshot.isActive else { return }
        applySelectionOutcome(surface.selectionSnapshot(), presentMenu: false)
    }

    private func reconcileLocalSelectionAfterLongPress() {
        longPressOriginalPoint = nil
        guard let surface = projectedLocalSelectionSurface() else {
            cancelLocalSelectionInteraction()
            return
        }
        localSelectionControlSurface = surface.controlSurface
        applySelectionOutcome(
            surface.selectionSnapshot(),
            presentMenu: false
        )
    }

    private func restoreLocalSelectionIfPresent() {
        guard localSelectionSurface == nil,
              let surfaceID = projection.popup?.id ?? projection.focusedSurfaceID,
              shownContainer(for: surfaceID) != nil,
              let surface = surfaceLookup.managedSurface(for: surfaceID),
              surface.view.isDescendant(of: self),
              case .snapshot(let snapshot) = surface.selectionSnapshot(),
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
        invalidateSelectionMenu()
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
              let (surface, _) = exactLocalSelectionSurface()
        else {
            cancelLocalSelectionInteraction()
            return
        }
        if recognizer.state == .began {
            invalidateSelectionMenu()
            previewSelectionContext.selectionDidChange()
            selectionEditMenuInteraction.dismissMenu()
        }
        if recognizer.state == .changed {
            applySelectionOutcome(
                surface.setSelectionEndpoint(
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
        // Handles sit on the pane's cells, so they move with the pane, never animated.
        UIView.performWithoutAnimation {
            position(startSelectionHandle, surface: surface)
            position(endSelectionHandle, surface: surface)
        }
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
        if gestureRecognizer === arrowRegripRecognizer {
            return trackpadDriver?.canRegrip(owner: self) == true
        }
        guard gestureRecognizer === panRecognizer else { return true }
        return projection.canNavigateWindows && GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
            topLevelCount: projection.windowCount,
            velocity: panRecognizer.velocity(in: self)
        )
    }

    /// The container showing `surfaceID`'s terminal: while the backend shows a popup, only the popup's, which
    /// covers the panes.
    private func shownContainer(for surfaceID: UUID) -> GhosttyPaneScrollContainerView? {
        if let popup = projection.popup {
            guard popup.id == surfaceID, popupView.surface?.id == surfaceID else { return nil }
            return popupView.terminal
        }
        guard projection.panes.contains(where: { $0.id == surfaceID && $0.visibleFrame != nil }) else { return nil }
        return containersBySurfaceID[surfaceID]
    }

    /// The surface a touch at `point` reaches: while the backend shows a popup, only the popup's, on its cells.
    private func visibleSurface(
        at point: CGPoint
    ) -> (UUID, GhosttyManagedSurface, GhosttyPaneScrollContainerView)? {
        if let popup = projection.popup {
            guard popupView.terminalContains(convert(point, to: popupView)),
                  let container = shownContainer(for: popup.id),
                  let surface = surfaceLookup.managedSurface(for: popup.id),
                  surface.rendererIsAvailable
            else { return nil }
            return (popup.id, surface, container)
        }
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

        // Link and Preview actions use a known embedded destination immediately. Plain-text targets
        // require completed backend text; ordinary Copy always keeps the backend's selected-text semantics.
        let linkSelection = preparedSelection.flatMap { isCurrent($0.context) ? $0 : nil }
            ?? selectionMenuContext().flatMap { context -> (context: SelectionMenuContext, text: String)? in
                guard context.explicitTarget != nil else { return nil }
                return (context, context.visibleText)
            }
        var actions: [UIMenuElement] = []
        if onPreviewSelection != nil, let prepared = linkSelection,
           let candidate = prepared.context.preview.candidate(for: prepared.text) {
            let context = prepared.context
            // Preview what this action names: the selection must still read the same when tapped.
            actions.append(UIAction(title: "Preview", image: UIImage(systemName: "eye")) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(context) else { return }
                    let currentText = context.explicitTarget != nil
                        ? context.visibleText : await self.menuSelectionText(for: context)
                    guard let text = currentText, self.isCurrent(context),
                          context.preview.candidate(for: text) == candidate
                    else { return }
                    self.onPreviewSelection?(context.surface.id, candidate)
                }
            })
        } else if let prepared = linkSelection,
                  let url = TerminalExternalLink.url(selection: prepared.text, explicitTarget: prepared.context.explicitTarget) {
            let context = prepared.context
            // Keep the destination advertised by this action, including its path, query and fragment.
            actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(context) else { return }
                    let currentText = context.explicitTarget != nil
                        ? context.visibleText : await self.menuSelectionText(for: context)
                    guard let text = currentText, self.isCurrent(context),
                          TerminalExternalLink.url(selection: text, explicitTarget: context.explicitTarget) == url
                    else { return }
                    _ = await UIApplication.shared.open(url)
                }
            })
        }
        if let prepared = linkSelection, let target = prepared.context.explicitTarget {
            let context = prepared.context
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in
                guard let self, self.isCurrent(context) else { return }
                UIPasteboard.general.string = target
            })
        }
        actions.append(
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let (surface, _) = self?.exactLocalSelectionSurface(),
                      let source = self?.selectionSource
                else { return }
                // The backend reads the text where it keeps the pane's history, which can take a reply
                // from its server.
                Task { @MainActor in
                    guard let text = await source.readText(surface.id, true), !text.isEmpty else { return }
                    UIPasteboard.general.string = text
                }
            }
        )
        return UIMenu(children: actions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        // Menu dismissal must not cancel the separate validation of an Open tap.
        selectionMenuPreparation?.cancel()
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
        backgroundColor = RemuxAccent.uiFill
        layer.borderColor = RemuxAccent.uiOnFill.cgColor
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

/// Lines on a grid's canvas (`GhosttyPaneLine.draw`), in a view of their own that its host places at the canvas
/// of `GhosttyCompositeViewportLayout`, which the grid alone sizes. The terminal area's size animates as the
/// keyboard comes up or goes down, and Core Animation scales a layer's drawing to its bounds through such an
/// animation, so lines drawn into the area's own layer would stretch over the panes, which are laid out without
/// animation. The canvas keeps its place through the animation, and this view's geometry never animates.
final class GhosttyPaneLinesUIView: UIView {
    /// The colours of the inks the backend leaves to the app: the theme's separator and the app's accent.
    struct Inks: Equatable {
        var separator: UIColor
        var focus: UIColor

        func color(of ink: GhosttyPaneLine.Ink) -> UIColor {
            switch ink {
            case .separator:
                separator
            case .focus:
                focus
            case .color(let red, let green, let blue):
                UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            }
        }
    }

    private var lines: [GhosttyPaneLine] = []
    private var layout: GhosttyCompositeViewportLayout?
    private var inks = Inks(separator: .clear, focus: .clear)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(lines: [GhosttyPaneLine], layout: GhosttyCompositeViewportLayout?, inks: Inks) {
        guard lines != self.lines || layout != self.layout || inks != self.inks else { return }
        self.lines = lines
        self.layout = layout
        self.inks = inks
        setNeedsDisplay()
    }

    override func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        switch event {
        case "bounds", "position":
            NSNull()
        default:
            super.action(for: layer, forKey: event)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        // The lines are laid out from the area's origin; the view sits at the canvas's.
        context.translateBy(x: -layout.origin.x, y: -layout.origin.y)
        GhosttyPaneLine.draw(lines, in: context, layout: layout, scale: paneDisplayScale) { ink in
            inks.color(of: ink).cgColor
        }
    }
}

private extension UIView {
    /// The scale the panes' cells and lines are laid out on, so the two meet on the same pixels: the window's
    /// screen's, or the main screen's before the view is in a window.
    var paneDisplayScale: CGFloat {
        max(window?.screen.scale ?? UIScreen.main.scale, 1)
    }
}

extension GhosttyPaneLine {
    /// Draws `lines` on `layout`'s grid, inside its canvas, each on whole pixels of `scale` and at least one
    /// pixel wide, so lines of one width are all equally crisp: in order, so a later line draws over an
    /// earlier one, and a run of lines in one ink as one fill.
    static func draw(
        _ lines: [GhosttyPaneLine],
        in context: CGContext,
        layout: GhosttyCompositeViewportLayout,
        scale: CGFloat,
        color: (Ink) -> CGColor
    ) {
        let canvas = CGRect(origin: layout.origin, size: layout.canvasSize)
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        var start = lines.startIndex
        while start < lines.endIndex {
            let ink = lines[start].ink
            let end = lines[start...].firstIndex { $0.ink != ink } ?? lines.endIndex
            let path = CGMutablePath()
            for line in lines[start..<end] {
                if let frame = line.pixelFrame(origin: layout.origin, cellSize: layout.cellSize, canvas: canvas, scale: scale) {
                    path.addRect(frame)
                }
            }
            context.setFillColor(color(ink))
            context.addPath(path)
            context.fillPath()
            start = end
        }
    }

    /// The line's frame on whole pixels, inside `canvas`, or nil when none of it is.
    func pixelFrame(origin: CGPoint, cellSize: CGSize, canvas: CGRect, scale: CGFloat) -> CGRect? {
        let clipped = frame(origin: origin, cellSize: cellSize).intersection(canvas)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let pixelAligned = CGRect(
            x: (clipped.minX * scale).rounded() / scale,
            y: (clipped.minY * scale).rounded() / scale,
            width: max((clipped.width * scale).rounded() / scale, 1 / scale),
            height: max((clipped.height * scale).rounded() / scale, 1 / scale)
        ).intersection(canvas)
        guard !pixelAligned.isNull, !pixelAligned.isEmpty else { return nil }
        return pixelAligned
    }
}
