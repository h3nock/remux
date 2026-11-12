import Foundation
import GhosttyKit

extension TmuxSessionController.RetainedPaneTerminal: RetainedGhosttyTerminal {}

/// One tmux pane's renderer and input path. The renderer owns the retained
/// pane terminal and its native lifetime; this type adds what is tmux's: the
/// controller fence, input writes, including writes awaited until tmux
/// answers the send-keys command that carries them, and pastes, which tmux
/// writes to the pane itself.
@MainActor
final class TmuxPaneSurface: TerminalPaneInputSink {
    let paneID: TmuxPaneID
    let renderer: TerminalPaneRenderer
    private let binding: RendererBinding

    static func create(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        terminal: TmuxSessionController.RetainedPaneTerminal,
        baseConfig: ghostty_terminal_surface_config_s,
        metrics: GhosttySurfaceDisplayMetrics,
        theme: TerminalTheme,
        onRendererFailure: @escaping @MainActor (TmuxPaneID) -> Void,
        completion: @escaping @MainActor (Result<TmuxPaneSurface, TerminalPaneRenderer.CreateError>) -> Void
    ) {
        create(
            app: app,
            controller: controller,
            terminal: terminal,
            baseConfig: baseConfig,
            metrics: metrics,
            theme: theme,
            onRendererFailure: onRendererFailure,
            wrapFence: { $0 },
            completion: completion
        )
    }

    /// `wrapFence` stands between the renderer and the controller's fence, where a test can hold an
    /// unregistration back.
    static func create(
        app: ghostty_app_t,
        controller: TmuxSessionController,
        terminal: TmuxSessionController.RetainedPaneTerminal,
        baseConfig: ghostty_terminal_surface_config_s,
        metrics: GhosttySurfaceDisplayMetrics,
        theme: TerminalTheme,
        onRendererFailure: @escaping @MainActor (TmuxPaneID) -> Void,
        wrapFence: (any TerminalPaneRendererFence) -> any TerminalPaneRendererFence,
        completion: @escaping @MainActor (Result<TmuxPaneSurface, TerminalPaneRenderer.CreateError>) -> Void
    ) {
        let paneID = terminal.paneID
        let binding = RendererBinding(controller: controller, paneID: paneID)
        TerminalPaneRenderer.create(
            app: app,
            terminal: terminal,
            fence: wrapFence(binding),
            writeInput: { [binding] bytes in binding.write(bytes) },
            baseConfig: baseConfig,
            metrics: metrics,
            theme: theme,
            diagnosticName: "pane=\(paneID)",
            onRendererFailure: { onRendererFailure(paneID) }
        ) { result in
            completion(result.map { TmuxPaneSurface(paneID: paneID, renderer: $0, binding: binding) })
        }
    }

    private init(paneID: TmuxPaneID, renderer: TerminalPaneRenderer, binding: RendererBinding) {
        self.paneID = paneID
        self.renderer = renderer
        self.binding = binding
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        renderer.screenSurface(id: id, inputSink: self)
    }

    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool {
        await withCheckedContinuation { continuation in
            if !binding.sendPaste(text, completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: false)
            }
        }
    }

    func sendKeyEventAwaitingCommandCompletion(
        _ event: GhosttySurfaceKeyEvent
    ) async -> Bool {
        guard let control = renderer.inputControlSurface else { return false }
        return await withCheckedContinuation { continuation in
            binding.performTrackedWrite(completion: { continuation.resume(returning: $0) }) {
                control.sendKeyEvent(event)
            }
        }
    }
}

/// The controller fence and input writer for one tmux pane's renderers.
@MainActor
private final class RendererBinding: TerminalPaneRendererFence {
    private let controller: TmuxSessionController
    private let paneID: TmuxPaneID
    private var trackedWriteCompletion: (@Sendable (Bool) -> Void)?

    init(controller: TmuxSessionController, paneID: TmuxPaneID) {
        self.controller = controller
        self.paneID = paneID
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        controller.registerTerminalSurface(paneID: paneID, surface: surface) { result in
            completion(result.mapError { $0 as any Error })
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        controller.unregisterTerminalSurface(paneID: paneID, surface: surface, completion: completion)
    }

    /// `write_cb` runs only inside the renderer's input operations, so a
    /// tracked write armed by `performTrackedWrite` receives exactly the bytes
    /// its operation encodes.
    func write(_ data: Data) -> Bool {
        guard let completion = trackedWriteCompletion else {
            return controller.sendInput(paneID: paneID, data)
        }
        trackedWriteCompletion = nil
        let admitted = controller.sendTrackedInput(paneID: paneID, data, completion: completion)
        if !admitted {
            completion(false)
        }
        return admitted
    }

    func performTrackedWrite(
        completion: @escaping @Sendable (Bool) -> Void,
        _ operation: () -> Bool
    ) {
        precondition(trackedWriteCompletion == nil)
        trackedWriteCompletion = completion
        _ = operation()
        guard trackedWriteCompletion != nil else { return }
        trackedWriteCompletion = nil
        completion(false)
    }

    /// A paste doesn't pass through the pane's terminal: tmux knows whether
    /// the pane's program asked for bracketed paste, and the terminal here
    /// knows only what the program has said since this client attached.
    func sendPaste(_ text: String, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        controller.sendPaste(paneID: paneID, text, completion: completion)
    }
}
