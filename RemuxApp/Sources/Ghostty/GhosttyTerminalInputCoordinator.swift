import Foundation

enum GhosttyKeyboardOwner: Equatable {
    case none
    case terminal
    case composer
}

struct GhosttyTerminalInputCoordinator: Equatable {
    private(set) var terminalActivationToken = 0
    private(set) var composerActivationToken = 0
    private(set) var keyboardMode: GhosttyKeyboardChromeMode = .hidden
    private(set) var keyboardOwner: GhosttyKeyboardOwner = .none
    private(set) var isDismissSystemKeyboardRequested = false
    private(set) var isSoftwareKeyboardVisible = false

    mutating func showSystemKeyboard(isInputAvailable: Bool) {
        showSystemKeyboard(owner: .terminal, isOwnerAvailable: isInputAvailable)
    }

    mutating func showSystemKeyboard(
        owner: GhosttyKeyboardOwner,
        isOwnerAvailable: Bool
    ) {
        guard owner != .none, isOwnerAvailable else { return }
        isDismissSystemKeyboardRequested = false
        keyboardMode = .system
        keyboardOwner = owner
        switch owner {
        case .terminal:
            terminalActivationToken += 1
        case .composer:
            composerActivationToken += 1
        case .none:
            break
        }
    }

    mutating func toggleKeyboard(isInputAvailable: Bool) {
        toggleKeyboard(owner: .terminal, isOwnerAvailable: isInputAvailable)
    }

    mutating func toggleKeyboard(
        owner: GhosttyKeyboardOwner,
        isOwnerAvailable: Bool
    ) {
        if keyboardMode == .system, keyboardOwner == owner {
            hideKeyboard()
            return
        }

        showSystemKeyboard(owner: owner, isOwnerAvailable: isOwnerAvailable)
    }

    mutating func transferKeyboardOwnerIfActive(
        to owner: GhosttyKeyboardOwner,
        isOwnerAvailable: Bool
    ) {
        guard keyboardMode == .system else { return }
        showSystemKeyboard(owner: owner, isOwnerAvailable: isOwnerAvailable)
    }

    mutating func dismissKeyboard() {
        hideKeyboard()
    }

    mutating func refocusSystemKeyboardIfActive(isInputAvailable: Bool) {
        guard keyboardMode == .system, keyboardOwner == .terminal else { return }
        showSystemKeyboard(isInputAvailable: isInputAvailable)
    }

    mutating func handleSelectionChange(isInputAvailable: Bool) {
        switch (keyboardMode, keyboardOwner) {
        case (.system, .terminal):
            showSystemKeyboard(isInputAvailable: isInputAvailable)
        case (.hidden, _):
            isDismissSystemKeyboardRequested = false
        case (.system, .composer), (.system, .none):
            break
        }
    }

    mutating func updateSoftwareKeyboardVisibility(_ isVisible: Bool) {
        isSoftwareKeyboardVisible = isVisible

        if isVisible {
            // Presentation can finish after the user has already asked to
            // dismiss the keyboard. Keep that explicit dismissal authoritative
            // until UIKit confirms the keyboard is hidden.
            guard !isDismissSystemKeyboardRequested else { return }
            isDismissSystemKeyboardRequested = false
            keyboardMode = keyboardMode.applyingSystemKeyboardVisibility(true)
            if keyboardOwner == .none {
                keyboardOwner = .terminal
            }
            return
        }

        if isDismissSystemKeyboardRequested {
            keyboardMode = keyboardMode.applyingSystemKeyboardVisibility(false)
            keyboardOwner = .none
        }
        isDismissSystemKeyboardRequested = false
    }

    private mutating func hideKeyboard() {
        if keyboardMode == .system {
            isDismissSystemKeyboardRequested = true
        } else {
            isDismissSystemKeyboardRequested = false
        }
        keyboardMode = .hidden
        keyboardOwner = .none
    }
}

struct GhosttyTerminalInputController: Equatable {
    enum TextAction: Equatable {
        case submit(String)
        case schedulePrefixFlush(token: UInt64)
        case enterCopyMode(fallbackInput: String)
    }

    struct PasteAction: Equatable {
        var pendingPrefixInput: String?
        var text: String
    }

    struct KeyEventAction: Equatable {
        var pendingPrefixInput: String?
        var event: GhosttySurfaceKeyEvent
    }

    private var modifierState = GhosttyModifierState()
    private var tmuxPrefixInputBuffer = GhosttyTmuxPrefixInputBuffer()

    var isControlArmed: Bool {
        modifierState.isControlArmed
    }

    var isShiftArmed: Bool {
        modifierState.isShiftArmed
    }

    mutating func toggleControl() {
        modifierState.toggleControl()
    }

    mutating func toggleShift() {
        modifierState.toggleShift()
    }

    mutating func clearModifiers() {
        modifierState.clearModifiers()
    }

    mutating func receiveText(_ text: String) -> TextAction {
        let outbound = modifierState.apply(to: text)
        switch tmuxPrefixInputBuffer.handleText(outbound) {
        case .submit(let input):
            return .submit(input)
        case .armPrefix(let token):
            return .schedulePrefixFlush(token: token)
        case .enterCopyMode(let fallbackInput):
            return .enterCopyMode(fallbackInput: fallbackInput)
        }
    }

    mutating func performTextInput(
        _ text: String,
        submit: (String) -> Bool,
        schedulePrefixFlush: (UInt64) -> Void,
        enterCopyMode: () -> Bool
    ) -> Bool {
        switch receiveText(text) {
        case .submit(let input):
            return submit(input)
        case .schedulePrefixFlush(let token):
            schedulePrefixFlush(token)
            return true
        case .enterCopyMode(let fallbackInput):
            guard enterCopyMode() else {
                return submit(fallbackInput)
            }
            return true
        }
    }

    mutating func receivePaste(_ text: String) -> PasteAction {
        PasteAction(
            pendingPrefixInput: tmuxPrefixInputBuffer.flushPendingInput(),
            text: text
        )
    }

    mutating func performPaste(
        _ text: String,
        submitPendingPrefix: (String) -> Bool,
        sendPaste: (String) -> Bool
    ) -> Bool {
        let action = receivePaste(text)
        if let pendingPrefixInput = action.pendingPrefixInput {
            _ = submitPendingPrefix(pendingPrefixInput)
        }
        return sendPaste(action.text)
    }

    mutating func receiveKeyEvent(_ event: GhosttySurfaceKeyEvent) -> KeyEventAction {
        KeyEventAction(
            pendingPrefixInput: tmuxPrefixInputBuffer.flushPendingInput(),
            event: modifierState.apply(to: event)
        )
    }

    mutating func performKeyEvent(
        _ event: GhosttySurfaceKeyEvent,
        submitPendingPrefix: (String) -> Bool,
        sendKey: (GhosttySurfaceKeyEvent) -> Bool
    ) -> Bool {
        let action = receiveKeyEvent(event)
        if let pendingPrefixInput = action.pendingPrefixInput {
            _ = submitPendingPrefix(pendingPrefixInput)
        }
        return sendKey(action.event)
    }

    mutating func flushPendingTmuxPrefixInput() -> String? {
        tmuxPrefixInputBuffer.flushPendingInput()
    }

    mutating func flushPendingTmuxPrefixInput(matching token: UInt64) -> String? {
        tmuxPrefixInputBuffer.flushPendingInput(matching: token)
    }
}

struct GhosttyPendingTopologyInputRefocus: Equatable {
    private var isPending = false
    private var sourceActiveLeafID: UUID?
    private(set) var ownsKeyboardTransition = false

    var isActive: Bool {
        isPending
    }

    @discardableResult
    mutating func request(
        from activeLeafID: UUID?,
        keyboardMode: GhosttyKeyboardChromeMode,
        keyboardOwner: GhosttyKeyboardOwner = .terminal
    ) -> Bool {
        guard keyboardMode == .system, keyboardOwner == .terminal else { return false }
        isPending = true
        sourceActiveLeafID = activeLeafID
        ownsKeyboardTransition = false
        return true
    }

    mutating func markKeyboardTransitionOwned() {
        guard isActive else { return }
        ownsKeyboardTransition = true
    }

    mutating func consumeIfActiveLeafChanged(to activeLeafID: UUID?) -> Bool {
        guard isPending else { return false }
        guard activeLeafID != sourceActiveLeafID else { return false }

        isPending = false
        self.sourceActiveLeafID = nil
        ownsKeyboardTransition = false
        return true
    }

    mutating func cancel() {
        isPending = false
        sourceActiveLeafID = nil
        ownsKeyboardTransition = false
    }
}

struct GhosttyTopologyActionInputRefocusCoordinator: Equatable {
    enum Effect: Equatable {
        case requestRefocus
        case dismissSelectionSheet
        case cancelRefocus(ownsKeyboardTransition: Bool)
        case completeRefocus
    }

    enum EffectApplicationFeedback: Equatable {
        case none
        case refocusKeyboardTransitionStarted
    }

    private var pendingRefocus = GhosttyPendingTopologyInputRefocus()

    var isActive: Bool {
        pendingRefocus.isActive
    }

    mutating func prepare(
        actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        activeLeafID: UUID?,
        keyboardMode: GhosttyKeyboardChromeMode,
        keyboardOwner: GhosttyKeyboardOwner = .terminal
    ) -> Effect? {
        guard actionEffect.requestsInputRefocus else { return nil }
        guard pendingRefocus.request(
            from: activeLeafID,
            keyboardMode: keyboardMode,
            keyboardOwner: keyboardOwner
        ) else {
            return nil
        }
        return .requestRefocus
    }

    mutating func complete(
        actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        outcome: GhosttyTmuxModelActionOutcome
    ) -> Effect? {
        guard outcome.isQueued else {
            guard actionEffect.requestsInputRefocus else { return nil }
            guard pendingRefocus.isActive else { return nil }

            let ownsKeyboardTransition = pendingRefocus.ownsKeyboardTransition
            pendingRefocus.cancel()
            return .cancelRefocus(ownsKeyboardTransition: ownsKeyboardTransition)
        }

        guard actionEffect.dismissesSelectionSheetOnQueued else { return nil }
        return .dismissSelectionSheet
    }

    mutating func consumeActiveLeafChange(to activeLeafID: UUID?) -> Effect? {
        guard pendingRefocus.consumeIfActiveLeafChanged(to: activeLeafID) else {
            return nil
        }
        return .completeRefocus
    }

    mutating func cancelForCommandFailure() -> Effect? {
        guard pendingRefocus.isActive else { return nil }

        let ownsKeyboardTransition = pendingRefocus.ownsKeyboardTransition
        pendingRefocus.cancel()
        return .cancelRefocus(ownsKeyboardTransition: ownsKeyboardTransition)
    }

    @discardableResult
    mutating func perform(
        actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        activeLeafID: UUID?,
        keyboardMode: GhosttyKeyboardChromeMode,
        keyboardOwner: GhosttyKeyboardOwner = .terminal,
        apply: (Effect) -> EffectApplicationFeedback,
        action: () -> GhosttyTmuxModelActionOutcome
    ) -> GhosttyTmuxModelActionOutcome {
        if let effect = prepare(
            actionEffect: actionEffect,
            activeLeafID: activeLeafID,
            keyboardMode: keyboardMode,
            keyboardOwner: keyboardOwner
        ) {
            applyEffect(effect, using: apply)
        }

        let outcome = action()

        if let effect = complete(actionEffect: actionEffect, outcome: outcome) {
            applyEffect(effect, using: apply)
        }

        return outcome
    }

    private mutating func applyEffect(
        _ effect: Effect,
        using apply: (Effect) -> EffectApplicationFeedback
    ) {
        let feedback = apply(effect)
        guard case .requestRefocus = effect else { return }
        guard feedback == .refocusKeyboardTransitionStarted else { return }

        pendingRefocus.markKeyboardTransitionOwned()
    }
}
