import Foundation
import GhosttyKit
import QuartzCore
import UIKit

/// A backend's reference to one native terminal. The pane renderer holds it
/// until its native surface over that terminal is freed.
protocol RetainedGhosttyTerminal: AnyObject {
    var handle: ghostty_terminal_t { get }
}

/// The backend's native lifetime fence for a pane renderer. Registration
/// admits the renderer to the backend's terminal-change notifications. The
/// unregistration completion is the happens-before fence: every earlier
/// notification has returned and no later one can dereference the renderer.
@MainActor
protocol TerminalPaneRendererFence: AnyObject {
    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    )
    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    )
}

/// MainActor owner of the renderer for one retained pane terminal. Normal pane
/// switches retain this object unchanged; only renderer failure replaces the
/// native renderer over the same terminal and UIView. Settings update the live
/// renderer in place. The backend supplies the terminal, its lifetime fence
/// and, when the native surface encodes input for it, the input writer.
@MainActor
final class TerminalPaneRenderer {
    /// Receives the bytes the native surface encodes from local input
    /// (`write_cb`).
    typealias InputWriter = @MainActor (Data) -> Bool

    let view: GhosttyKitSurfaceView

    private let app: ghostty_app_t
    private let terminal: any RetainedGhosttyTerminal
    private let fence: any TerminalPaneRendererFence
    private let writeInput: InputWriter?
    private let diagnosticName: String
    private let onRendererFailure: @MainActor () -> Void

    private struct NativeRenderer {
        let handle: ghostty_terminal_surface_t
        let control: GhosttyKitControlSurface
        let callbackBox: CallbackBox
    }

    private enum Lifecycle {
        case active
        case replacing
        case closing
        case closed
    }

    private var renderer: NativeRenderer?
    private(set) var managedSurface: GhosttyManagedSurface?
    private var presented = false
    private var focused = false
    private var sceneActive = true
    private var lifecycle = Lifecycle.active
    private var rendererFailureReported = false
    #if DEBUG
    var suppressFirstPublicationForTesting = false
    var suppressReplacementPublicationForTesting = false
    #endif
    private var rendererIsAvailable = true
    private var hasPublishedFrame = false
    /// The pane draws its first picture off screen (`prepare()`), until it is presented in a window.
    private var isPreparing = false
    private var presentationFailure: TerminalDisconnectReason?
    private var firstFrameObservation: NSKeyValueObservation?
    private var firstFrameDeadline: Task<Void, Never>?
    var onPresentationChange: (() -> Void)?

    /// Ready once a frame at the pane's size is in its view: in a window, or drawn off screen for the view to
    /// show the moment it is attached (`prepare()`).
    var presentation: TerminalPanePresentation {
        if let presentationFailure { return .failed(presentationFailure) }
        guard !isClosing, rendererIsAvailable, renderer != nil,
              view.window != nil || isPreparing else { return .pending }
        return hasPublishedFrame ? .ready : .awaitingFrame
    }

    private var acceptsInput: Bool {
        lifecycle == .active && rendererIsAvailable && hasPublishedFrame && presentationFailure == nil
    }

    var inputControlSurface: GhosttyKitControlSurface? {
        acceptsInput ? renderer?.control : nil
    }

    private func observeFirstFrame() {
        firstFrameObservation = nil
        hasPublishedFrame = false
        guard let layer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer) else {
            failPresentation(message: "Terminal renderer has no presentation layer. Reconnect to try again.")
            return
        }
        let reference = LayerReference(layer)
        let relay = previewRelay
        firstFrameObservation = layer.observe(\.contents, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let renderer = relay.renderer, let layer = reference.layer,
                          GhosttyIOSurfaceFrame.rendererLayer(in: renderer.view.layer) === layer
                    else { return }
                    renderer.recordFirstFrameIfPublished(on: layer)
                }
            }
        }
    }

    private func recordFirstFrameIfPublished(on layer: CALayer) {
        #if DEBUG
        guard !suppressFirstPublicationForTesting,
              replacementCompletion == nil || !suppressReplacementPublicationForTesting else { return }
        #endif
        guard lifecycle == .active, rendererIsAvailable, presentationFailure == nil,
              !hasPublishedFrame, isPreparing || (presented && sceneActive && view.window != nil),
              appliedDisplayMetrics == canonicalViewportMetrics,
              let dimensions = GhosttyIOSurfaceFrame.dimensions(in: layer),
              dimensions.width == Int(canonicalViewportMetrics.pixelWidth),
              dimensions.height == Int(canonicalViewportMetrics.pixelHeight)
        else { return }
        hasPublishedFrame = true
        firstFrameObservation = nil
        managedSurface?.finishRendererReplacement(isAvailable: true)
        GhosttyRuntimeTrace.diagnostics(
            "terminalPane.firstFrame \(diagnosticName) attached=\(view.window != nil) size=\(dimensions.width)x\(dimensions.height)"
        )
        updatePresentationReadiness()
        finishReplacement(.replaced)
    }

    /// Both initial presentation and renderer recovery wait only while this pane can be shown, or draws its
    /// first picture off screen. Hidden or detached time is not a renderer failure.
    private var isAwaitingFrame: Bool {
        lifecycle == .active && rendererIsAvailable && sceneActive
            && (isPreparing || (presented && view.window != nil))
            && !hasPublishedFrame && presentationFailure == nil
    }

    private func updatePresentationReadiness() {
        if !isAwaitingFrame {
            firstFrameDeadline?.cancel()
            firstFrameDeadline = nil
        } else if firstFrameDeadline == nil {
            firstFrameDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.framePublicationTimeout)
                guard !Task.isCancelled, let self else { return }
                self.firstFrameDeadline = nil
                guard self.isAwaitingFrame else { return }
                let dimensions = GhosttyIOSurfaceFrame.rendererLayer(in: self.view.layer)
                    .flatMap { GhosttyIOSurfaceFrame.dimensions(in: $0) }
                NSLog("Remux first frame timeout: expected=%ux%u actual=%dx%d scale=%g attached=%d preparing=%d",
                      self.canonicalViewportMetrics.pixelWidth, self.canonicalViewportMetrics.pixelHeight,
                      dimensions?.width ?? 0, dimensions?.height ?? 0,
                      Double(self.view.contentScaleFactor), self.view.window != nil ? 1 : 0, self.isPreparing ? 1 : 0)
                self.failPresentation(message: "Terminal did not publish its first frame. Reconnect to try again.")
            }
        }
        onPresentationChange?()
    }

    func failPresentation(message: String) {
        guard !isClosing, presentationFailure == nil else { return }
        // This message is an app-defined rendering failure, never remote terminal content.
        NSLog("Remux renderer presentation failed: %@", message)
        presentationFailure = TerminalDisconnectReason(kind: .runtime, message: message)
        rendererIsAvailable = false
        rendererFailureReported = true
        firstFrameObservation = nil
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        cancelFramePublicationWait()
        beginRendererRecovery()
        applyPresentationActivity()
        finishReplacement(.failed)
    }

    private func finishReplacement(_ result: RendererReplacementResult) {
        let completion = replacementCompletion
        replacementCompletion = nil
        completion?(result)
    }

    private var closeCompletions: [@MainActor @Sendable () -> Void] = []
    private var framePublicationWait: FramePublicationWait?
    private var replacementCompletion: (@MainActor (RendererReplacementResult) -> Void)?
    private let previewRelay = PreviewRelay()
    private var currentTheme: TerminalTheme
    private var canonicalViewportMetrics: GhosttySurfaceDisplayMetrics
    private var appliedDisplayMetrics: GhosttySurfaceDisplayMetrics

    enum CreateError: Error {
        case surfaceCreationFailed(ghostty_terminal_surface_result_e)
        case registrationFailed(any Error)
    }

    enum RendererReplacementResult: Equatable {
        case replaced
        case busy
        case failed
    }

    private final class FailureRelay {
        weak var renderer: TerminalPaneRenderer?
    }

    private final class FramePublicationWait: @unchecked Sendable {
        let budget: GhosttyPanePreviewSession.PixelBudget
        var observation: NSKeyValueObservation?
        var continuation: CheckedContinuation<GhosttyIOSurfaceFrame?, Never>?
        var timeoutTask: Task<Void, Never>?

        init(budget: GhosttyPanePreviewSession.PixelBudget) {
            self.budget = budget
        }
    }

    private final class PreviewRelay: @unchecked Sendable {
        weak var renderer: TerminalPaneRenderer?
    }

    private static let framePublicationTimeout: Duration = .seconds(2)

    private final class LayerReference: @unchecked Sendable {
        weak var layer: CALayer?

        init(_ layer: CALayer) {
            self.layer = layer
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        let failureRelay: FailureRelay
        let writeInput: InputWriter?

        init(failureRelay: FailureRelay, writeInput: InputWriter?) {
            self.failureRelay = failureRelay
            self.writeInput = writeInput
        }

        static let writeCallback: ghostty_terminal_surface_write_cb = { userdata, pointer, count in
            // ghostty.h: write_cb fires only from terminal-surface input
            // operations on the presentation-owner thread, never from the
            // output feed.
            assert(Thread.isMainThread)
            guard let userdata else { return false }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            guard count > 0 else { return true }
            guard let pointer, let writeInput = box.writeInput else { return false }
            let bytes = Data(bytes: pointer, count: count)
            return MainActor.assumeIsolated { writeInput(bytes) }
        }

        static let healthCallback: ghostty_terminal_surface_renderer_health_cb = { userdata, health in
            guard health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY, let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { [weak relay = box.failureRelay] in
                MainActor.assumeIsolated { relay?.renderer?.rendererDidFail() }
            }
        }
    }

    static func create(
        app: ghostty_app_t,
        terminal: any RetainedGhosttyTerminal,
        fence: any TerminalPaneRendererFence,
        writeInput: InputWriter?,
        baseConfig: ghostty_terminal_surface_config_s,
        metrics: GhosttySurfaceDisplayMetrics,
        theme: TerminalTheme,
        diagnosticName: String,
        onRendererFailure: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (Result<TerminalPaneRenderer, CreateError>) -> Void
    ) {
        let relay = FailureRelay()
        let callbackBox = CallbackBox(failureRelay: relay, writeInput: writeInput)
        let view = GhosttyKitSurfaceView(frame: CGRect(
            x: 0,
            y: 0,
            width: Double(metrics.pixelWidth) / metrics.contentScale,
            height: Double(metrics.pixelHeight) / metrics.contentScale
        ))
        view.contentScaleFactor = metrics.contentScale
        view.applyTerminalTheme(theme)

        var config = configured(
            baseConfig,
            view: view,
            metrics: metrics,
            callbackBox: callbackBox,
            visible: false,
            focused: false
        )
        var nativeSurface: ghostty_terminal_surface_t?
        let result = ghostty_terminal_surface_new(
            app,
            terminal.handle,
            &config,
            &nativeSurface
        )
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK, let nativeSurface else {
            completion(.failure(.surfaceCreationFailed(result)))
            return
        }
        view.alignGhosttyRendererSublayers()

        let renderer = TerminalPaneRenderer(
            app: app,
            terminal: terminal,
            fence: fence,
            writeInput: writeInput,
            diagnosticName: diagnosticName,
            view: view,
            surface: nativeSurface,
            metrics: metrics,
            theme: theme,
            callbackBox: callbackBox,
            failureRelay: relay,
            onRendererFailure: onRendererFailure
        )
        relay.renderer = renderer
        fence.registerRenderer(nativeSurface) { result in
            switch result {
            case .success:
                completion(.success(renderer))
            case .failure(let error):
                renderer.destroyUnregisteredRenderer()
                completion(.failure(.registrationFailed(error)))
            }
        }
    }

    private init(
        app: ghostty_app_t,
        terminal: any RetainedGhosttyTerminal,
        fence: any TerminalPaneRendererFence,
        writeInput: InputWriter?,
        diagnosticName: String,
        view: GhosttyKitSurfaceView,
        surface: ghostty_terminal_surface_t,
        metrics: GhosttySurfaceDisplayMetrics,
        theme: TerminalTheme,
        callbackBox: CallbackBox,
        failureRelay: FailureRelay,
        onRendererFailure: @escaping @MainActor () -> Void
    ) {
        self.app = app
        self.terminal = terminal
        self.fence = fence
        self.writeInput = writeInput
        self.diagnosticName = diagnosticName
        self.view = view
        self.onRendererFailure = onRendererFailure
        canonicalViewportMetrics = metrics
        appliedDisplayMetrics = metrics
        currentTheme = theme
        let control = GhosttyKitControlSurface(
            surface: surface,
            scaleFactor: metrics.contentScale,
            onFailure: { [failureRelay] _ in
                failureRelay.renderer?.rendererDidFail()
            }
        )
        renderer = NativeRenderer(handle: surface, control: control, callbackBox: callbackBox)
        previewRelay.renderer = self
        view.onWindowAttachmentChange = { [weak self] in
            // didMoveToWindow can run inside a SwiftUI view update, where
            // publishing observable state is not allowed. Apply on the next
            // main-queue turn and read attachment from the view then.
            DispatchQueue.main.async { [weak self] in self?.applyPresentationActivity() }
        }
        observeFirstFrame()
    }

    var rawSurface: ghostty_terminal_surface_t? { renderer?.handle }

    /// The pane's managed surface, made once by its backend: when Herdr admits the renderer, or when
    /// tmux first shows the pane's window. An existing one is returned as it is.
    func screenSurface(id: UUID, inputSink: any TerminalPaneInputSink) -> GhosttyManagedSurface {
        if let managedSurface {
            precondition(
                managedSurface.id == id,
                "managed surface identity must remain stable for one pane"
            )
            return managedSurface
        }
        guard let renderer else {
            preconditionFailure("first screen surface requires a registered renderer")
        }

        let managed = GhosttyManagedSurface(
            id: id,
            view: view,
            controlSurface: renderer.control,
            inputSink: inputSink,
            interactionState: renderer.control.interactionState()
        )
        managedSurface = managed
        managed.finishRendererReplacement(isAvailable: rendererIsAvailable && hasPublishedFrame)
        applyPresentationActivity()
        return managed
    }

    func setPresented(_ presented: Bool) {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        guard self.presented != presented else { return }
        self.presented = presented
        applyPresentationActivity()
    }

    func setFocused(_ focused: Bool) {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        guard self.focused != focused else { return }
        self.focused = focused
        applyPresentationActivity()
    }

    func setSceneActive(_ active: Bool) {
        guard lifecycle != .closed, lifecycle != .closing else { return }
        guard active != sceneActive else { return }
        sceneActive = active
        applyPresentationActivity()
    }

    func refreshInteractionState() {
        managedSurface?.refreshInteractionState()
    }

    @discardableResult
    func updateDisplay(metrics: GhosttySurfaceDisplayMetrics) -> Bool {
        let resized = metrics != canonicalViewportMetrics
        canonicalViewportMetrics = metrics
        // The native replacement owns the old renderer until unregister is
        // acknowledged. Installation and registration apply the latest size.
        guard lifecycle != .replacing else { return true }
        let applied = applyDisplayMetrics(metrics)
        // A pane drawing off screen draws again at its new size, which its first picture must have.
        if applied, resized, isPreparing {
            observeFirstFrame()
            updatePresentationReadiness()
            renderer?.control.requestFrame()
        } else if applied, let layer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer) {
            recordFirstFrameIfPublished(on: layer)
        }
        return applied
    }

    /// Has the hidden renderer draw a frame of its terminal at the pane's size, so its view shows a complete
    /// picture the moment it is attached: `presentation` reads ready once that frame is in, before the view
    /// is in a window, as a pane of a tab coming on screen needs. Ghostty draws a hidden surface's frame on
    /// request (`ghostty_terminal_surface_request_frame`). The pane then shows as any other once presented
    /// in a window.
    func prepare() {
        guard lifecycle == .active, !presented, !isPreparing else { return }
        isPreparing = true
        guard !hasPublishedFrame else { return updatePresentationReadiness() }
        updatePresentationReadiness()
        renderer?.control.requestFrame()
    }

    @discardableResult
    func applyTerminalConfiguration(theme: TerminalTheme) -> Bool {
        currentTheme = theme
        guard lifecycle != .replacing else { return true }
        guard lifecycle == .active, presentationFailure == nil, let renderer else { return false }
        let result = ghostty_terminal_surface_update_config(renderer.handle)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            NSLog(
                "terminalPane.configUpdate failed \(diagnosticName) result=\(String(describing: result))"
            )
            return false
        }
        view.applyTerminalTheme(theme)
        managedSurface?.notifyLocalSelectionGeometryChanged()
        return true
    }

    func replaceRenderer(
        baseConfig: ghostty_terminal_surface_config_s,
        metrics: GhosttySurfaceDisplayMetrics,
        theme: TerminalTheme,
        completion: @escaping @MainActor (RendererReplacementResult) -> Void
    ) {
        guard lifecycle == .active, replacementCompletion == nil, presentationFailure == nil else {
            completion(lifecycle == .replacing || replacementCompletion != nil ? .busy : .failed)
            return
        }
        lifecycle = .replacing
        currentTheme = theme
        replacementCompletion = completion
        canonicalViewportMetrics = metrics
        rendererIsAvailable = false
        hasPublishedFrame = false
        firstFrameObservation = nil
        rendererFailureReported = true
        renderer?.callbackBox.failureRelay.renderer = nil
        cancelFramePublicationWait()
        beginRendererRecovery()
        updatePresentationReadiness()

        let installReplacement = { [self] in
            guard lifecycle == .replacing else {
                finishCloseIfRendererless()
                finishReplacement(.failed)
                return
            }
            let metrics = canonicalViewportMetrics
            let relay = FailureRelay()
            let callbackBox = CallbackBox(failureRelay: relay, writeInput: writeInput)
            view.applyTerminalTheme(currentTheme)
            view.frame.size = CGSize(
                width: Double(metrics.pixelWidth) / metrics.contentScale,
                height: Double(metrics.pixelHeight) / metrics.contentScale
            )
            view.contentScaleFactor = metrics.contentScale
            appliedDisplayMetrics = metrics
            var config = Self.configured(
                baseConfig, view: view, metrics: metrics, callbackBox: callbackBox,
                visible: false, focused: false
            )
            var replacement: ghostty_terminal_surface_t?
            let result = ghostty_terminal_surface_new(app, terminal.handle, &config, &replacement)
            guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK, let replacement else {
                lifecycle = .active
                failPresentation(message: "Terminal renderer could not recover. Reconnect to try again.")
                return
            }
            view.alignGhosttyRendererSublayers()
            let wrapper = GhosttyKitControlSurface(
                surface: replacement, scaleFactor: metrics.contentScale,
                onFailure: { [relay] _ in relay.renderer?.rendererDidFail() }
            )
            renderer = NativeRenderer(handle: replacement, control: wrapper, callbackBox: callbackBox)
            relay.renderer = self
            rendererFailureReported = false
            fence.registerRenderer(replacement) { [self] result in
                guard case .success = result else {
                    relay.renderer = nil
                    wrapper.invalidate()
                    ghostty_terminal_surface_free(replacement)
                    renderer = nil
                    if lifecycle == .closing {
                        finishCloseIfRendererless()
                    } else {
                        lifecycle = .active
                        failPresentation(message: "Terminal renderer could not recover. Reconnect to try again.")
                    }
                    return
                }
                guard lifecycle != .closing else {
                    fence.unregisterRenderer(replacement) { [self] in
                        relay.renderer = nil
                        wrapper.invalidate()
                        ghostty_terminal_surface_free(replacement)
                        renderer = nil
                        finishCloseIfRendererless()
                    }
                    return
                }
                lifecycle = .active
                managedSurface?.replaceControlSurface(wrapper)
                guard presentationFailure == nil else { return }
                rendererIsAvailable = true
                guard applyTerminalConfiguration(theme: currentTheme) else {
                    failPresentation(message: "Terminal renderer could not apply its configuration. Reconnect to try again.")
                    return
                }
                guard applyDisplayMetrics(canonicalViewportMetrics) else {
                    failPresentation(message: "Terminal renderer could not apply its viewport. Reconnect to try again.")
                    return
                }
                observeFirstFrame()
                applyPresentationActivity()
            }
        }

        guard let oldRenderer = renderer else {
            installReplacement()
            return
        }
        fence.unregisterRenderer(oldRenderer.handle) { [self] in
            oldRenderer.control.invalidate()
            ghostty_terminal_surface_free(oldRenderer.handle)
            if renderer?.handle == oldRenderer.handle { renderer = nil }
            guard lifecycle != .closing else {
                finishCloseIfRendererless()
                return
            }
            installReplacement()
        }
    }

    var isClosing: Bool { lifecycle == .closing || lifecycle == .closed }

    func close(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        if lifecycle == .closed {
            completion()
            return
        }
        closeCompletions.append(completion)
        guard lifecycle != .closing else { return }
        let wasReplacing = lifecycle == .replacing
        lifecycle = .closing
        firstFrameObservation = nil
        updatePresentationReadiness()
        view.onWindowAttachmentChange = nil
        onPresentationChange = nil
        finishReplacement(.failed)
        cancelFramePublicationWait()
        previewRelay.renderer = nil
        renderer?.callbackBox.failureRelay.renderer = nil
        managedSurface?.prepareForPermanentRemoval()
        guard !wasReplacing else { return }
        guard let renderer else {
            finishCloseIfRendererless()
            return
        }
        fence.unregisterRenderer(renderer.handle) { [self] in
            renderer.control.invalidate()
            ghostty_terminal_surface_free(renderer.handle)
            if self.renderer?.handle == renderer.handle { self.renderer = nil }
            finishCloseIfRendererless()
        }
    }

    /// Cancel a pending picker frame before pane selection owns the surface.
    /// Invalidating the observation prevents a delayed preview completion
    /// from racing the pane's presentation.
    func cancelPickerCaptureForPresentation() {
        cancelFramePublicationWait()
    }

    func capturePickerPreview(
        columns: UInt32,
        rows: UInt32,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> CGImage? {
        guard lifecycle == .active,
              framePublicationWait == nil,
              replacementCompletion == nil, rendererIsAvailable, presentationFailure == nil,
              columns > 0, rows > 0,
              let renderer,
              let rendererLayer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer)
        else { return nil }
        let current = renderer.control.currentSize()

        guard (current.columns == columns && current.rows == rows)
                || isViewportSized(current)
        else { return nil }

        let frame: GhosttyIOSurfaceFrame
        if presented {
            guard let dimensions = GhosttyIOSurfaceFrame.dimensions(in: rendererLayer),
                  let sourceRect = previewSourceRect(
                    width: dimensions.width,
                    height: dimensions.height,
                    budget: budget
                  )
            else { return nil }
            guard let published = try? GhosttyIOSurfaceFrame.read(
                from: rendererLayer,
                sourceRect: sourceRect
            ) else { return nil }
            frame = published
        } else {
            guard let published = await matchingPublication(
                on: rendererLayer, budget: budget
            )
            else { return nil }
            frame = published
        }

        guard let image = await makePreviewImage(
            from: frame,
            budget: budget
        ) else {
            return nil
        }
        return image
    }

    func reportRendererFailure() { rendererDidFail() }

    private func rendererDidFail() {
        guard !isClosing, !rendererFailureReported, presentationFailure == nil else { return }
        if replacementCompletion != nil {
            failPresentation(message: "Terminal renderer could not recover. Reconnect to try again.")
            return
        }
        guard lifecycle == .active else { return }
        rendererFailureReported = true
        rendererIsAvailable = false
        firstFrameObservation = nil
        cancelFramePublicationWait()
        updatePresentationReadiness()
        beginRendererRecovery()
        onRendererFailure()
    }

    #if DEBUG
    var isAwaitingReplacementFrameForTesting: Bool {
        lifecycle == .active && replacementCompletion != nil
    }
    func rendererFailureCallbackForTesting() -> () -> Void {
        let relay = renderer?.callbackBox.failureRelay
        return { [weak relay] in relay?.renderer?.rendererDidFail() }
    }
    #endif

    private func beginRendererRecovery() {
        guard let managedSurface else { return }
        // Keep the last successful frame until recovery succeeds. A failed
        // replacement may already have published pixels that are not usable.
        let snapshot = managedSurface.rendererRecoverySnapshot == nil ? currentRendererSnapshot() : nil
        managedSurface.beginRendererRecovery(snapshot: snapshot)
    }

    private func currentRendererSnapshot() -> CGImage? {
        guard let layer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer),
              let frame = try? GhosttyIOSurfaceFrame.read(from: layer),
              let width = UInt32(exactly: frame.width),
              let height = UInt32(exactly: frame.height)
        else { return nil }
        return try? frame.image(maxWidth: width, maxHeight: height)
    }

    private func applyPresentationActivity() {
        guard lifecycle == .active else {
            updatePresentationReadiness()
            return
        }
        if presented, view.window != nil {
            isPreparing = false
        } else if isPreparing, sceneActive, !hasPublishedFrame {
            // Asked again as the pane's state changes until its first picture is in; Ghostty coalesces requests.
            renderer?.control.requestFrame()
        }
        let visible = presented && sceneActive && presentationFailure == nil
        let active = focused && visible
        if let managedSurface {
            managedSurface.setFocused(active)
            managedSurface.setVisible(visible)
        } else {
            _ = renderer?.control.setFocused(active)
            _ = renderer?.control.setVisible(visible)
        }
        if let layer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer) {
            recordFirstFrameIfPublished(on: layer)
        }
        updatePresentationReadiness()
    }

    private func destroyUnregisteredRenderer() {
        lifecycle = .closed
        firstFrameObservation = nil
        firstFrameDeadline?.cancel()
        view.onWindowAttachmentChange = nil
        cancelFramePublicationWait()
        previewRelay.renderer = nil
        renderer?.callbackBox.failureRelay.renderer = nil
        renderer?.control.invalidate()
        if let renderer { ghostty_terminal_surface_free(renderer.handle) }
        renderer = nil
    }

    private func finishCloseIfRendererless() {
        guard lifecycle == .closing, renderer == nil else { return }
        lifecycle = .closed
        let completions = closeCompletions
        closeCompletions.removeAll()
        for completion in completions { completion() }
    }

    private static func configured(
        _ base: ghostty_terminal_surface_config_s,
        view: GhosttyKitSurfaceView,
        metrics: GhosttySurfaceDisplayMetrics,
        callbackBox: CallbackBox,
        visible: Bool,
        focused: Bool
    ) -> ghostty_terminal_surface_config_s {
        var config = base
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(callbackBox).toOpaque()
        config.renderer_health_cb = CallbackBox.healthCallback
        config.write_cb = callbackBox.writeInput == nil ? nil : CallbackBox.writeCallback
        config.scale_factor = metrics.contentScale
        config.width_px = metrics.pixelWidth
        config.height_px = metrics.pixelHeight
        config.visible = visible
        config.focused = focused
        return config
    }

    private func matchingPublication(
        on layer: CALayer,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> GhosttyIOSurfaceFrame? {
        // Drain stale display invalidation before observing the next renderer
        // publication.
        layer.displayIfNeeded()
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled, framePublicationWait == nil else {
                continuation.resume(returning: nil)
                return
            }
            let wait = FramePublicationWait(budget: budget)
            let layerReference = LayerReference(layer)
            let relay = previewRelay
            wait.continuation = continuation
            framePublicationWait = wait
            wait.timeoutTask = Task { @MainActor [weak self, weak wait] in
                try? await Task.sleep(for: Self.framePublicationTimeout)
                guard !Task.isCancelled, let self, let wait else { return }
                self.finishFramePublicationWait(wait, publication: nil)
            }
            wait.observation = layer.observe(\.contents, options: [.new]) { [weak wait] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let renderer = relay.renderer,
                              let wait,
                              let layer = layerReference.layer
                        else { return }
                        renderer.finishFramePublicationIfMatching(wait, layer: layer)
                    }
                }
            }
            guard renderer?.control.requestFrame() == true else {
                finishFramePublicationWait(wait, publication: nil)
                return
            }
        }
    }

    private func finishFramePublicationIfMatching(
        _ wait: FramePublicationWait,
        layer: CALayer
    ) {
        guard framePublicationWait === wait,
              let dimensions = GhosttyIOSurfaceFrame.dimensions(in: layer)
        else { return }

        guard let sourceRect = previewSourceRect(
            width: dimensions.width, height: dimensions.height, budget: wait.budget
        ) else {
            finishFramePublicationWait(wait, publication: nil)
            return
        }
        let frame: GhosttyIOSurfaceFrame
        do {
            frame = try GhosttyIOSurfaceFrame.read(from: layer, sourceRect: sourceRect)
        } catch {
            GhosttyRuntimeTrace.diagnostics(
                "terminalPane.frameRead failed \(diagnosticName) error=\(String(describing: error))"
            )
            finishFramePublicationWait(wait, publication: nil)
            return
        }
        finishFramePublicationWait(wait, publication: frame)
    }

    private func finishFramePublicationWait(
        _ wait: FramePublicationWait,
        publication: GhosttyIOSurfaceFrame?
    ) {
        guard framePublicationWait === wait else { return }
        wait.timeoutTask?.cancel()
        wait.timeoutTask = nil
        wait.observation?.invalidate()
        wait.observation = nil
        framePublicationWait = nil
        let continuation = wait.continuation
        wait.continuation = nil
        continuation?.resume(returning: publication)
    }

    private func cancelFramePublicationWait() {
        guard let wait = framePublicationWait else { return }
        finishFramePublicationWait(wait, publication: nil)
    }

    private func makePreviewImage(
        from frame: GhosttyIOSurfaceFrame,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> CGImage? {
        let diagnosticName = diagnosticName
        return await Task.detached(priority: .userInitiated) {
            do {
                return try frame.image(
                    maxWidth: budget.width,
                    maxHeight: budget.height
                )
            } catch {
                GhosttyRuntimeTrace.diagnostics(
                    "terminalPane.previewRead failed \(diagnosticName) error=\(String(describing: error))"
                )
                return nil
            }
        }.value
    }

    private func previewSourceRect(
        width: Int,
        height: Int,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) -> CGRect? {
        let viewportAnchor = CGRect(x: 0, y: 0, width: width, height: height)
        let cropAnchor: CGRect
        if let cursor = renderer?.control.cursorGeometry() {
            let scale = CGFloat(canonicalViewportMetrics.contentScale)
            cropAnchor = CGRect(
                x: cursor.minX * scale,
                y: cursor.minY * scale,
                width: cursor.width * scale,
                height: cursor.height * scale
            )
        } else {
            cropAnchor = viewportAnchor
        }
        let cropWidth = UInt32(clamping: UInt64(budget.width) * 2)
        let cropHeight = UInt32(clamping: UInt64(budget.height) * 2)
        return GhosttyIOSurfaceFrame.sourceRect(
            width: width,
            height: height,
            centeredOn: cropAnchor,
            maxWidth: cropWidth,
            maxHeight: cropHeight
        ) ?? GhosttyIOSurfaceFrame.sourceRect(
            width: width,
            height: height,
            centeredOn: viewportAnchor,
            maxWidth: cropWidth,
            maxHeight: cropHeight
        )
    }

    private func isViewportSized(_ size: ghostty_surface_size_s) -> Bool {
        size.width_px == canonicalViewportMetrics.pixelWidth
            && size.height_px == canonicalViewportMetrics.pixelHeight
    }

    private func applyDisplayMetrics(
        _ metrics: GhosttySurfaceDisplayMetrics
    ) -> Bool {
        guard let renderer,
              metrics.contentScale == canonicalViewportMetrics.contentScale
        else { return false }
        if metrics == appliedDisplayMetrics { return true }
        view.frame.size = CGSize(
            width: Double(metrics.pixelWidth) / metrics.contentScale,
            height: Double(metrics.pixelHeight) / metrics.contentScale
        )
        view.contentScaleFactor = metrics.contentScale
        view.alignGhosttyRendererSublayers()
        guard renderer.control.updateDisplay(metrics: metrics) else {
            return false
        }
        appliedDisplayMetrics = metrics
        // Selection geometry is in surface pixels.
        managedSurface?.notifyLocalSelectionGeometryChanged()
        return true
    }

    deinit {
        let finalLifecycle = lifecycle
        assert(finalLifecycle == .closed, "TerminalPaneRenderer deinit without close()")
    }
}
