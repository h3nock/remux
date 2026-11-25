import XCTest
@testable import Remux

final class GhosttyTerminalResponderFocusPolicyTests: XCTestCase {
    func testUnavailablePanePausesInputWithoutSurrenderingRequestedKeyboard() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            keyboardOwner: .terminal,
            isInputAvailable: false,
            isKeyboardFocusAvailable: true,
            isTransientInputOwnerPresented: false
        )
        XCTAssertFalse(policy.isResponderEnabled)
        XCTAssertTrue(policy.wantsFirstResponder)
    }

    func testAttachmentModalPresentationsBecomeTransientInputOwners() {
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isCameraPresented: true,
                isPhotosPickerPresented: false,
                isFileImporterPresented: false,
                isPreviewPresented: false
            ).isTransientInputOwnerPresented
        )
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isCameraPresented: false,
                isPhotosPickerPresented: true,
                isFileImporterPresented: false,
                isPreviewPresented: false
            ).isTransientInputOwnerPresented
        )
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isCameraPresented: false,
                isPhotosPickerPresented: false,
                isFileImporterPresented: true,
                isPreviewPresented: false
            ).isTransientInputOwnerPresented
        )
        XCTAssertTrue(
            GhosttyAttachmentInputOwnerProjection(
                isCameraPresented: false,
                isPhotosPickerPresented: false,
                isFileImporterPresented: false,
                isPreviewPresented: true
            ).isTransientInputOwnerPresented
        )
    }

    func testPendingAttachmentPreviewCanOpenOnlyWhenNotSending() {
        XCTAssertTrue(
            GhosttyPendingAttachmentInteractionProjection(
                hasPreviewableAttachments: true,
                isTransferInProgress: false
            ).canOpenPreview
        )
        XCTAssertFalse(
            GhosttyPendingAttachmentInteractionProjection(
                hasPreviewableAttachments: true,
                isTransferInProgress: true
            ).canOpenPreview
        )
        XCTAssertFalse(
            GhosttyPendingAttachmentInteractionProjection(
                hasPreviewableAttachments: false,
                isTransferInProgress: false
            ).canOpenPreview
        )
    }

    func testStagedAttachmentsDoNotSuspendTerminalResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            keyboardOwner: .terminal,
            isInputAvailable: true,
            isKeyboardFocusAvailable: true,
            isTransientInputOwnerPresented: false
        )

        XCTAssertTrue(policy.isResponderEnabled)
        XCTAssertTrue(policy.wantsFirstResponder)
    }

    func testAttachmentInputOwnerSuspendsTerminalResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            keyboardOwner: .terminal,
            isInputAvailable: true,
            isKeyboardFocusAvailable: true,
            isTransientInputOwnerPresented: true
        )

        XCTAssertFalse(policy.isResponderEnabled)
        XCTAssertFalse(policy.wantsFirstResponder)
    }

    func testHiddenKeyboardDoesNotRequestFirstResponder() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .hidden,
            keyboardOwner: .none,
            isInputAvailable: true,
            isKeyboardFocusAvailable: true,
            isTransientInputOwnerPresented: false
        )

        XCTAssertTrue(policy.isResponderEnabled)
        XCTAssertFalse(policy.wantsFirstResponder)
    }

    func testComposerKeyboardOwnerKeepsTerminalEligibleForResponderHandoff() {
        let policy = GhosttyTerminalResponderFocusPolicy(
            isSelected: true,
            keyboardMode: .system,
            keyboardOwner: .composer,
            isInputAvailable: true,
            isKeyboardFocusAvailable: true,
            isTransientInputOwnerPresented: false
        )

        XCTAssertTrue(policy.isResponderEnabled)
        XCTAssertFalse(policy.wantsFirstResponder)
    }

    func testCoveredPresentationOwnsInputOnlyUntilKeyboardRestorationBegins() {
        XCTAssertFalse(GhosttyTerminalCoverPhase.visible.ownsTerminalInput)
        XCTAssertTrue(
            GhosttyTerminalCoverPhase.covered(
                restoreKeyboard: true
            ).ownsTerminalInput
        )
        XCTAssertTrue(
            GhosttyTerminalCoverPhase.covered(
                restoreKeyboard: false
            ).ownsTerminalInput
        )
        XCTAssertFalse(GhosttyTerminalCoverPhase.restoringKeyboard.ownsTerminalInput)
        XCTAssertTrue(GhosttyTerminalCoverPhase.restoringKeyboard.isRestoringKeyboard)
        XCTAssertFalse(GhosttyTerminalCoverPhase.visible.isRestoringKeyboard)
    }

    func testComposerHoldsKeyboardWhenItOwnsIt() {
        XCTAssertTrue(
            GhosttyComposerResponderFocusPolicy(
                keyboardMode: .system,
                keyboardOwner: .composer,
                isTransientInputOwnerPresented: false
            ).wantsFirstResponder
        )
        XCTAssertFalse(
            GhosttyComposerResponderFocusPolicy(
                keyboardMode: .system,
                keyboardOwner: .terminal,
                isTransientInputOwnerPresented: false
            ).wantsFirstResponder
        )
        XCTAssertFalse(
            GhosttyComposerResponderFocusPolicy(
                keyboardMode: .hidden,
                keyboardOwner: .composer,
                isTransientInputOwnerPresented: false
            ).wantsFirstResponder
        )
    }

    func testComposerGivesUpKeyboardUnderPickerCameraAndViewer() {
        XCTAssertFalse(
            GhosttyComposerResponderFocusPolicy(
                keyboardMode: .system,
                keyboardOwner: .composer,
                isTransientInputOwnerPresented: true
            ).wantsFirstResponder,
            "Wanting the keyboard under the viewer, the composer takes it back when markup ends and it covers the viewer."
        )
    }
}
