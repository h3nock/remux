import SwiftUI
import UIKit

struct GhosttyTerminalResponderRepresentable: UIViewRepresentable {
    let isEnabled: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    let keyboardAppearance: UIKeyboardAppearance
    let sendText: (String) -> Bool
    let sendPaste: (String) -> Bool
    let sendKeyEvent: (GhosttySurfaceKeyEvent) -> Bool
    let onTrackpadStateChange: (GhosttyKeyboardCursorTrackpad.HUDState) -> Void
    let onFirstResponderChange: (Bool) -> Void

    init(
        isEnabled: Bool,
        wantsFirstResponder: Bool,
        activationToken: Int,
        trackpadDriver: GhosttyKeyboardCursorTrackpadDriver,
        keyboardAppearance: UIKeyboardAppearance = .dark,
        sendText: @escaping (String) -> Bool,
        sendPaste: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        onTrackpadStateChange: @escaping (GhosttyKeyboardCursorTrackpad.HUDState) -> Void,
        onFirstResponderChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isEnabled = isEnabled
        self.wantsFirstResponder = wantsFirstResponder
        self.activationToken = activationToken
        self.trackpadDriver = trackpadDriver
        self.keyboardAppearance = keyboardAppearance
        self.sendText = sendText
        self.sendPaste = sendPaste
        self.sendKeyEvent = sendKeyEvent
        self.onTrackpadStateChange = onTrackpadStateChange
        self.onFirstResponderChange = onFirstResponderChange
    }

    func makeUIView(context: Context) -> GhosttyTerminalResponderUIView {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: trackpadDriver)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: GhosttyTerminalResponderUIView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            wantsFirstResponder: wantsFirstResponder,
            activationToken: activationToken,
            keyboardAppearance: keyboardAppearance,
            sendText: { sendText(GhosttyTerminalInputNormalizer.normalize($0)) },
            sendPaste: sendPaste,
            sendKeyEvent: sendKeyEvent,
            onTrackpadStateChange: onTrackpadStateChange,
            onFirstResponderChange: onFirstResponderChange
        )
    }

    static func dismantleUIView(_ uiView: GhosttyTerminalResponderUIView, coordinator: ()) {
        // SwiftUI is dropping this representable while a trackpad gesture may
        // still be live (surface revision, screen transition, disconnect).
        // Make sure the floating-cursor HUD state observer downstream goes
        // hidden so it doesn't strand on a parent view.
        uiView.cancelTrackpadGestureIfActive(reason: "dismantle")
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
    var enablesReturnKeyAutomatically = false

    private var isInputEnabled = false
    private var wantsFirstResponder = false
    private var activationToken = -1
    private var pendingFirstResponderRequest = false
    private var responderReconciliationScheduled = false
    private var sendTextHandler: ((String) -> Bool)?
    private var sendPasteHandler: ((String) -> Bool)?
    private var sendKeyEventHandler: ((GhosttySurfaceKeyEvent) -> Bool)?
    private var firstResponderStateHandler: ((Bool) -> Void)?
    private var lastReportedFirstResponderState: Bool?
    var trackpadStateHandler: ((GhosttyKeyboardCursorTrackpad.HUDState) -> Void)?
    private let trackpadDriver: GhosttyKeyboardCursorTrackpadDriver
    lazy var floatingCursorTokenizer: UITextInputTokenizer =
        UITextInputStringTokenizer(textInput: self)
    weak var inputDelegate: UITextInputDelegate?

    var storedMarkedText: String?
    var storedMarkedSelectedRange: NSRange = NSRange(location: NSNotFound, length: 0)

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
        sendText: @escaping (String) -> Bool,
        sendPaste: @escaping (String) -> Bool,
        sendKeyEvent: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        onTrackpadStateChange: @escaping (GhosttyKeyboardCursorTrackpad.HUDState) -> Void,
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
        self.sendTextHandler = sendText
        self.sendPasteHandler = sendPaste
        self.sendKeyEventHandler = sendKeyEvent
        self.trackpadStateHandler = onTrackpadStateChange
        self.firstResponderStateHandler = onFirstResponderChange

        if isFirstResponder, previousKeyboardAppearance != keyboardAppearance {
            reloadInputViews()
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

    func insertText(_ text: String) {
        if storedMarkedText != nil {
            inputDelegate?.textWillChange(self)
            storedMarkedText = nil
            storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
            inputDelegate?.textDidChange(self)
        }
        submitTextInput(text, source: "insertText")
    }

    func submitTextInput(_ text: String, source: String) {
        guard isInputEnabled else { return }
        guard !text.isEmpty else { return }
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
        _ = sendTextHandler?(text)
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
        // Now that this view conforms to UITextInput, UIKit otherwise advertises
        // the standard text edit menu (Select / Select All / Copy / Cut). The
        // terminal has no editable selection, so suppress those and keep paste
        // wired through the existing handler.
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
        trackpadDriver.begin(
            owner: self,
            at: point,
            sendKeyEvent: { [weak self] event in
                self?.sendKeyEventHandler?(event) == true
            },
            onHUDStateChange: { [weak self] state in
                self?.trackpadStateHandler?(state)
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
        let traceStart = GhosttyRuntimeTrace.nowNanos()
        guard let outcome = trackpadDriver.update(owner: self, at: point) else { return }

        if !outcome.steps.isEmpty || outcome.didLockAxis {
            GhosttyRuntimeTrace.perf(
                "input.trackpad.steps count=\(outcome.steps.count) intensity=\(String(format: "%.2f", Double(outcome.hud.intensity))) lockedAxis=\(outcome.didLockAxis) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStart))"
            )
        }
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

    func deleteBackward() {
        guard isInputEnabled else { return }
        if storedMarkedText != nil {
            inputDelegate?.textWillChange(self)
            storedMarkedText = nil
            storedMarkedSelectedRange = NSRange(location: NSNotFound, length: 0)
            inputDelegate?.textDidChange(self)
            return
        }
        GhosttyRuntimeTrace.diagnostics(
            "responder.deleteBackward firstResponder=\(isFirstResponder) token=\(activationToken)"
        )
        _ = sendKeyEventHandler?(.init(keyCode: .backspace))
    }

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
