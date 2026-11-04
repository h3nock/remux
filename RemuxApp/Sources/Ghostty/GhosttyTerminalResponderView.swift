import SwiftUI
import UIKit

@MainActor
final class GhosttyKeyboardResponderHandoff {
    enum Target {
        case terminal
        case composer
    }

    private weak var terminalResponder: UIView?
    private weak var composerResponder: UIView?

    func register(_ responder: UIView, as target: Target) {
        switch target {
        case .terminal:
            terminalResponder = responder
        case .composer:
            composerResponder = responder
        }
    }

    @discardableResult
    func transfer(to target: Target) -> Bool {
        let responder = switch target {
        case .terminal:
            terminalResponder
        case .composer:
            composerResponder
        }
        guard let responder, responder.window != nil else { return false }
        return responder.becomeFirstResponder()
    }

    /// Settles the terminal keyboard's composition before an app action, as a toolbar key
    /// (`GhosttyTerminalResponderUIView.resolveComposition(for:)`). Without a terminal responder
    /// there is nothing to settle.
    @discardableResult
    func resolveTerminalComposition(
        for action: GhosttyTerminalCompositionAction
    ) -> GhosttyTerminalCompositionOutcome {
        guard let responder = terminalResponder as? GhosttyTerminalResponderUIView else { return .noDraft }
        return responder.resolveComposition(for: action)
    }
}

/// What an app action, as a toolbar key, does to the terminal keyboard's unfinished composition.
enum GhosttyTerminalCompositionAction: Equatable {
    /// Commits the draft as typed. `preservingModifiers` leaves an armed Ctrl for the key that
    /// finishes the draft instead of applying it to the draft.
    case finish(preservingModifiers: Bool)
    case cancel
    /// A delete key, which leaves a draft as it is. The keyboard keeps its own copy of what it
    /// composes, so an edit it didn't make either undoes its buffer or is undone by it.
    case delete
}

enum GhosttyTerminalCompositionOutcome: Equatable {
    /// Nothing was composing. The keyboard's context, typed text and hidden state such as Korean's
    /// syllable assembly, ended, and the action goes on to the terminal.
    case noDraft
    case finished
    case canceled
    /// The draft stays as typed, and the action does nothing while it is open.
    case kept
    /// The draft couldn't be committed: its pane no longer takes the input, or the input was
    /// refused. The draft is gone, and the action stops.
    case refused
}

struct GhosttyTerminalResponderRepresentable: UIViewRepresentable {
    let isEnabled: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let responderHandoff: GhosttyKeyboardResponderHandoff
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let keyboardAppearance: UIKeyboardAppearance
    let inputSurface: () -> GhosttyManagedSurface?
    let sendText: (String) -> Bool
    let sendFinishedText: (String) -> Bool
    let sendPaste: (String) -> Bool
    let sendKeyEvent: (GhosttySurfaceKeyEvent) -> Bool
    let isModifierArmed: () -> Bool
    let onTrackpadFeedbackChange: (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void
    let onFirstResponderChange: (Bool) -> Void

    /// `inputSurface` is the surface the focused input operations reach now, nil while they would
    /// be refused; a composition is drawn on it and stays with it. `sendText` sends what the
    /// keyboard commits, with an armed modifier applied. `sendFinishedText` sends a draft an app
    /// action finishes while preserving the modifier for that action. `isModifierArmed` tells
    /// whether `sendText` would apply a modifier to the next text.
    init(
        isEnabled: Bool,
        wantsFirstResponder: Bool,
        activationToken: Int,
        responderHandoff: GhosttyKeyboardResponderHandoff,
        trackpadDriver: GhosttyKeyboardCursorTrackpadDriver,
        keyboardAppearance: UIKeyboardAppearance = .dark,
        inputSurface: @escaping () -> GhosttyManagedSurface? = { nil },
        sendText: @escaping (String) -> Bool,
        sendFinishedText: @escaping (String) -> Bool,
        sendPaste: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        isModifierArmed: @escaping () -> Bool = { false },
        onTrackpadFeedbackChange: @escaping (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void,
        onFirstResponderChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isEnabled = isEnabled
        self.wantsFirstResponder = wantsFirstResponder
        self.activationToken = activationToken
        self.responderHandoff = responderHandoff
        self.trackpadDriver = trackpadDriver
        self.keyboardAppearance = keyboardAppearance
        self.inputSurface = inputSurface
        self.sendText = sendText
        self.sendFinishedText = sendFinishedText
        self.sendPaste = sendPaste
        self.sendKeyEvent = sendKeyEvent
        self.isModifierArmed = isModifierArmed
        self.onTrackpadFeedbackChange = onTrackpadFeedbackChange
        self.onFirstResponderChange = onFirstResponderChange
    }

    func makeUIView(context: Context) -> GhosttyTerminalResponderUIView {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: trackpadDriver)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        responderHandoff.register(view, as: .terminal)
        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalResponderUIView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            wantsFirstResponder: wantsFirstResponder,
            activationToken: activationToken,
            keyboardAppearance: keyboardAppearance,
            inputSurface: inputSurface,
            sendText: { sendText(GhosttyTerminalInputNormalizer.normalize($0)) },
            sendFinishedText: { sendFinishedText(GhosttyTerminalInputNormalizer.normalize($0)) },
            sendPaste: sendPaste,
            sendKeyEvent: sendKeyEvent,
            isModifierArmed: isModifierArmed,
            onTrackpadFeedbackChange: onTrackpadFeedbackChange,
            onFirstResponderChange: onFirstResponderChange
        )
    }

    static func dismantleUIView(_ uiView: GhosttyTerminalResponderUIView, coordinator: ()) {
        // SwiftUI is dropping this representable while a trackpad gesture may
        // still be live (surface revision, screen transition, disconnect).
        uiView.cancelTrackpadGestureIfActive(reason: "dismantle")
        uiView.resolveComposition(for: .cancel)
    }
}

enum GhosttyTerminalInputNormalizer {
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\r")
    }
}

@MainActor
final class GhosttyTerminalResponderUIView: UIView, UIKeyInput, UITextInputTraits {
    override var canBecomeFirstResponder: Bool { isInputEnabled }

    var hasText: Bool { isInputEnabled }
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    /// A terminal takes literal input, so the keyboard offers no grey suggestion that a later
    /// commit could send unseen.
    var inlinePredictionType: UITextInlinePredictionType = .no
    var enablesReturnKeyAutomatically = false

    /// The keyboard's document: the placeholder, the text the keyboard typed since its context
    /// last ended, and any unfinished composition. Typed text is kept only while no modifier is
    /// armed: arming one is an app action, which ends the context, and text typed with one armed
    /// isn't kept.
    private(set) var composition = GhosttyTerminalCompositionDocument()
    /// The surface a composition belongs to, which draws it. It is bound when the composition
    /// starts, and the composition is committed only while focused input still reaches it.
    private weak var compositionSurface: GhosttyManagedSurface?
    private var compositionSurfaceID: UUID?
    /// The surface focused input reached at the last update; a change ends the composition.
    private var observedInputSurfaceID: UUID?
    /// A keyboard edit since the last synchronization may have left context the keyboard keeps
    /// to revise what it sent, as Korean's syllable assembly does.
    private var keyboardContextNeedsSync = false
    private var inputSurfaceProvider: () -> GhosttyManagedSurface? = { nil }

    private var isInputEnabled = false
    private var wantsFirstResponder = false
    private var activationToken = -1
    private var pendingFirstResponderRequest = false
    private var responderReconciliationScheduled = false
    private var sendTextHandler: ((String) -> Bool)?
    private var sendFinishedTextHandler: ((String) -> Bool)?
    private var sendPasteHandler: ((String) -> Bool)?
    private var sendKeyEventHandler: ((GhosttySurfaceKeyEvent) -> Bool)?
    private var modifierArmedProvider: () -> Bool = { false }
    private var trackpadFeedbackHandler: ((GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void)?
    private var firstResponderStateHandler: ((Bool) -> Void)?
    private var lastReportedFirstResponderState: Bool?
    private let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    lazy var floatingCursorTokenizer: UITextInputTokenizer =
        UITextInputStringTokenizer(textInput: self)
    weak var inputDelegate: UITextInputDelegate?

    init(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver) {
        self.trackpadDriver = trackpadDriver
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(
        isEnabled: Bool,
        wantsFirstResponder: Bool,
        activationToken: Int,
        keyboardAppearance: UIKeyboardAppearance = .dark,
        inputSurface: @escaping () -> GhosttyManagedSurface? = { nil },
        sendText: @escaping (String) -> Bool,
        sendFinishedText: ((String) -> Bool)? = nil,
        sendPaste: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        isModifierArmed: @escaping () -> Bool = { false },
        onTrackpadFeedbackChange: @escaping (GhosttyKeyboardCursorTrackpad.FeedbackState) -> Void = { _ in },
        onFirstResponderChange: @escaping (Bool) -> Void = { _ in }
    ) {
        let wasInputEnabled = self.isInputEnabled
        let previouslyWantedFirstResponder = self.wantsFirstResponder
        let previousActivationToken = self.activationToken
        let previousKeyboardAppearance = self.keyboardAppearance
        GhosttyRuntimeTrace.diagnostics(
            "responder.update enabled=\(isEnabled) wasEnabled=\(wasInputEnabled) wantsFirstResponder=\(wantsFirstResponder) previousWantsFirstResponder=\(previouslyWantedFirstResponder) token=\(activationToken) previousToken=\(previousActivationToken) firstResponder=\(isFirstResponder) hasWindow=\(window != nil)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.update",
            fields: [
                "enabled": "\(isEnabled)",
                "firstResponder": "\(isFirstResponder)",
                "hasWindow": "\(window != nil)",
                "token": "\(activationToken)",
                "wasEnabled": "\(wasInputEnabled)",
                "wantsFirstResponder": "\(wantsFirstResponder)",
                "previousWantsFirstResponder": "\(previouslyWantedFirstResponder)",
            ]
        )
        self.isInputEnabled = isEnabled
        self.wantsFirstResponder = wantsFirstResponder
        self.keyboardAppearance = keyboardAppearance
        self.inputSurfaceProvider = inputSurface
        self.sendTextHandler = sendText
        self.sendFinishedTextHandler = sendFinishedText ?? sendText
        self.sendPasteHandler = sendPaste
        self.sendKeyEventHandler = sendKeyEvent
        self.modifierArmedProvider = isModifierArmed
        self.trackpadFeedbackHandler = onTrackpadFeedbackChange
        self.firstResponderStateHandler = onFirstResponderChange

        if isFirstResponder, previousKeyboardAppearance != keyboardAppearance {
            reloadInputViews()
        }

        // A composition and the keyboard's context belong to where input went: another pane, a
        // popup, a new connection or input becoming unavailable ends them.
        let inputSurfaceID = isEnabled ? inputSurface()?.id : nil
        if inputSurfaceID != observedInputSurfaceID || (!isEnabled && !composition.isIdle) {
            GhosttyRuntimeTrace.diagnostics(
                "responder.inputSurface \(ghosttyDiagnosticShortID(observedInputSurfaceID)) -> \(ghosttyDiagnosticShortID(inputSurfaceID))"
            )
            observedInputSurfaceID = inputSurfaceID
            resolveComposition(for: .cancel)
        }

        if !isEnabled {
            cancelTrackpadGestureIfActive(reason: "disabled")
            pendingFirstResponderRequest = false
            self.activationToken = activationToken
            scheduleResponderReconciliationIfNeeded(reason: "disabled")
            return
        }

        guard wantsFirstResponder else {
            pendingFirstResponderRequest = false
            self.activationToken = activationToken
            scheduleResponderReconciliationIfNeeded(reason: "not-wanted")
            return
        }

        let activationChanged = activationToken != self.activationToken
        let enabledChanged = !wasInputEnabled
        let wantsFirstResponderChanged = wantsFirstResponder != previouslyWantedFirstResponder
        let needsFirstResponderRecovery = !isFirstResponder && !pendingFirstResponderRequest
        guard activationChanged || enabledChanged || wantsFirstResponderChanged || needsFirstResponderRecovery else { return }

        self.activationToken = activationToken
        pendingFirstResponderRequest = true
        scheduleResponderReconciliationIfNeeded(reason: "request")
    }

    /// Committed keyboard text: an input method's commit replaces its composition; anything else
    /// is typed, and stays in the document so the keyboard can revise it, as dictation and
    /// Korean's syllables do.
    func insertText(_ text: String) {
        guard isInputEnabled else { return }
        keyboardContextNeedsSync = true
        guard composition.marked == nil else {
            commitComposition(text, source: "insertText", through: sendTextHandler)
            return
        }
        // A Return ends the line, and an armed modifier turns text into a key: either way there is
        // nothing for the keyboard to revise.
        guard !text.contains(where: \.isNewline), !modifierArmedProvider(),
              let edit = composition.type(text)
        else {
            submitTextInput(text, source: "insertText")
            endKeyboardContext()
            return
        }
        submitTypedEdit(edit, source: "insertText")
    }

    /// Sends an edit of typed text: Backspaces back to where it changes, then the new text. If any
    /// of it isn't delivered, what the terminal holds is unknown, so the keyboard's context ends; it
    /// also ends once the typed text outgrows the document's capacity.
    private func submitTypedEdit(_ edit: GhosttyTerminalCompositionDocument.TypedEdit, source: String) {
        var delivered = true
        for _ in 0..<edit.backspaces where delivered {
            delivered = sendKeyEventHandler?(.init(keyCode: .backspace)) ?? false
        }
        if delivered, !edit.text.isEmpty {
            delivered = submitTextInput(edit.text, source: source)
        }
        if !delivered || composition.typedLength > GhosttyTerminalCompositionDocument.typedCapacity {
            endKeyboardContext()
        }
    }

    /// Ends the keyboard's context, typed text included, and tells the keyboard.
    private func endKeyboardContext() {
        guard !composition.isIdle || keyboardContextNeedsSync else { return }
        synchronizeKeyboardContext { composition.clear() }
    }

    @discardableResult
    func submitTextInput(_ text: String, source: String) -> Bool {
        submitTextInput(text, source: source, through: sendTextHandler)
    }

    @discardableResult
    private func submitTextInput(
        _ text: String,
        source: String,
        through send: ((String) -> Bool)?
    ) -> Bool {
        guard isInputEnabled else { return false }
        guard !text.isEmpty else { return false }
        GhosttyRuntimeTrace.diagnostics(
            "responder.\(source) bytes=\(text.lengthOfBytes(using: .utf8)) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.\(source)",
            fields: [
                "bytes": "\(text.lengthOfBytes(using: .utf8))",
                "firstResponder": "\(isFirstResponder)",
                "token": "\(activationToken)",
            ],
        )
        return send?(text) ?? false
    }

    // MARK: Composition

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard isInputEnabled else { return }
        keyboardContextNeedsSync = true
        let startsComposition = composition.marked == nil
        composition.setMarkedText(markedText, selectedRange: selectedRange)
        if startsComposition, composition.marked != nil {
            let surface = inputSurfaceProvider()
            compositionSurface = surface
            compositionSurfaceID = surface?.id
        }
        GhosttyRuntimeTrace.diagnostics(
            "responder.setMarkedText marked=\(composition.marked.map(NSStringFromRange) ?? "nil") selection=\(NSStringFromRange(composition.selection)) surface=\(ghosttyDiagnosticShortID(compositionSurfaceID))"
        )
        presentComposition()
    }

    func unmarkText() {
        guard let text = composition.markedText else { return }
        keyboardContextNeedsSync = true
        commitComposition(text, source: "unmarkText", through: sendTextHandler)
    }

    func replaceComposition(_ range: NSRange, with text: String) {
        guard isInputEnabled else { return }
        keyboardContextNeedsSync = true
        switch composition.replace(range, with: text) {
        case .composition:
            presentComposition()
        case .typed(let edit):
            submitTypedEdit(edit, source: "replaceText")
        case .committed(let committed):
            presentComposition()
            submitTextInput(committed, source: "replaceText")
        case .none:
            break
        }
    }

    func selectComposition(_ range: NSRange) {
        composition.select(range)
    }

    /// Settles the composition for an app action: commits or cancels a draft, or leaves it alone
    /// for a delete key. A commit or cancel brackets its local change with the input delegate's
    /// notifications, which also end context the keyboard keeps between its own edits. With no
    /// draft, the action changes the terminal's line in a way the keyboard didn't type, so the
    /// keyboard's context, typed text included, ends. Keyboard edits never come through here: they
    /// change the document as the keyboard asks.
    @discardableResult
    func resolveComposition(
        for action: GhosttyTerminalCompositionAction
    ) -> GhosttyTerminalCompositionOutcome {
        let outcome = settleComposition(for: action)
        GhosttyRuntimeTrace.diagnostics("responder.composition action=\(action) outcome=\(outcome)")
        return outcome
    }

    private func settleComposition(
        for action: GhosttyTerminalCompositionAction
    ) -> GhosttyTerminalCompositionOutcome {
        guard composition.marked != nil else {
            endKeyboardContext()
            return .noDraft
        }
        switch action {
        case .finish(let preservingModifiers):
            var draft: (text: String, surfaceID: UUID?)?
            synchronizeKeyboardContext { draft = takeComposition() }
            guard let draft else { return .noDraft }
            let committed = send(
                draft,
                source: "finish",
                through: preservingModifiers ? sendFinishedTextHandler : sendTextHandler
            )
            return committed ? .finished : .refused
        case .cancel:
            synchronizeKeyboardContext { endComposition() }
            return .canceled
        case .delete:
            return .kept
        }
    }

    /// A keyboard commit: `text` replaces the draft.
    @discardableResult
    private func commitComposition(
        _ text: String,
        source: String,
        through sendText: ((String) -> Bool)?
    ) -> Bool {
        guard let draft = takeComposition() else { return false }
        return send((text, draft.surfaceID), source: source, through: sendText)
    }

    /// The one take-and-clear of a draft, whether the keyboard commits it or an app action
    /// finishes it: the draft is gone before anything is sent.
    private func takeComposition() -> (text: String, surfaceID: UUID?)? {
        guard let text = composition.markedText else { return nil }
        let surfaceID = compositionSurfaceID
        endComposition()
        return (text, surfaceID)
    }

    /// Sends a taken draft only while focused input still reaches the surface it was typed on.
    private func send(
        _ draft: (text: String, surfaceID: UUID?),
        source: String,
        through sendText: ((String) -> Bool)?
    ) -> Bool {
        guard inputSurfaceProvider()?.id == draft.surfaceID else {
            GhosttyRuntimeTrace.diagnostics("responder.\(source) dropped composition for another destination")
            return false
        }
        return submitTextInput(draft.text, source: source, through: sendText)
    }

    private func endComposition() {
        composition.clear()
        presentComposition()
    }

    /// Draws the composition on its surface, and clears it there once it ends.
    private func presentComposition() {
        guard let text = composition.markedText else {
            compositionSurface?.setPreedit(nil)
            compositionSurface = nil
            compositionSurfaceID = nil
            return
        }
        compositionSurface?.setPreedit(text)
    }

    private func synchronizeKeyboardContext(_ change: () -> Void) {
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        change()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
        keyboardContextNeedsSync = false
    }

    /// The composition's surface cursor cell, in this view's coordinates.
    func compositionCaretRect() -> CGRect? {
        guard let surface = compositionSurface ?? inputSurfaceProvider() else { return nil }
        let view = surface.view
        let cell = surface.controlSurface.cursorGeometry()
            ?? CGRect(x: 0, y: max(0, view.bounds.maxY - 1), width: 1, height: 1)
        return view.convert(cell, to: self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        GhosttyRuntimeTrace.diagnostics(
            "responder.didMoveToWindow hasWindow=\(window != nil) enabled=\(isInputEnabled) pending=\(pendingFirstResponderRequest) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        if window == nil {
            // Detached from the view hierarchy mid-flight: end any active
            // trackpad gesture so the SwiftUI HUD observer doesn't strand
            // visible after the surface this responder belonged to is gone.
            cancelTrackpadGestureIfActive(reason: "didMoveToWindow.nil")
        }
        scheduleResponderReconciliationIfNeeded(reason: "didMoveToWindow")
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        reportFirstResponderStateIfChanged()
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.result",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "result": "\(didBecomeFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        cancelTrackpadGestureIfActive(reason: "resignFirstResponder")
        let didResignFirstResponder = super.resignFirstResponder()
        // UIKit settles a composition as the keyboard leaves; a draft it leaves behind has no
        // keyboard to finish it, so it isn't left drawn. The line may change before the keyboard
        // returns, so typed text ends with it.
        if didResignFirstResponder, !composition.isIdle {
            GhosttyRuntimeTrace.diagnostics("responder.resign cancels unfinished composition")
            resolveComposition(for: .cancel)
        }
        reportFirstResponderStateIfChanged()
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.resignFirstResponder.result",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "result": "\(didResignFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
        return didResignFirstResponder
    }

    private func reportFirstResponderStateIfChanged() {
        let currentState = isFirstResponder
        guard currentState != lastReportedFirstResponderState else { return }
        lastReportedFirstResponderState = currentState
        firstResponderStateHandler?(currentState)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // UITextInput conformance makes UIKit offer the standard edit menu
        // (Select, Select All, Copy, Cut). The terminal has no editable selection,
        // so those are suppressed; paste stays available.
        switch action {
        case #selector(UIResponderStandardEditActions.select(_:)),
             #selector(UIResponderStandardEditActions.selectAll(_:)),
             #selector(UIResponderStandardEditActions.copy(_:)),
             #selector(UIResponderStandardEditActions.cut(_:)):
            return false
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    func beginFloatingCursor(at point: CGPoint) {
        guard isInputEnabled else { return }
        // The trackpad steers the terminal's cursor, so a draft is finished first.
        guard resolveComposition(for: .finish(preservingModifiers: true)) != .refused else { return }
        trackpadDriver.begin(
            owner: self,
            at: point,
            sendKeyEvent: { [weak self] event in
                self?.sendKeyEventHandler?(event) == true
            },
            onFeedbackChange: { [weak self] state in
                self?.trackpadFeedbackHandler?(state)
            }
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.trackpad.begin",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
    }

    func updateFloatingCursor(at point: CGPoint) {
        guard isInputEnabled else { return }
        _ = trackpadDriver.update(owner: self, at: point)
    }

    func endFloatingCursor() {
        guard trackpadDriver.end(owner: self) != nil else { return }
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.trackpad.end",
            fields: [
                "firstResponder": "\(isFirstResponder)",
                "token": "\(activationToken)",
            ]
        )
    }

    func cancelTrackpadGestureIfActive(reason: String) {
        guard trackpadDriver.cancel(owner: self) else { return }
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.trackpad.cancel",
            fields: [
                "reason": reason,
                "token": "\(activationToken)",
            ]
        )
    }

    /// The keyboard's delete: within a composition it edits the draft; otherwise it deletes typed
    /// text, or the selection the keyboard made in it, and once no typed text is left the terminal
    /// deletes what came before, as Korean's syllable revisions need.
    func deleteBackward() {
        guard isInputEnabled else { return }
        keyboardContextNeedsSync = true
        GhosttyRuntimeTrace.diagnostics(
            "responder.deleteBackward firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        switch composition.deleteBackward() {
        case .terminal:
            _ = sendKeyEventHandler?(.init(keyCode: .backspace))
            // With typed text still after the caret, the terminal deleted text the document holds,
            // so the keyboard's context ends.
            if !composition.isIdle { endKeyboardContext() }
        case .typed(let edit):
            submitTypedEdit(edit, source: "deleteBackward")
        case .composition:
            presentComposition()
        case .none:
            break
        }
    }

    /// A paste replaces an unfinished draft, as UIKit's own paste does, and goes once.
    override func paste(_ sender: Any?) {
        guard
            isInputEnabled,
            let text = UIPasteboard.general.string,
            !text.isEmpty
        else {
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.paste bytes=\(text.lengthOfBytes(using: .utf8)) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        resolveComposition(for: .cancel)
        _ = sendPasteHandler?(text)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isInputEnabled else {
            GhosttyRuntimeTrace.diagnostics(
                "responder.pressesBegan disabled count=\(presses.count) firstResponder=\(isFirstResponder) token=\(activationToken)"
            )
            super.pressesBegan(presses, with: event)
            return
        }

        GhosttyRuntimeTrace.diagnostics(
            "responder.pressesBegan count=\(presses.count) firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        // While an input method composes, its keys edit, convert and confirm the draft.
        guard composition.marked == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandledPresses = Set<UIPress>()
        for press in presses.sorted(by: Self.sortPressesByTimestamp) {
            guard let key = press.key else {
                unhandledPresses.insert(press)
                continue
            }

            guard let action = GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: key.keyCode,
                modifiers: key.modifierFlags,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers
            ) else {
                unhandledPresses.insert(press)
                continue
            }

            if case .text(let text) = action,
               GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                   characters: key.characters,
                   modifiers: key.modifierFlags
               ) == text {
                GhosttyRuntimeTrace.diagnostics(
                    "responder.pressesBegan text keyCode=\(key.keyCode.rawValue) modifiers=\(key.modifierFlags.rawValue) bytes=\(text.lengthOfBytes(using: .utf8))"
                )
            } else {
                GhosttyRuntimeTrace.diagnostics(
                    "responder.pressesBegan action keyCode=\(key.keyCode.rawValue) modifiers=\(key.modifierFlags.rawValue)"
                )
                // A terminal command, unlike typed text, ends the keyboard's context.
                resolveComposition(for: .finish(preservingModifiers: true))
            }
            handleHardwareCommandAction(action)
        }

        if !unhandledPresses.isEmpty {
            GhosttyRuntimeTrace.diagnostics(
                "responder.pressesBegan unhandled count=\(unhandledPresses.count)"
            )
            super.pressesBegan(unhandledPresses, with: event)
        }
    }

    private func handleHardwareCommandAction(_ action: GhosttyTerminalHardwareCommandAction) {
        switch action {
        case .keyEvent(let event):
            _ = sendKeyEventHandler?(event)
        case .text(let text):
            // Hardware text reaches the line without the software keyboard, so its context ends.
            endKeyboardContext()
            _ = sendTextHandler?(text)
        }
    }

    private func scheduleResponderReconciliationIfNeeded(reason: String) {
        guard needsResponderReconciliation else { return }
        guard !responderReconciliationScheduled else { return }

        responderReconciliationScheduled = true
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.reconcile.scheduled",
            fields: [
                "reason": reason,
                "token": "\(activationToken)",
            ]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileResponderState()
        }
    }

    private var needsResponderReconciliation: Bool {
        if isFirstResponder {
            return !isInputEnabled || !wantsFirstResponder || pendingFirstResponderRequest
        }

        return isInputEnabled && wantsFirstResponder && pendingFirstResponderRequest
    }

    private func reconcileResponderState() {
        responderReconciliationScheduled = false

        guard isInputEnabled else {
            pendingFirstResponderRequest = false
            guard isFirstResponder else { return }
            GhosttyRuntimeTrace.diagnostics("responder.reconcile resign disabled token=\(activationToken)")
            _ = resignFirstResponder()
            return
        }

        guard wantsFirstResponder else {
            pendingFirstResponderRequest = false
            guard isFirstResponder else { return }
            GhosttyRuntimeTrace.diagnostics("responder.reconcile resign not-wanted token=\(activationToken)")
            _ = resignFirstResponder()
            return
        }

        guard pendingFirstResponderRequest else { return }
        guard window != nil else {
            GhosttyRuntimeTrace.perf("responder.requestFirstResponder skip-no-window token=\(activationToken)")
            return
        }

        GhosttyRuntimeTrace.perf(
            "responder.requestFirstResponder deferred token=\(activationToken) firstResponder=\(isFirstResponder)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.scheduled",
            fields: [
                "route": "reconcile",
                "token": "\(activationToken)",
            ]
        )
        _ = attemptFirstResponderRequest(route: "reconcile")
    }

    @discardableResult
    private func attemptFirstResponderRequest(route: String) -> Bool {
        if isFirstResponder {
            reloadInputViews()
            pendingFirstResponderRequest = false
            GhosttyRuntimeTrace.perf(
                "responder.requestFirstResponder result=true route=\(route) token=\(activationToken) firstResponder=true"
            )
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "responder.becomeFirstResponder.already",
                fields: [
                    "route": route,
                    "token": "\(activationToken)",
                ]
            )
            return true
        }

        let traceStart = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.begin",
            fields: [
                "route": route,
                "token": "\(activationToken)",
            ],
            at: traceStart
        )
        let didBecomeFirstResponder = becomeFirstResponder()
        let elapsedMilliseconds = GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStart)
        GhosttyRuntimeTrace.perf(
            "responder.requestFirstResponder result=\(didBecomeFirstResponder) route=\(route) token=\(activationToken) firstResponder=\(isFirstResponder) elapsed_ms=\(elapsedMilliseconds)"
        )
        GhosttyRuntimeTrace.diagnostics(
            "responder.requestFirstResponder result=\(didBecomeFirstResponder) route=\(route) token=\(activationToken) firstResponder=\(isFirstResponder)"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "responder.becomeFirstResponder.end",
            fields: [
                "elapsed_ms": elapsedMilliseconds,
                "result": "\(didBecomeFirstResponder)",
                "route": route,
                "token": "\(activationToken)",
            ]
        )
        if didBecomeFirstResponder {
            pendingFirstResponderRequest = false
        }
        return didBecomeFirstResponder
    }

    private static func sortPressesByTimestamp(_ lhs: UIPress, _ rhs: UIPress) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }

        return (lhs.key?.keyCode.rawValue ?? 0) < (rhs.key?.keyCode.rawValue ?? 0)
    }
}

enum GhosttyTerminalHardwareCommandAction: Equatable {
    case keyEvent(GhosttySurfaceKeyEvent)
    case text(String)
}

enum GhosttyTerminalHardwareCommandMapping {
    private static let hardwareKeyCodes: [UIKeyboardHIDUsage: GhosttySurfaceKeyEvent.KeyCode] = [
        .keyboardDeleteOrBackspace: .backspace,
        .keyboardDeleteForward: .delete,
        .keyboardReturnOrEnter: .enter,
        .keyboardTab: .tab,
        .keyboardEscape: .escape,
        .keyboardUpArrow: .arrowUp,
        .keyboardDownArrow: .arrowDown,
        .keyboardLeftArrow: .arrowLeft,
        .keyboardRightArrow: .arrowRight,
        .keyboardHome: .home,
        .keyboardEnd: .end,
        .keyboardPageUp: .pageUp,
        .keyboardPageDown: .pageDown,
        .keyboardInsert: .insert,
        .keyboardF1: .f1,
        .keyboardF2: .f2,
        .keyboardF3: .f3,
        .keyboardF4: .f4,
        .keyboardF5: .f5,
        .keyboardF6: .f6,
        .keyboardF7: .f7,
        .keyboardF8: .f8,
        .keyboardF9: .f9,
        .keyboardF10: .f10,
        .keyboardF11: .f11,
        .keyboardF12: .f12,
    ]

    static func resolveHardwareKey(
        keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        charactersIgnoringModifiers: String? = nil
    ) -> GhosttyTerminalHardwareCommandAction? {
        if let mappedKeyCode = hardwareKeyCodes[keyCode] {
            return .keyEvent(
                .init(
                    keyCode: mappedKeyCode,
                    mods: ghosttyModifiers(from: modifiers)
                )
            )
        }

        guard supportsControlTextTranslation(modifiers: modifiers) else { return nil }
        guard let charactersIgnoringModifiers else { return nil }
        guard let translated = GhosttyModifierState.controlText(for: charactersIgnoringModifiers) else {
            return nil
        }

        return .text(translated)
    }

    static func resolveHardwarePress(
        keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String?
    ) -> GhosttyTerminalHardwareCommandAction? {
        if let action = resolveHardwareKey(
            keyCode: keyCode,
            modifiers: modifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        ) {
            return action
        }

        guard let text = resolveHardwareText(characters: characters, modifiers: modifiers) else {
            return nil
        }
        return .text(text)
    }

    static func resolveHardwareText(
        characters: String,
        modifiers: UIKeyModifierFlags
    ) -> String? {
        guard !characters.isEmpty else { return nil }
        guard !modifiers.contains(.command) else { return nil }
        guard !modifiers.contains(.control) else { return nil }
        return characters
    }

    private static func supportsControlTextTranslation(modifiers: UIKeyModifierFlags) -> Bool {
        guard modifiers.contains(.control) else { return false }
        return !modifiers.contains(.command) && !modifiers.contains(.alternate)
    }

    private static func ghosttyModifiers(from modifiers: UIKeyModifierFlags) -> GhosttySurfaceKeyEvent.Mods {
        var result: GhosttySurfaceKeyEvent.Mods = []

        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.ctrl) }
        if modifiers.contains(.alternate) { result.insert(.alt) }
        if modifiers.contains(.command) { result.insert(.super) }
        if modifiers.contains(.alphaShift) { result.insert(.caps) }

        return result
    }
}
