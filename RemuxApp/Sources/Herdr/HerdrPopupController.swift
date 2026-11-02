import Foundation
import GhosttyKit

/// The grid a popup gets: the panes' grid inside Herdr's frame, whose lines take its outer cells, as Herdr's
/// client blits a popup's terminal inside its box, or the whole grid when it is too small for a frame
/// (`GhosttyTerminalViewportPresentationProjection.Popup.content(in:)`). Cells of the panes' font, never
/// scaled, so the popup's text is the panes' size and the keyboard takes rows, not size.
struct HerdrPopupGrid: Equatable, Sendable, CustomStringConvertible {
    let columns: UInt16
    let rows: UInt16

    /// The popup's cells on the panes' grid of `columns` x `rows`; nil for an empty grid.
    init?(in columns: UInt16, rows: UInt16) {
        let grid = GhosttyTerminalGridSize(columns: UInt32(columns), rows: UInt32(rows))
        guard let content = GhosttyTerminalViewportPresentationProjection.Popup.content(in: grid) else { return nil }
        self.init(columns: UInt16(content.columns), rows: UInt16(content.rows))
    }

    init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    var description: String { "\(columns)x\(rows)" }

    func displayMetrics(cell: GhosttyTerminalCellDisplayMetrics) -> GhosttySurfaceDisplayMetrics {
        GhosttySurfaceDisplayMetrics(
            contentScale: cell.contentScale,
            pixelWidth: UInt32(columns) * cell.pixelWidth,
            pixelHeight: UInt32(rows) * cell.pixelHeight
        )
    }
}

/// The renderer of the popup over the tab: over its attachment's terminal, or over the terminal the engine
/// paints from Herdr's popup frame when it can't be attached. Either way its input goes as Herdr's client
/// sends a popup's (`HerdrPopupController.Input`).
@MainActor
final class HerdrPopupTerminalSurface: TerminalPaneInputSink {
    let terminalID: String
    let terminal: HerdrRetainedTerminal
    let renderer: TerminalPaneRenderer
    /// Over the attachment's terminal, rather than the one painted from Herdr's frame.
    let isAttached: Bool
    /// The composer's input for this popup's terminal, which learns whether Herdr has it.
    private let deliver: ([HerdrInputEvent]) async -> Bool
    /// The grid the renderer draws, which is also its scroll range (`applyScrollRange`). Another width ends
    /// the selection, as a pane's does: Herdr draws the popup again at that width, and its lines move.
    fileprivate(set) var grid: HerdrPopupGrid {
        didSet {
            applyScrollRange()
            if grid.columns != oldValue.columns { renderer.managedSurface?.endSelection() }
        }
    }

    fileprivate init(
        terminalID: String,
        terminal: HerdrRetainedTerminal,
        renderer: TerminalPaneRenderer,
        isAttached: Bool,
        deliver: @escaping ([HerdrInputEvent]) async -> Bool,
        grid: HerdrPopupGrid
    ) {
        self.terminalID = terminalID
        self.terminal = terminal
        self.renderer = renderer
        self.isAttached = isAttached
        self.deliver = deliver
        self.grid = grid
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        let managed = renderer.screenSurface(id: id, inputSink: self)
        applyScrollRange()
        return managed
    }

    /// Herdr doesn't say how far back a popup's history goes, so its scroll range is its grid, and a swipe goes
    /// to Herdr's wheel handling, as a pane's does.
    private func applyScrollRange() {
        let rows = UInt64(grid.rows)
        renderer.managedSurface?.setRemoteScroll(
            GhosttySurfaceScrollState(total: rows, offset: 0, len: rows, cellOffset: 0),
            route: .remoteHistory
        )
    }

    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        return await deliver([.paste(text)])
    }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool {
        guard let event = HerdrInputTranslator.event(for: event) else { return false }
        return await deliver([event])
    }
}

/// The popup Herdr shows over the tab on screen, while the phone shows it. Herdr's client draws a popup at
/// a share of its screen; Remux instead attaches straight to the popup's terminal, as `herdr terminal
/// attach` does, at the grid that fills the terminal area at the panes' font. Herdr's resize lock then keeps
/// the popup at the phone's size whatever other clients do, until the phone lets it go and Herdr gives the
/// size back, so the phone holds the popup only while it is on the phone's screen. When Herdr refuses the
/// attach or it fails, the popup's frame is drawn as Herdr sends it to this client, at the panes' font.
/// Its input goes as Herdr's client sends a popup's either way, which Herdr encodes for the program's modes
/// and which makes the phone the client Herdr sends the program's clipboard writes to.
///
/// Three grids are kept apart: the one the area holds, which goes to Herdr once the area settles; the one
/// Herdr's frames have; and the one the renderer draws, which follows the frames', so the screen always
/// shows whole frames. Each attach has a generation, so nothing from an attach let go reaches the screen.
@MainActor
final class HerdrPopupController {
    typealias AttachmentFactory = @MainActor (_ terminalID: String, HerdrTerminalAttachment.Geometry) -> HerdrTerminalAttachment
    typealias FrameFenceFactory = @MainActor (_ terminalID: String, HerdrRetainedTerminal) -> any TerminalPaneRendererFence

    /// The popup's input, as Herdr's client sends a popup's.
    struct Input {
        /// Typing, read as Herdr's client reads a terminal's for the popup's keyboard modes.
        let text: (String) -> FocusedTerminalInputSubmissionResult
        /// Input in the order it is typed.
        let send: ([HerdrInputEvent]) -> FocusedTerminalInputSubmissionResult
        /// The composer's input for one popup terminal, which learns whether Herdr has it; false when that
        /// popup is no longer on screen.
        let deliver: (_ terminalID: String, [HerdrInputEvent]) async -> Bool
    }

    struct RendererActivity: Equatable {
        var sceneActive = true
        var presented = false
        var focused = false
    }

    private struct Attached {
        let generation: UInt64
        let attachment: HerdrTerminalAttachment
        /// The grid of the frames that came, once the first did.
        var received: HerdrPopupGrid?
        var listening: Task<Void, Never>?
    }

    private let makeAttachment: AttachmentFactory
    private let makeFrameFence: FrameFenceFactory
    /// Tells the engine whether to paint the popup's frames, with a revision that orders the calls.
    private let paintFrames: (Bool, UInt64) -> Void
    private let input: Input
    /// Herdr refused the attach because another device holds the popup.
    private let onHeldElsewhere: () -> Void
    /// A new renderer, which the screen gives its surface.
    private let onSurface: (HerdrPopupTerminalSurface) -> Void
    private let onChange: () -> Void

    private var runtime: GhosttyKitRuntime?
    private var theme: TerminalTheme
    /// The popup open as far as the phone can tell, with the tab it is open over and the server boot of its
    /// id: what the frames last showed of it. Herdr shows a popup only on the tab it was opened on, and leaves
    /// it out of a surface too small to box it, so it stays known until there is word it closed: an attach to
    /// it ends as its terminal is gone (`ended`), or a frame of its tab that could show it doesn't
    /// (`HerdrPaneLayout.showsClosed`). Nothing else forgets it: not the phone letting it go, nor a visit to
    /// another tab, nor a refusal to try again.
    private var known: (popup: HerdrPaneLayout.Popup, tabID: String?, bootID: String)?
    /// Whether the layout on screen is of the known popup's tab.
    private var onItsTab = false
    /// Whether the layout on screen shows the known popup; otherwise only an attach shows it.
    private var inFrame = false
    /// Whether the attach's program reads the mouse, as Herdr sends it to the attach as it changes
    /// (`server/headless/render.rs` `stream_host_mouse_capture_mode`).
    private var attachReadsMouse = false
    private var held = false
    private var activity = RendererActivity()
    private var cell: GhosttyTerminalCellDisplayMetrics?
    /// The phone's viewport grid, which the popup is framed on independently of its covered tab.
    private var viewport: (columns: UInt16, rows: UInt16)?
    /// The grid inside the frame now.
    private(set) var requested: HerdrPopupGrid?
    /// The attach's geometry last sent to Herdr, its grid and its cell, which a new grid or cell is compared
    /// against as one.
    private var asked: HerdrTerminalAttachment.Geometry?
    /// When it was sent, until Herdr's frames have its grid.
    private var askedAt: ContinuousClock.Instant?
    private var attached: Attached?
    private var generation: UInt64 = 0
    /// Popups drawn from their frames, until they close or a reconnect.
    private var framed: Set<String> = []
    private var frameTerminal: (terminalID: String, terminal: HerdrRetainedTerminal)?
    /// Whether the engine paints the popup's frames, as last told.
    private var paintsFrames = false
    private var paintsFramesRevision: UInt64 = 0
    private(set) var surface: HerdrPopupTerminalSurface?
    private var creating: ObjectIdentifier?
    private var failure: TerminalDisconnectReason?
    private var settle: Task<Void, Never>?
    /// The popup Herdr asked to attach to again, once (`Ending.busy`), and the wait before it.
    private var retried: String?
    private var retry: Task<Void, Never>?

    /// How long the area must stay put before its grid goes to Herdr: the keyboard and rotation move the
    /// area, and each resize makes the program redraw.
    static let settleDelay: Duration = .milliseconds(150)
    /// How long to wait before attaching again when Herdr asks to try again.
    static let retryDelay: Duration = .milliseconds(250)

    init(
        theme: TerminalTheme,
        makeAttachment: @escaping AttachmentFactory,
        makeFrameFence: @escaping FrameFenceFactory,
        paintFrames: @escaping (Bool, UInt64) -> Void,
        input: Input,
        onHeldElsewhere: @escaping () -> Void,
        onSurface: @escaping (HerdrPopupTerminalSurface) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.theme = theme
        self.makeAttachment = makeAttachment
        self.makeFrameFence = makeFrameFence
        self.paintFrames = paintFrames
        self.input = input
        self.onHeldElsewhere = onHeldElsewhere
        self.onSurface = onSurface
        self.onChange = onChange
    }

    // MARK: - What the model tells

    func setRuntime(_ runtime: GhosttyKitRuntime?) {
        self.runtime = runtime
        reconcile()
    }

    /// The layout on screen. A popup it shows is the known one; another terminal id is another popup, as Herdr
    /// has one at a time.
    func update(from layout: HerdrPaneLayout) {
        if let known,
           known.bootID != layout.bootID || layout.showsClosed(popup: known.popup.terminalID, openedOn: known.tabID) {
            forget()
        }
        if let next = layout.popup {
            if next.terminalID != known?.popup.terminalID { forget() }
            known = (next, layout.tab?.tabID, layout.bootID)
        }
        onItsTab = known.map { layout.tab?.tabID == $0.tabID } ?? false
        inFrame = layout.popup != nil
        followFrameGrid()
        reconcile()
    }

    /// Whether the popup is on the phone's screen, which is when the phone holds it.
    func setHeld(_ next: Bool) {
        guard next != held else { return }
        held = next
        reconcile()
    }

    func setRendererActivity(_ next: RendererActivity) {
        activity = next
        applyActivity()
    }

    /// The panes' cell and grid, from the screen's font, scale and size.
    func setViewport(cell next: GhosttyTerminalCellDisplayMetrics, columns: UInt16, rows: UInt16) {
        guard next != cell || viewport.map({ $0.columns != columns || $0.rows != rows }) ?? true else { return }
        cell = next
        viewport = (columns, rows)
        planGrid()
    }

    /// False when the renderer can't take the theme.
    func applyTheme(_ next: TerminalTheme) -> Bool {
        theme = next
        guard let surface, !surface.renderer.isClosing else { return true }
        return surface.renderer.applyTerminalConfiguration(theme: next)
    }

    /// The engine's terminal for a popup drawn from its frames.
    func takeFrameTerminal(_ terminal: HerdrRetainedTerminal, terminalID: String) {
        frameTerminal = (terminalID, terminal)
        reconcile()
    }

    func frameTerminalFailed(terminalID: String) {
        guard frameTerminal?.terminalID == terminalID else { return }
        frameTerminal = nil
        failure = Self.rendererFailure
        onChange()
    }

    func rendererWakeFailed(terminalID: String) {
        guard let surface, surface.terminalID == terminalID else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        onChange()
    }

    /// A reconnect tries a popup that couldn't be attached again.
    func retryAttach() {
        framed.removeAll()
        retried = nil
        failure = nil
        reconcile()
    }

    func stop() {
        held = false
        forget()
    }

    // MARK: - What the screen reads

    /// The popup over the tab on screen, which takes the tab's input: the known popup, while the screen shows
    /// its tab and there is something to draw it from, Herdr's frame of it or an attach to it. With neither,
    /// as when Herdr leaves out of its surface a popup that couldn't be attached, the panes show, as in
    /// Herdr's client on a surface too small for the popup; the popup stays known, and shows again once
    /// either comes.
    var popup: HerdrPaneLayout.Popup? {
        guard onItsTab, let known, inFrame || !framed.contains(known.popup.terminalID) else { return nil }
        return known.popup
    }

    /// The popup uses its terminal attachment, including opening and the existing busy retry. Renderer
    /// availability and a temporary detach for background/reconnect do not change how it will be sized.
    var resizesIndependently: Bool {
        guard let popup else { return false }
        return !framed.contains(popup.terminalID)
    }

    /// Whether the popup's program reads the mouse, as what it is drawn from says: its attach while attached,
    /// else Herdr's frame of it.
    var reportsMouse: Bool {
        guard let popup else { return false }
        return attached != nil ? attachReadsMouse : popup.mouseReporting
    }

    /// Whether the popup takes the tab's input: it is on screen and the phone holds it.
    var takesInput: Bool { popup != nil && held }

    var presentation: TerminalPanePresentation {
        if let failure { return .failed(failure) }
        return surface?.renderer.presentation ?? .pending
    }

    /// The renderer's grid and the cell it draws with.
    var displayed: (grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics)? {
        guard let surface, let cell else { return nil }
        return (surface.grid, cell)
    }

    // MARK: - Input

    func sendText(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        return input.text(text)
    }

    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        return input.send([.paste(text)])
    }

    func sendKey(_ key: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard takesInput else { return .transportUnavailable }
        guard let event = HerdrInputTranslator.event(for: key) else {
            return key.action == .release ? .accepted : .surfaceRejected
        }
        return input.send([event])
    }

    /// A swipe's wheel steps, a row each, up for positive `rows`, as Herdr's client sends a popup's wheel: on
    /// the keys' queue, so a key after a swipe comes after all of its steps. Herdr routes each as the program
    /// asks, a mouse report, cursor keys on the alternate screen, or the terminal's history.
    func scroll(rows: Int, column: UInt16, row: UInt16) -> Bool {
        guard takesInput else { return false }
        guard rows != 0 else { return true }
        let wheel = HerdrMouseEvent(
            kind: rows > 0 ? .scrollUp : .scrollDown,
            column: column,
            row: row,
            modifiers: [],
            lines: 1
        )
        return input.send(Array(repeating: .mouse(wheel), count: Int(rows.magnitude))) == .accepted
    }

    /// A button pressed or released at a cell of the popup's terminal.
    func sendMouse(_ kind: HerdrMouseEvent.Kind, column: UInt16, row: UInt16, modifiers: HerdrKeyModifiers) -> Bool {
        guard takesInput else { return false }
        return input.send([.mouse(HerdrMouseEvent(kind: kind, column: column, row: row, modifiers: modifiers))]) == .accepted
    }

    // MARK: - Holding the popup

    private func reconcile() {
        guard let popup, held, runtime != nil else {
            release()
            return
        }
        if framed.contains(popup.terminalID) {
            detach()
            setPaintsFrames(true)
            createFramedRendererIfPossible(popup)
        } else {
            setPaintsFrames(false)
            if attached == nil, retry == nil, let requested, let cell {
                attach(popup.terminalID, grid: requested, cell: cell)
            }
        }
    }

    private func planGrid() {
        guard let viewport, cell != nil,
              let next = HerdrPopupGrid(in: viewport.columns, rows: viewport.rows)
        else { return }
        requested = next
        // A cell of another size draws the renderer's grid at that size, as a pane's does.
        if let surface, let cell {
            _ = surface.renderer.updateDisplay(metrics: surface.grid.displayMetrics(cell: cell))
        }
        if attached?.received != nil {
            scheduleResize()
        } else {
            // Not attached yet: the attach asks for the newest grid.
            reconcile()
        }
    }

    private func scheduleResize() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.resize()
        }
    }

    private func resize() {
        guard let attached, let requested, let cell else { return }
        let geometry = Self.geometry(requested, cell: cell)
        guard geometry != asked else { return }
        asked = geometry
        askedAt = .now
        Task { await attached.attachment.resize(to: geometry) }
    }

    private func attach(_ terminalID: String, grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics) {
        generation += 1
        let generation = generation
        // Herdr sends the program's mouse capture as the attach begins.
        attachReadsMouse = false
        let attachment = makeAttachment(terminalID, Self.geometry(grid, cell: cell))
        var next = Attached(generation: generation, attachment: attachment)
        next.listening = Task { [weak self] in
            for await event in attachment.updates {
                guard let self, self.attached?.generation == generation else { return }
                self.receive(event, generation: generation)
            }
        }
        attached = next
        asked = Self.geometry(grid, cell: cell)
        askedAt = .now
        Task { await attachment.run() }
        GhosttyRuntimeTrace.diagnostics("popup attach terminal=\(terminalID) grid=\(grid)")
    }

    private func receive(_ event: HerdrTerminalAttachment.Event, generation: UInt64) {
        switch event {
        case .terminal(let terminal, let columns, let rows):
            let grid = HerdrPopupGrid(columns: columns, rows: rows)
            attached?.received = grid
            createAttachedRenderer(terminal: terminal, grid: grid, generation: generation)
            // The area or the cell may have changed while the attach was on its way.
            scheduleResize()
        case .grid(let columns, let rows):
            let grid = HerdrPopupGrid(columns: columns, rows: rows)
            attached?.received = grid
            if let surface, surface.isAttached, let cell {
                surface.grid = grid
                _ = surface.renderer.updateDisplay(metrics: grid.displayMetrics(cell: cell))
                logLayout()
            }
            onChange()
        case .mouseCapture(let enabled):
            attachReadsMouse = enabled
        case .ended(let ending):
            ended(ending)
        }
    }

    private func ended(_ ending: HerdrTerminalAttachment.Ending) {
        guard let popup else { return }
        attached?.listening?.cancel()
        attached = nil
        settle?.cancel()
        asked = nil
        askedAt = nil
        // A renderer still being made for the attach closes once made.
        creating = nil
        let terminalID = popup.terminalID
        switch ending {
        case .detached:
            return
        case .closed(let reason):
            // Word the popup closed; frames that still show it were drawn before it did.
            GhosttyRuntimeTrace.diagnostics("popup attach ended terminal=\(terminalID) reason=\(reason)")
            forget()
            onChange()
            return
        case .missing(let reason) where !inFrame:
            // Herdr has no such terminal, and no frame says the popup is open: it closed out of sight.
            GhosttyRuntimeTrace.diagnostics("popup attach missing terminal=\(terminalID) reason=\(reason)")
            forget()
            onChange()
            return
        case .held(let reason):
            GhosttyRuntimeTrace.diagnostics("popup attach held elsewhere terminal=\(terminalID) reason=\(reason)")
            onHeldElsewhere()
        case .busy(let reason) where retried != terminalID:
            // Once: Herdr asks to try again while an agent reads the terminal, which takes a moment.
            GhosttyRuntimeTrace.diagnostics("popup attach busy terminal=\(terminalID) reason=\(reason)")
            retried = terminalID
            closeSurface()
            retry = Task { [weak self] in
                try? await Task.sleep(for: Self.retryDelay)
                guard !Task.isCancelled, let self else { return }
                self.retry = nil
                self.reconcile()
            }
            return
        case .busy(let reason), .refused(let reason), .missing(let reason):
            // A frame that shows the popup says it is open, which outweighs a refusal for a missing terminal.
            GhosttyRuntimeTrace.diagnostics("popup attach refused terminal=\(terminalID) reason=\(reason)")
        case .failed(let reason):
            GhosttyRuntimeTrace.diagnostics("popup attach failed terminal=\(terminalID) reason=\(reason)")
        }
        closeSurface()
        framed.insert(terminalID)
        reconcile()
        onChange()
    }

    /// One record per layout the renderer draws: the grid the area holds, the frames', and the renderer's,
    /// which agree once the layout settles, and how long the frames took to follow.
    private func logLayout() {
        guard let popup, let cell, let surface else { return }
        let received = attached?.received
        var settledIn = "-"
        if let askedAt, let received, Self.geometry(received, cell: cell) == asked {
            let elapsed = (ContinuousClock.now - askedAt).components
            settledIn = "\(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)ms"
            self.askedAt = nil
        }
        GhosttyRuntimeTrace.diagnostics(
            "popup layout terminal=\(popup.terminalID) viewport=\(viewport.map { "\($0.columns)x\($0.rows)" } ?? "-") "
                + "scale=\(cell.contentScale) cell=\(cell.pixelWidth)x\(cell.pixelHeight)px "
                + "requested=\(requested?.description ?? "-") received=\(received?.description ?? "-") "
                + "displayed=\(surface.grid) "
                + "drawable=\(UInt32(surface.grid.columns) * cell.pixelWidth)x\(UInt32(surface.grid.rows) * cell.pixelHeight)px "
                + "cursor=\(surface.renderer.inputControlSurface?.cursorGeometry().map { "\($0.minX),\($0.minY)" } ?? "-") "
                + "settledIn=\(settledIn)"
        )
    }

    // MARK: - Renderers

    private func createAttachedRenderer(terminal: HerdrRetainedTerminal, grid: HerdrPopupGrid, generation: UInt64) {
        guard let runtime, let cell, let popup, let attached, attached.generation == generation else { return }
        closeSurface()
        let terminalID = popup.terminalID
        let deliver = input.deliver
        creating = ObjectIdentifier(terminal)
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: HerdrTerminalAttachmentFence(attachment: attached.attachment, terminal: terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: grid.displayMetrics(cell: cell),
            theme: theme,
            diagnosticName: "herdr popup=\(terminalID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(terminal) }
        ) { [weak self, runtime] result in
            guard let self, self.creating == ObjectIdentifier(terminal), self.attached?.generation == generation else {
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                self?.creationOutdated(terminal)
                return
            }
            self.creating = nil
            switch result {
            case .success(let renderer):
                // A newer grid may have come while the renderer was made.
                let current = self.attached?.received ?? grid
                if current != grid { _ = renderer.updateDisplay(metrics: current.displayMetrics(cell: cell)) }
                self.adopt(renderer)
                let surface = HerdrPopupTerminalSurface(
                    terminalID: terminalID,
                    terminal: terminal,
                    renderer: renderer,
                    isAttached: true,
                    deliver: { await deliver(terminalID, $0) },
                    grid: current
                )
                self.surface = surface
                self.onSurface(surface)
                self.applyActivity()
                self.logLayout()
            case .failure:
                self.failure = Self.rendererFailure
            }
            self.onChange()
        }
    }

    private func createFramedRendererIfPossible(_ popup: HerdrPaneLayout.Popup) {
        guard let runtime, let cell, let frameTerminal, frameTerminal.terminalID == popup.terminalID,
              surface?.terminal !== frameTerminal.terminal, creating == nil
        else { return }
        let terminal = frameTerminal.terminal
        let grid = HerdrPopupGrid(columns: popup.columns, rows: popup.rows)
        let deliver = input.deliver
        let terminalID = popup.terminalID
        closeSurface()
        creating = ObjectIdentifier(terminal)
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: makeFrameFence(popup.terminalID, terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: grid.displayMetrics(cell: cell),
            theme: theme,
            diagnosticName: "herdr popup frame=\(popup.terminalID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(terminal) }
        ) { [weak self, runtime] result in
            guard let self, self.creating == ObjectIdentifier(terminal), self.frameTerminal?.terminal === terminal else {
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                self?.creationOutdated(terminal)
                return
            }
            self.creating = nil
            switch result {
            case .success(let renderer):
                self.adopt(renderer)
                let surface = HerdrPopupTerminalSurface(
                    terminalID: popup.terminalID,
                    terminal: terminal,
                    renderer: renderer,
                    isAttached: false,
                    deliver: { await deliver(terminalID, $0) },
                    grid: grid
                )
                self.surface = surface
                self.onSurface(surface)
                self.followFrameGrid()
                self.applyActivity()
            case .failure:
                self.failure = Self.rendererFailure
            }
            self.onChange()
        }
    }

    /// A new renderer tells the screen when it has drawn, as a pane's does, and takes the theme, which may
    /// have changed while it was made.
    private func adopt(_ renderer: TerminalPaneRenderer) {
        renderer.onPresentationChange = { [weak self] in self?.onChange() }
        if !renderer.applyTerminalConfiguration(theme: theme) {
            renderer.failPresentation(message: Self.rendererFailureMessage)
        }
    }

    /// A renderer made for a terminal the popup no longer shows: another one may wait for it.
    private func creationOutdated(_ terminal: HerdrRetainedTerminal) {
        guard creating == ObjectIdentifier(terminal) else { return }
        creating = nil
        reconcile()
    }

    /// A framed popup's renderer draws the grid Herdr's frame has.
    private func followFrameGrid() {
        guard let popup, let surface, !surface.isAttached, let cell else { return }
        let grid = HerdrPopupGrid(columns: popup.columns, rows: popup.rows)
        guard grid != surface.grid else { return }
        surface.grid = grid
        _ = surface.renderer.updateDisplay(metrics: grid.displayMetrics(cell: cell))
    }

    private func applyActivity() {
        guard let surface else { return }
        surface.renderer.setSceneActive(activity.sceneActive)
        surface.renderer.setPresented(activity.presented)
        surface.renderer.setFocused(activity.focused)
    }

    private func rendererFailed(_ terminal: HerdrRetainedTerminal) {
        guard let surface, surface.terminal === terminal else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        onChange()
    }

    private func closeSurface() {
        guard let surface else { return }
        self.surface = nil
        surface.renderer.close { [runtime] in withExtendedLifetime(runtime) {} }
    }

    private func detach() {
        retry?.cancel()
        retry = nil
        guard let attached else { return }
        self.attached = nil
        attached.listening?.cancel()
        settle?.cancel()
        asked = nil
        askedAt = nil
        Task { await attached.attachment.detach() }
    }

    /// Word came that the known popup closed.
    private func forget() {
        known = nil
        onItsTab = false
        inFrame = false
        framed.removeAll()
        retried = nil
        failure = nil
        release()
    }

    /// The phone lets the popup go: Herdr gives its size back, and its renderer closes.
    private func release() {
        let holding = attached != nil || surface != nil || creating != nil || frameTerminal != nil
        detach()
        creating = nil
        closeSurface()
        setPaintsFrames(false)
        frameTerminal = nil
        if holding { onChange() }
    }

    private func setPaintsFrames(_ paints: Bool) {
        guard paints != paintsFrames else { return }
        paintsFrames = paints
        paintsFramesRevision += 1
        paintFrames(paints, paintsFramesRevision)
    }

    private static func geometry(_ grid: HerdrPopupGrid, cell: GhosttyTerminalCellDisplayMetrics) -> HerdrTerminalAttachment.Geometry {
        HerdrTerminalAttachment.Geometry(
            columns: grid.columns,
            rows: grid.rows,
            cellWidthPx: cell.pixelWidth,
            cellHeightPx: cell.pixelHeight
        )
    }

    static let rendererFailureMessage = "Terminal renderer is unavailable. Reconnect to try again."
    private static let rendererFailure = TerminalDisconnectReason(kind: .runtime, message: rendererFailureMessage)
}

/// Herdr's accent as a client can see it: Herdr sends no palette, but draws the focused pane's border lines
/// in the accent and the others in `overlay0` (`ui/panes.rs`), and Herdr's client draws a popup's border in
/// it (`client/shell/composition.rs`).
enum HerdrPopupAccent {
    /// The accent of Herdr's default theme, Catppuccin Mocha (`app/state.rs` `Palette::catppuccin`), which
    /// Herdr's client uses without a config (`config/theme.rs`, `app/mod.rs` `theme_runtime_config`).
    static let herdrDefault = HerdrColor(raw: 0x0289_B4FA)

    /// The colour of a border line along the text area of the pane the frame was drawn focused, nil when the
    /// tab draws none there.
    static func color(in layout: HerdrPaneLayout) -> HerdrColor? {
        guard let area = layout.panes.first(where: { $0.paneID == layout.focusedPaneID })?.innerRect else { return nil }
        let left = Int(area.x), right = Int(area.x) + Int(area.width)
        let top = Int(area.y), bottom = Int(area.y) + Int(area.height)
        // Lines run in half cells along their axis; a line along an edge overlaps the edge's span.
        func overlaps(_ line: HerdrBorderLine, from start: Int, to end: Int) -> Bool {
            Int(line.start) < 2 * end && Int(line.end) > 2 * start
        }
        return layout.borders.first { line in
            let track = Int(line.track)
            switch line.axis {
            case .horizontal:
                return (track == top - 1 || track == bottom) && overlaps(line, from: left, to: right)
            case .vertical:
                return (track == left - 1 || track == right || track == right + 1) && overlaps(line, from: top, to: bottom)
            }
        }?.color
    }
}
