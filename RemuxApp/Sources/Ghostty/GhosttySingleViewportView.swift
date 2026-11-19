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
    /// The terminal's size when it is taller than the area shown, as while the keyboard covers its bottom
    /// with the keyboard pan; nil when the terminal fills the area.
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

/// Shows the composite viewport in the terminal area, which clips it. Without a canvas size the viewport fills
/// the area. With one taller than the area, as while the keyboard covers the bottom of the terminal under the
/// keyboard pan, the viewport keeps the canvas size and moves up just far enough that the focused pane's cursor
/// row and anything drawn below it, such as an agent's footer, stay above the area's bottom edge, together with
/// the margin below the grid when the last row is in use; but never so far that the cursor's row leaves the top.
/// While the pane shows scrollback above its cursor, the bottom of the canvas stays in view.
///
/// The move is set in this view's layout, run as soon as the area's size is set, so inside the keyboard's
/// animation that sets it: the viewport moves with the keyboard and the toolbar on it. A move for output alone,
/// as it arrives, is immediate, as a terminal scrolls.
private final class GhosttyCompositeViewportHostView: UIView {
    let viewport = GhosttyCompositeViewportContainerView()
    /// Set before the viewport's update, which then starts or stops following the cursor's frames.
    var canvasSize: CGSize? {
        didSet {
            guard canvasSize != oldValue else { return }
            if (canvasSize == nil) != (oldValue == nil) {
                viewport.onFocusedFramePublished = canvasSize == nil ? nil : { [weak self] in
                    self?.frameRecord?.notePublishedFrame()
                    self?.followContent()
                }
                frameRecord = canvasSize != nil && GhosttyRuntimeTrace.tmuxViewportEnabled
                    ? GhosttyKeyboardPanFrameRecord(host: self)
                    : nil
            }
            setNeedsLayout()
        }
    }
    private var frameRecord: GhosttyKeyboardPanFrameRecord?
    private var lastLaidOutHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(viewport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The area's size is set inside the keyboard's animation, but on a phone the layout pass it asks for runs
    // later, outside it, where the canvas's move would be a jump. So the canvas is laid out at once, inside the
    // animation the size change runs in, as UIKit resizes autoresizing subviews.
    override var frame: CGRect {
        didSet { layOutForSizeChange(from: oldValue.size, to: frame.size) }
    }

    override var bounds: CGRect {
        didSet { layOutForSizeChange(from: oldValue.size, to: bounds.size) }
    }

    private func layOutForSizeChange(from oldSize: CGSize, to newSize: CGSize) {
        guard canvasSize != nil, oldSize != newSize else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = canvasSize.map {
            CGSize(width: $0.width, height: max($0.height, bounds.height))
        } ?? bounds.size
        // Set inside an animation the size change runs in, the keyboard's, and so moves with it.
        let pan = pan(canvasHeight: size.height)
        tracePan("layout", pan: pan, canvasHeight: size.height)
        viewport.frame = CGRect(origin: CGPoint(x: 0, y: -pan), size: size)
        if lastLaidOutHeight != bounds.height {
            lastLaidOutHeight = bounds.height
            frameRecord?.record()
        }
    }

    /// The line the pan keeps in view (`GhosttyCompositeViewportContainerView.keyboardPanLines`) in the canvas,
    /// for the frame record.
    var panLine: CGFloat? {
        viewport.keyboardPanLines(canvasHeight: viewport.bounds.height)?.line
    }

    private func followContent() {
        let pan = pan(canvasHeight: viewport.bounds.height)
        guard viewport.frame.minY != -pan else { return }
        tracePan("content", pan: pan, canvasHeight: viewport.bounds.height)
        UIView.performWithoutAnimation {
            viewport.frame.origin.y = -pan
        }
    }

    private func tracePan(_ reason: String, pan: CGFloat, canvasHeight: CGFloat) {
        guard GhosttyRuntimeTrace.tmuxViewportEnabled, canvasSize != nil else { return }
        GhosttyRuntimeTrace.tmuxViewport(
            "viewport.pan reason=\(reason) ca=\(String(format: "%.4f", CACurrentMediaTime())) area=\(bounds.height) canvas=\(canvasHeight) pan=\(pan) previous=\(-viewport.frame.minY) animation=\(UIView.inheritedAnimationDuration)"
        )
    }

    /// How far the canvas moves up: none while the area shows all of it; otherwise just enough that the
    /// focused pane's cursor and what is drawn below it (`GhosttyCompositeViewportContainerView.keyboardPanLines`)
    /// are above the area's bottom edge, but never so far that the cursor's row leaves the top, and at most the
    /// height covered; all of it when the pane shows nothing. On whole pixels, so the picture is not resampled.
    private func pan(canvasHeight: CGFloat) -> CGFloat {
        let covered = canvasHeight - bounds.height
        guard covered > 0 else { return 0 }
        let lines = viewport.keyboardPanLines(canvasHeight: canvasHeight)
        let line = lines?.line ?? canvasHeight
        let limit = min(covered, lines?.cursorRoom ?? covered)
        let pan = min(max(line - bounds.height, 0), limit)
        let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
        return (pan * scale).rounded() / scale
    }
}

/// The keyboard pan experiment's frame record, with REMUX_TRACE_TMUX_VIEWPORT. From each keyboard notification or
/// change of the area's height until a second after it, it traces every display frame's on-screen positions as Core
/// Animation shows them: the area's top and bottom, the canvas's top, the line the pan keeps in view, and the keyboard's top. It
/// also traces each keyboard notification and each frame the focused pane publishes, so a run on a phone, which
/// can't record its screen, can still be read frame by frame.
@MainActor
private final class GhosttyKeyboardPanFrameRecord: NSObject {
    private weak var host: GhosttyCompositeViewportHostView?
    private var displayLink: CADisplayLink?
    private var recordsUntil: CFTimeInterval = 0
    private weak var keyboardView: UIView?
    private var publishedFrames = 0

    init(host: GhosttyCompositeViewportHostView) {
        self.host = host
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    func record() {
        recordsUntil = CACurrentMediaTime() + 1.0
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func notePublishedFrame() {
        guard displayLink != nil else { return }
        publishedFrames += 1
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let begin = (info[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue ?? .null
        let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .null
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? -1
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? -1
        GhosttyRuntimeTrace.tmuxViewport(
            "viewport.kbd ca=\(Self.format(CACurrentMediaTime())) begin=\(Self.format(begin.minY)) end=\(Self.format(end.minY)) height=\(Self.format(end.height)) duration=\(duration) curve=\(curve) inherited=\(UIView.inheritedAnimationDuration)"
        )
        record()
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        guard let host, let window = host.window, link.timestamp < recordsUntil else {
            link.invalidate()
            displayLink = nil
            return
        }
        let windowLayer = window.layer.presentation() ?? window.layer
        let area = Self.shownFrame(of: host.layer, in: windowLayer)
        let canvas = Self.shownFrame(of: host.viewport.layer, in: windowLayer)
        let line = host.panLine.map { canvas.minY + $0 }
        let keyboard = keyboardTop(in: window.windowScene)
        GhosttyRuntimeTrace.tmuxViewport(
            "viewport.frame ca=\(Self.format(CACurrentMediaTime())) t=\(Self.format(link.timestamp)) target=\(Self.format(link.targetTimestamp)) areaTop=\(Self.format(area.minY)) areaBottom=\(Self.format(area.maxY)) canvasTop=\(Self.format(canvas.minY)) line=\(line.map { Self.format($0) } ?? "-") keyboardTop=\(keyboard.map { Self.format($0) } ?? "-") modelArea=\(Self.format(host.bounds.height)) modelPan=\(Self.format(-host.viewport.frame.minY)) published=\(publishedFrames)"
        )
    }

    /// A layer's frame on screen as Core Animation shows it this frame, mid-animation included.
    private static func shownFrame(of layer: CALayer, in windowLayer: CALayer) -> CGRect {
        let shown = layer.presentation() ?? layer
        return shown.convert(shown.bounds, to: windowLayer)
    }

    /// The top of the keyboard's host view, as shown this frame, in its window, which covers the screen.
    private func keyboardTop(in scene: UIWindowScene?) -> CGFloat? {
        if keyboardView?.window == nil {
            keyboardView = scene?.windows.lazy.compactMap { Self.view(named: "UIInputSetHostView", in: $0) }.first
        }
        guard let keyboardView, let window = keyboardView.window else { return nil }
        let windowLayer = window.layer.presentation() ?? window.layer
        let frame = Self.shownFrame(of: keyboardView.layer, in: windowLayer)
        return frame.height > 0 ? frame.minY : nil
    }

    private static func view(named className: String, in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)) == className { return view }
        for subview in view.subviews {
            if let found = Self.view(named: className, in: subview) { return found }
        }
        return nil
    }

    private static func format(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    private static func format(_ value: Double) -> String { String(format: "%.4f", value) }
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

    /// Called on the main thread for each frame the focused pane's (or the popup's) renderer publishes.
    var onFocusedFramePublished: (() -> Void)?
    private var focusedFrameObservation: (layer: CALayer, observation: NSKeyValueObservation)?

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
        focusedFrameObservation = nil
        onFocusedFramePublished = nil
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
            let container = containersBySurfaceID[pane.id] ?? GhosttyPaneScrollContainerView()
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
        observeFocusedFramePublications()
    }

    /// The surface that takes the terminal's input and shows its cursor: the popup's while one shows,
    /// otherwise the focused pane's.
    private var inputSurface: GhosttyManagedSurface? {
        guard let id = projection.popup?.id ?? projection.focusedSurfaceID else { return nil }
        guard let surface = surfaceLookup.managedSurface(for: id), isShown(surface) else { return nil }
        return surface
    }

    private func observeFocusedFramePublications() {
        guard onFocusedFramePublished != nil,
              let layer = inputSurface.flatMap({ GhosttyIOSurfaceFrame.rendererLayer(in: $0.view.layer) })
        else {
            focusedFrameObservation = nil
            return
        }
        guard focusedFrameObservation?.layer !== layer else { return }
        let relay = FocusedFrameRelay(viewport: self, layer: layer)
        let observation = layer.observe(\.contents, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.publish() }
            }
        }
        focusedFrameObservation = (layer, observation)
    }

    /// Carries a frame publication from the renderer layer's observation to the main thread, for as long as
    /// the viewport still observes that layer.
    private final class FocusedFrameRelay: @unchecked Sendable {
        weak var viewport: GhosttyCompositeViewportContainerView?
        weak var layer: CALayer?

        init(viewport: GhosttyCompositeViewportContainerView, layer: CALayer) {
            self.viewport = viewport
            self.layer = layer
        }

        @MainActor
        func publish() {
            guard let viewport, let layer, viewport.focusedFrameObservation?.layer === layer else { return }
            viewport.onFocusedFramePublished?()
        }
    }

    /// What the keyboard pan keeps in view of the input surface, in this view's coordinates for a canvas
    /// `canvasHeight` high. `line` is the bottom of the cursor's row or of the lowest row with anything drawn on it,
    /// whichever is lower, lowered by the margin between the grid's last row and the canvas's bottom, so a last
    /// row in use keeps the whole canvas in view. `cursorRoom` is how far the cursor's row is below the grid's
    /// top, which a move up must not exceed, so the cursor's row stays in view; nil without a cursor on screen, as
    /// while the pane shows scrollback above it. Nil when the pane shows nothing.
    func keyboardPanLines(canvasHeight: CGFloat) -> (line: CGFloat, cursorRoom: CGFloat?)? {
        guard let surface = inputSurface,
              let geometry = surface.controlSurface.contentGeometry(),
              let grid = projection.windowGrid,
              let cell = projection.cellMetrics,
              let layout = GhosttyCompositeViewportLayout(
                  bounds: CGRect(x: 0, y: 0, width: bounds.width, height: canvasHeight),
                  grid: grid,
                  cellMetrics: cell
              )
        else { return nil }
        let cursor = geometry.cursor.map { surface.view.convert($0, to: self) }
        let contentBottom = geometry.contentBottom.map { surface.view.convert($0, to: self) }
        guard let lowest = [cursor, contentBottom].compactMap({ $0?.maxY }).max() else { return nil }
        let bottomMargin = max(canvasHeight - layout.origin.y - layout.canvasSize.height, 0)
        return (lowest + bottomMargin, cursor.map { max($0.minY - layout.origin.y, 0) })
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
