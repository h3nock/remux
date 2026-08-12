import XCTest
@testable import Remux

final class GhosttyTerminalInputCoordinatorTests: XCTestCase {
    func testShowSystemKeyboardActivatesTerminalWhenInputIsAvailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.showSystemKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.keyboardOwner, .terminal)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testShowSystemKeyboardIsIgnoredWhenInputIsUnavailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.showSystemKeyboard(isInputAvailable: false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testToggleKeyboardFromHiddenShowsSystemKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.toggleKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
    }

    func testToggleKeyboardFromHiddenIsIgnoredWhenInputIsUnavailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.toggleKeyboard(isInputAvailable: false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testToggleKeyboardFromSystemRequestsSystemDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.toggleKeyboard(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertTrue(coordinator.isDismissSystemKeyboardRequested)
    }

    func testKeyboardVisibilityHideCompletesExplicitSystemDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.toggleKeyboard(isInputAvailable: true)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertFalse(coordinator.isSoftwareKeyboardVisible)
    }

    func testLateKeyboardShowDoesNotCancelExplicitDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.toggleKeyboard(isInputAvailable: true)

        coordinator.updateSoftwareKeyboardVisibility(true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertTrue(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertTrue(coordinator.isSoftwareKeyboardVisible)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertFalse(coordinator.isSoftwareKeyboardVisible)
    }

    func testLateKeyboardShowDoesNotRestoreDismissedComposerOwnership() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(
            owner: .composer,
            isOwnerAvailable: true
        )
        coordinator.toggleKeyboard(
            owner: .composer,
            isOwnerAvailable: true
        )

        coordinator.updateSoftwareKeyboardVisibility(true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertTrue(coordinator.isDismissSystemKeyboardRequested)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testKeyboardVisibilityHidePreservesSystemModeWithoutExplicitDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.updateSoftwareKeyboardVisibility(true)

        coordinator.updateSoftwareKeyboardVisibility(false)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.keyboardOwner, .terminal)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
        XCTAssertFalse(coordinator.isSoftwareKeyboardVisible)
    }

    func testUnexpectedKeyboardHideCanRequestFreshActivationWhileSystemModeIsPreserved() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)
        coordinator.updateSoftwareKeyboardVisibility(true)
        coordinator.updateSoftwareKeyboardVisibility(false)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testRefocusSystemKeyboardIfActiveRequestsFreshActivation() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
    }

    func testRefocusSystemKeyboardIfActiveDoesNothingWhenHidden() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testVisibleKeyboardTransfersFromTerminalToComposerWithoutDismissal() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.transferKeyboardOwnerIfActive(
            to: .composer,
            isOwnerAvailable: true
        )

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.keyboardOwner, .composer)
        XCTAssertEqual(coordinator.terminalActivationToken, 1)
        XCTAssertEqual(coordinator.composerActivationToken, 1)
        XCTAssertFalse(coordinator.isDismissSystemKeyboardRequested)
    }

    func testHiddenKeyboardDoesNotAppearWhenComposerBecomesAvailable() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.transferKeyboardOwnerIfActive(
            to: .composer,
            isOwnerAvailable: true
        )

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertEqual(coordinator.composerActivationToken, 0)
    }

    func testComposerKeyboardDismissHidesKeyboardAndClearsOwner() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(
            owner: .composer,
            isOwnerAvailable: true
        )

        coordinator.dismissKeyboard()

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.keyboardOwner, .none)
        XCTAssertTrue(coordinator.isDismissSystemKeyboardRequested)
    }

    func testTerminalRefocusDoesNotStealComposerKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(
            owner: .composer,
            isOwnerAvailable: true
        )

        coordinator.refocusSystemKeyboardIfActive(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardOwner, .composer)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
        XCTAssertEqual(coordinator.composerActivationToken, 1)
    }

    func testSelectionChangeDoesNotStealComposerKeyboard() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(
            owner: .composer,
            isOwnerAvailable: true
        )

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardOwner, .composer)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
        XCTAssertEqual(coordinator.composerActivationToken, 1)
    }

    func testSelectionChangeRefocusesSystemKeyboardOnlyWhenActive() {
        var coordinator = GhosttyTerminalInputCoordinator()
        coordinator.showSystemKeyboard(isInputAvailable: true)

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .system)
        XCTAssertEqual(coordinator.terminalActivationToken, 2)
    }

    func testSelectionChangeKeepsHiddenModeHidden() {
        var coordinator = GhosttyTerminalInputCoordinator()

        coordinator.handleSelectionChange(isInputAvailable: true)

        XCTAssertEqual(coordinator.keyboardMode, .hidden)
        XCTAssertEqual(coordinator.terminalActivationToken, 0)
    }

    func testPendingTopologyInputRefocusConsumesChangedActiveLeafInSystemMode() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        XCTAssertTrue(refocus.isActive)

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: sourceLeafID))
        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusIgnoresHiddenKeyboardMode() {
        let sourceLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertFalse(refocus.request(from: sourceLeafID, keyboardMode: .hidden))

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusIgnoresComposerKeyboardOwner() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertFalse(
            refocus.request(
                from: UUID(),
                keyboardMode: .system,
                keyboardOwner: .composer
            )
        )
        XCTAssertFalse(refocus.isActive)
    }

    func testPendingTopologyInputRefocusCancelClearsPendingRequest() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.request(from: UUID(), keyboardMode: .system)
        refocus.markKeyboardTransitionOwned()
        refocus.cancel()

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: UUID()))
    }

    func testPendingTopologyInputRefocusCanStartFromNilActiveLeaf() {
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))
        XCTAssertTrue(refocus.isActive)
        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.isActive)
    }

    func testPendingTopologyInputRefocusConsumesNilDestinationWhenSourceWasLeaf() {
        let sourceLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        refocus.markKeyboardTransitionOwned()

        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testPendingTopologyInputRefocusDoesNotConsumeNilDestinationFromNilSource() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))

        XCTAssertFalse(refocus.consumeIfActiveLeafChanged(to: nil))
        XCTAssertTrue(refocus.isActive)
    }

    func testPendingTopologyInputRefocusNilSourceCancelClearsOwnership() {
        var refocus = GhosttyPendingTopologyInputRefocus()

        XCTAssertTrue(refocus.request(from: nil, keyboardMode: .system))
        refocus.markKeyboardTransitionOwned()
        XCTAssertTrue(refocus.ownsKeyboardTransition)

        refocus.cancel()

        XCTAssertFalse(refocus.isActive)
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testPendingTopologyInputRefocusTracksKeyboardTransitionOwnership() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var refocus = GhosttyPendingTopologyInputRefocus()

        refocus.markKeyboardTransitionOwned()
        XCTAssertFalse(refocus.ownsKeyboardTransition)

        XCTAssertTrue(refocus.request(from: sourceLeafID, keyboardMode: .system))
        XCTAssertFalse(refocus.ownsKeyboardTransition)

        refocus.markKeyboardTransitionOwned()
        XCTAssertTrue(refocus.ownsKeyboardTransition)

        XCTAssertTrue(refocus.consumeIfActiveLeafChanged(to: nextLeafID))
        XCTAssertFalse(refocus.ownsKeyboardTransition)
    }

    func testTopologyRefocusCoordinatorIgnoresActionsWithoutRefocusPolicy() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .none,
            activeLeafID: UUID(),
            keyboardMode: .system
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorIgnoresHiddenKeyboardMode() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .hidden
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorIgnoresComposerKeyboardOwner() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .system,
            keyboardOwner: .composer
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorRequestsRefocusForSystemKeyboard() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        let effect = coordinator.prepare(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .system
        )

        XCTAssertEqual(effect, .requestRefocus)
        XCTAssertTrue(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorQueuedDismissEffectKeepsPendingRefocus() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusAndDismissOnQueued,
                activeLeafID: UUID(),
                keyboardMode: .system
            ),
            .requestRefocus
        )

        let effect = coordinator.complete(
            actionEffect: .refocusAndDismissOnQueued,
            outcome: .queued
        )

        XCTAssertEqual(effect, .dismissSelectionSheet)
        XCTAssertTrue(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorPerformAppliesEffectsAroundQueuedAction() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        var events: [String] = []

        let outcome = coordinator.perform(
            actionEffect: .refocusAndDismissOnQueued,
            activeLeafID: UUID(),
            keyboardMode: .system,
            apply: { effect in
                switch effect {
                case .requestRefocus:
                    events.append("requestRefocus")
                    return .refocusKeyboardTransitionStarted
                case .dismissSelectionSheet:
                    events.append("dismissSelectionSheet")
                    return .none
                case .cancelRefocus, .completeRefocus:
                    events.append("unexpected")
                    return .none
                }
            },
            action: {
                events.append("action")
                return .queued
            }
        )

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(events, ["requestRefocus", "action", "dismissSelectionSheet"])
        XCTAssertTrue(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorMissingTargetCancelsOwnedKeyboardTransition() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        var effects: [GhosttyTopologyActionInputRefocusCoordinator.Effect] = []

        let outcome = coordinator.perform(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .system,
            apply: { effect in
                effects.append(effect)
                return effect == .requestRefocus ? .refocusKeyboardTransitionStarted : .none
            },
            action: { .missingTarget(.focusedPane) }
        )

        XCTAssertEqual(outcome, .missingTarget(.focusedPane))
        XCTAssertEqual(effects, [.requestRefocus, .cancelRefocus(ownsKeyboardTransition: true)])
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorMissingTargetCancelsUnownedKeyboardTransition() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        var effects: [GhosttyTopologyActionInputRefocusCoordinator.Effect] = []

        let outcome = coordinator.perform(
            actionEffect: .refocusOnly,
            activeLeafID: UUID(),
            keyboardMode: .system,
            apply: { effect in
                effects.append(effect)
                return .none
            },
            action: { .missingTarget(.focusedPane) }
        )

        XCTAssertEqual(outcome, .missingTarget(.focusedPane))
        XCTAssertEqual(effects, [.requestRefocus, .cancelRefocus(ownsKeyboardTransition: false)])
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorRejectedActionCancelsEvenWhenPrepareWasIgnored() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        XCTAssertNil(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: UUID(),
                keyboardMode: .hidden
            )
        )

        let effect = coordinator.complete(
            actionEffect: .refocusOnly,
            outcome: .missingTarget(.focusedPane)
        )

        XCTAssertNil(effect)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorQueuedDismissesSheetEvenWhenPrepareWasIgnored() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()

        XCTAssertNil(
            coordinator.prepare(
                actionEffect: .refocusAndDismissOnQueued,
                activeLeafID: UUID(),
                keyboardMode: .hidden
            )
        )

        let effect = coordinator.complete(
            actionEffect: .refocusAndDismissOnQueued,
            outcome: .queued
        )

        XCTAssertEqual(effect, .dismissSelectionSheet)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorActiveLeafChangeCompletesOnlyWhenSelectionChanges() {
        let sourceLeafID = UUID()
        let nextLeafID = UUID()
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.prepare(
                actionEffect: .refocusOnly,
                activeLeafID: sourceLeafID,
                keyboardMode: .system
            ),
            .requestRefocus
        )

        XCTAssertNil(coordinator.consumeActiveLeafChange(to: sourceLeafID))
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(coordinator.consumeActiveLeafChange(to: nextLeafID), .completeRefocus)
        XCTAssertFalse(coordinator.isActive)
    }

    func testTopologyRefocusCoordinatorCommandFailureCancelsPendingRequest() {
        var coordinator = GhosttyTopologyActionInputRefocusCoordinator()
        XCTAssertEqual(
            coordinator.perform(
                actionEffect: .refocusOnly,
                activeLeafID: UUID(),
                keyboardMode: .system,
                apply: { effect in
                    effect == .requestRefocus ? .refocusKeyboardTransitionStarted : .none
                },
                action: { .queued }
            ),
            .queued
        )

        let effect = coordinator.cancelForCommandFailure()

        XCTAssertEqual(effect, .cancelRefocus(ownsKeyboardTransition: true))
        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.cancelForCommandFailure())
    }

    func testInputControllerSubmitsNormalTextUnchanged() {
        var controller = GhosttyTerminalInputController()

        XCTAssertEqual(controller.receiveText("ls\r"), .submit("ls\r"))
    }

    func testInputControllerControlTextSubmitsTranslatedInputAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()

        XCTAssertEqual(controller.receiveText("c"), .submit("\u{03}"))

        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerUnsupportedControlTextFallsBackAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()

        XCTAssertEqual(controller.receiveText("7"), .submit("7"))

        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerControlKeyAddsCtrlModifierAndClearsControl() {
        var controller = GhosttyTerminalInputController()
        controller.toggleControl()
        let event = GhosttySurfaceKeyEvent(keyCode: .arrowUp)

        let action = controller.receiveKeyEvent(event)

        XCTAssertNil(action.pendingPrefixInput)
        XCTAssertEqual(action.event, GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl]))
        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerPrefixArmsFlushWithoutSubmitting() {
        var controller = GhosttyTerminalInputController()

        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
    }

    func testInputControllerMatchingPrefixFlushSubmitsPrefixOnce() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(
            controller.flushPendingTmuxPrefixInput(matching: 1),
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput
        )
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerStalePrefixFlushDoesNotClearPendingPrefix() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 99))
        XCTAssertEqual(
            controller.flushPendingTmuxPrefixInput(matching: 1),
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput
        )
    }

    func testInputControllerPrefixNormalTextSubmitsCombinedInputAndCancelsFlush() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(controller.receiveText("c"), .submit("\u{2}c"))
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerPrefixBracketRequestsCopyModeFallbackAndCancelsFlush() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )

        XCTAssertEqual(controller.receiveText("["), .enterCopyMode(fallbackInput: "\u{2}["))
        XCTAssertNil(controller.flushPendingTmuxPrefixInput(matching: 1))
    }

    func testInputControllerPerformTextInputSubmitsNormalText() {
        var controller = GhosttyTerminalInputController()
        var submitted: [String] = []
        var scheduledTokens: [UInt64] = []
        var copyModeAttempts = 0

        let accepted = controller.performTextInput(
            "ls\r",
            submit: {
                submitted.append($0)
                return true
            },
            schedulePrefixFlush: { scheduledTokens.append($0) },
            enterCopyMode: {
                copyModeAttempts += 1
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(submitted, ["ls\r"])
        XCTAssertTrue(scheduledTokens.isEmpty)
        XCTAssertEqual(copyModeAttempts, 0)
    }

    func testInputControllerPerformTextInputSchedulesPrefixFlushWithoutSubmit() {
        var controller = GhosttyTerminalInputController()
        var submitted: [String] = []
        var scheduledTokens: [UInt64] = []

        let accepted = controller.performTextInput(
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput,
            submit: {
                submitted.append($0)
                return false
            },
            schedulePrefixFlush: { scheduledTokens.append($0) },
            enterCopyMode: { true }
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(scheduledTokens, [1])
    }

    func testInputControllerPerformTextInputQueuesCopyModeWithoutFallbackSubmit() {
        var controller = GhosttyTerminalInputController()
        var submitted: [String] = []
        var copyModeAttempts = 0

        _ = controller.performTextInput(
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput,
            submit: {
                submitted.append($0)
                return true
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: { true }
        )

        let accepted = controller.performTextInput(
            "[",
            submit: {
                submitted.append($0)
                return true
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: {
                copyModeAttempts += 1
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(copyModeAttempts, 1)
    }

    func testInputControllerPerformTextInputSubmitsCopyModeFallbackWhenNotQueued() {
        var controller = GhosttyTerminalInputController()
        var submitted: [String] = []
        var copyModeAttempts = 0

        _ = controller.performTextInput(
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput,
            submit: {
                submitted.append($0)
                return true
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: { true }
        )

        let accepted = controller.performTextInput(
            "[",
            submit: {
                submitted.append($0)
                return false
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: {
                copyModeAttempts += 1
                return false
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(submitted, ["\u{2}["])
        XCTAssertEqual(copyModeAttempts, 1)
    }

    func testInputControllerPasteFlushesPendingPrefixBeforePasteWithoutClearingControl() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
        controller.toggleControl()

        let action = controller.receivePaste("paste")

        XCTAssertEqual(action.pendingPrefixInput, GhosttyTmuxPrefixInputBuffer.defaultPrefixInput)
        XCTAssertEqual(action.text, "paste")
        XCTAssertTrue(controller.isControlArmed)
    }

    func testInputControllerPerformPasteFlushesPendingPrefixBeforePasteAndIgnoresPrefixResult() {
        var controller = GhosttyTerminalInputController()
        var calls: [String] = []

        _ = controller.performTextInput(
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput,
            submit: { _ in
                XCTFail("prefix arm should not submit immediately")
                return false
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: { true }
        )

        let accepted = controller.performPaste(
            "paste",
            submitPendingPrefix: {
                calls.append("prefix:\($0)")
                return false
            },
            sendPaste: {
                calls.append("paste:\($0)")
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(calls, ["prefix:\u{2}", "paste:paste"])
    }

    func testInputControllerPerformPasteWithoutPendingPrefixReturnsPasteResult() {
        var controller = GhosttyTerminalInputController()
        var submittedPrefix: [String] = []
        var pasted: [String] = []

        let accepted = controller.performPaste(
            "paste",
            submitPendingPrefix: {
                submittedPrefix.append($0)
                return true
            },
            sendPaste: {
                pasted.append($0)
                return false
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(submittedPrefix.isEmpty)
        XCTAssertEqual(pasted, ["paste"])
    }

    func testInputControllerKeyFlushesPendingPrefixBeforeSendingModifiedKey() {
        var controller = GhosttyTerminalInputController()
        XCTAssertEqual(
            controller.receiveText(GhosttyTmuxPrefixInputBuffer.defaultPrefixInput),
            .schedulePrefixFlush(token: 1)
        )
        controller.toggleControl()

        let action = controller.receiveKeyEvent(GhosttySurfaceKeyEvent(keyCode: .arrowUp))

        XCTAssertEqual(action.pendingPrefixInput, GhosttyTmuxPrefixInputBuffer.defaultPrefixInput)
        XCTAssertEqual(action.event, GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl]))
        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerPerformKeyFlushesPendingPrefixBeforeModifiedKeyAndIgnoresPrefixResult() {
        var controller = GhosttyTerminalInputController()
        var calls: [String] = []
        var sentEvents: [GhosttySurfaceKeyEvent] = []

        _ = controller.performTextInput(
            GhosttyTmuxPrefixInputBuffer.defaultPrefixInput,
            submit: { _ in
                XCTFail("prefix arm should not submit immediately")
                return false
            },
            schedulePrefixFlush: { _ in },
            enterCopyMode: { true }
        )
        controller.toggleControl()

        let accepted = controller.performKeyEvent(
            GhosttySurfaceKeyEvent(keyCode: .arrowUp),
            submitPendingPrefix: {
                calls.append("prefix:\($0)")
                return false
            },
            sendKey: {
                calls.append("key")
                sentEvents.append($0)
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(calls, ["prefix:\u{2}", "key"])
        XCTAssertEqual(sentEvents, [GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl])])
        XCTAssertFalse(controller.isControlArmed)
    }

    func testInputControllerPerformKeyWithoutPendingPrefixReturnsKeyResult() {
        var controller = GhosttyTerminalInputController()
        var submittedPrefix: [String] = []
        var sentEvents: [GhosttySurfaceKeyEvent] = []

        let accepted = controller.performKeyEvent(
            GhosttySurfaceKeyEvent(keyCode: .arrowDown),
            submitPendingPrefix: {
                submittedPrefix.append($0)
                return true
            },
            sendKey: {
                sentEvents.append($0)
                return false
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(submittedPrefix.isEmpty)
        XCTAssertEqual(sentEvents, [GhosttySurfaceKeyEvent(keyCode: .arrowDown)])
    }
}
