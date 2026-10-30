import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalPresentationProjectorTests: XCTestCase {
    func testTopologyAndSurfaceIdentityCannotDeclarePresentationSuccess() {
        let paneID = UUID()
        let failure = TerminalDisconnectReason(kind: .runtime, message: "first frame failed")
        for presentation in [TerminalPanePresentation.pending, .awaitingFrame, .failed(failure), .ready] {
            let snapshot = TerminalReadinessProjector.snapshot(
                phase: .running, transportWritable: true, topLevelCount: 1,
                selectedActiveLeafID: paneID, selectedPanePresentation: presentation
            )
            XCTAssertEqual(TerminalReadinessProjector.uiTestInputReady(snapshot), presentation == .ready)
            XCTAssertEqual(TerminalReadinessProjector.isTerminalStatusReady(snapshot, commandFailureMessage: nil), presentation == .ready)
            let expected: TerminalRuntimeState = switch presentation {
            case .pending, .awaitingFrame: .connecting
            case .ready: .connected
            case .failed(let reason): .disconnected(reason)
            }
            XCTAssertEqual(TerminalReadinessProjector.runtimeState(snapshot), expected)
            if presentation == .failed(failure) {
                XCTAssertEqual(GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                    readiness: snapshot, commandFailureMessage: "less important command failure",
                    debugStatus: "", registryDebugSummary: ""
                ), .failed(message: failure.message, reason: failure))
            }
        }
    }

    /// A session the root doesn't show draws nothing, so it reads as connected once its focused pane is
    /// live. Typing and the screen's own readiness still wait for a drawn frame.
    func testASessionThatIsNotShownIsConnectedWithoutADrawnFrame() {
        let paneID = UUID()
        let failure = TerminalDisconnectReason(kind: .runtime, message: "renderer failed")
        let cases: [(TerminalPanePresentation, isShown: Bool, TerminalRuntimeState)] = [
            (.awaitingFrame, false, .connected),
            (.ready, false, .connected),
            (.pending, false, .connecting),
            (.failed(failure), false, .disconnected(failure)),
            (.awaitingFrame, true, .connecting),
            (.ready, true, .connected),
        ]
        for (presentation, isShown, expected) in cases {
            let snapshot = TerminalReadinessProjector.snapshot(
                phase: .running, transportWritable: true, topLevelCount: 1,
                selectedActiveLeafID: paneID, selectedPanePresentation: presentation, isShown: isShown
            )
            XCTAssertEqual(
                TerminalReadinessProjector.runtimeState(snapshot), expected,
                "\(presentation), shown: \(isShown)"
            )
            XCTAssertEqual(TerminalReadinessProjector.canSubmitInput(snapshot), presentation == .ready)
            XCTAssertEqual(
                TerminalReadinessProjector.isTerminalStatusReady(snapshot, commandFailureMessage: nil),
                presentation == .ready
            )
        }

        // Not shown still needs a writable transport, a focused pane and a window.
        let unready = [
            TerminalReadinessProjector.snapshot(
                phase: .running, transportWritable: false, topLevelCount: 1,
                selectedActiveLeafID: paneID, selectedPanePresentation: .awaitingFrame, isShown: false
            ),
            TerminalReadinessProjector.snapshot(
                phase: .running, transportWritable: true, topLevelCount: 1,
                selectedActiveLeafID: nil, selectedPanePresentation: .awaitingFrame, isShown: false
            ),
            TerminalReadinessProjector.snapshot(
                phase: .running, transportWritable: true, topLevelCount: 0,
                selectedActiveLeafID: paneID, selectedPanePresentation: .awaitingFrame, isShown: false
            ),
            TerminalReadinessProjector.snapshot(
                phase: .starting, transportWritable: true, topLevelCount: 1,
                selectedActiveLeafID: paneID, selectedPanePresentation: .awaitingFrame, isShown: false
            ),
        ]
        for snapshot in unready {
            XCTAssertEqual(TerminalReadinessProjector.runtimeState(snapshot), .connecting)
        }
    }

    func testCompositeLayoutUsesExactSharedCellMetricWithoutScaling() throws {
        let layout = try XCTUnwrap(GhosttyCompositeViewportLayout(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            grid: .init(columns: 80, rows: 24),
            cellMetrics: .init(
                pixelWidth: 8,
                pixelHeight: 16,
                contentScale: 2
            )
        ))

        XCTAssertEqual(layout.cellSize, CGSize(width: 4, height: 8))
        XCTAssertEqual(layout.canvasSize, CGSize(width: 320, height: 192))
        XCTAssertEqual(layout.origin, CGPoint(x: 40, y: 0))
        XCTAssertEqual(
            layout.frame(for: .init(x: 0, y: 0, columns: 39, rows: 24)),
            CGRect(x: 40, y: 0, width: 156, height: 192)
        )
        XCTAssertEqual(
            layout.frame(for: .init(x: 40, y: 0, columns: 40, rows: 24)),
            CGRect(x: 200, y: 0, width: 160, height: 192)
        )
    }

    /// The keyboard closing grows the viewport before the server's taller grid arrives; the
    /// smaller grid must stay where it is meanwhile.
    func testCompositeLayoutKeepsAGridThatDoesNotFillTheViewportInPlaceAsTheViewportGrows() throws {
        let grid = GhosttyTerminalGridSize(columns: 55, rows: 29)
        let cellMetrics = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
        let keyboardUp = try XCTUnwrap(GhosttyCompositeViewportLayout(
            bounds: CGRect(x: 0, y: 0, width: 440, height: 520),
            grid: grid,
            cellMetrics: cellMetrics
        ))
        let keyboardDown = try XCTUnwrap(GhosttyCompositeViewportLayout(
            bounds: CGRect(x: 0, y: 0, width: 440, height: 806),
            grid: grid,
            cellMetrics: cellMetrics
        ))
        let pane = GhosttyTerminalGridRect(x: 0, y: 0, columns: 55, rows: 29)

        XCTAssertEqual(keyboardUp.frame(for: pane), keyboardDown.frame(for: pane))
        XCTAssertEqual(keyboardDown.frame(for: pane).minY, 0)
    }

    func testTwoSideBySidePanesShareOneDividerWithTmuxHalfFocusOwnership() throws {
        let leftID = UUID()
        let rightID = UUID()
        let separators = GhosttyPaneSeparatorLayout.segments(for: [
            .init(
                id: leftID,
                frame: .init(x: 0, y: 0, columns: 39, rows: 24)
            ),
            .init(
                id: rightID,
                frame: .init(x: 40, y: 0, columns: 40, rows: 24)
            ),
        ])

        let separator = try XCTUnwrap(separators.first)
        XCTAssertEqual(separators.count, 1)
        XCTAssertEqual(separator.orientation, .vertical)
        XCTAssertEqual(separator.position, 39.5)
        XCTAssertEqual(separator.start, -0.5)
        XCTAssertEqual(separator.end, 24.5)
        XCTAssertEqual(
            separator.focusedRange(focusedPaneID: leftID, paneCount: 2),
            -0.5..<12
        )
        XCTAssertEqual(
            separator.focusedRange(focusedPaneID: rightID, paneCount: 2),
            12..<24.5
        )
    }

    func testTwoStackedPanesShareOneDividerWithTmuxHalfFocusOwnership() throws {
        let topID = UUID()
        let bottomID = UUID()
        let separators = GhosttyPaneSeparatorLayout.segments(for: [
            .init(
                id: topID,
                frame: .init(x: 0, y: 0, columns: 80, rows: 11)
            ),
            .init(
                id: bottomID,
                frame: .init(x: 0, y: 12, columns: 80, rows: 12)
            ),
        ])

        let separator = try XCTUnwrap(separators.first)
        XCTAssertEqual(separators.count, 1)
        XCTAssertEqual(separator.orientation, .horizontal)
        XCTAssertEqual(separator.position, 11.5)
        XCTAssertEqual(
            separator.focusedRange(focusedPaneID: topID, paneCount: 2),
            -0.5..<40
        )
        XCTAssertEqual(
            separator.focusedRange(focusedPaneID: bottomID, paneCount: 2),
            40..<80.5
        )
    }

    func testNestedLayoutHighlightsEveryInternalSegmentAdjacentToFocusedPane() {
        let topLeftID = UUID()
        let bottomLeftID = UUID()
        let rightID = UUID()
        let separators = GhosttyPaneSeparatorLayout.segments(for: [
            .init(
                id: topLeftID,
                frame: .init(x: 0, y: 0, columns: 39, rows: 11)
            ),
            .init(
                id: bottomLeftID,
                frame: .init(x: 0, y: 12, columns: 39, rows: 12)
            ),
            .init(
                id: rightID,
                frame: .init(x: 40, y: 0, columns: 40, rows: 24)
            ),
        ])

        XCTAssertEqual(separators.count, 3)
        let focusedSegments = separators.filter {
            $0.focusedRange(focusedPaneID: rightID, paneCount: 3) != nil
        }
        XCTAssertEqual(focusedSegments.count, 2)
        XCTAssertTrue(focusedSegments.allSatisfy { $0.orientation == .vertical })
        XCTAssertEqual(
            focusedSegments.map { $0.focusedRange(focusedPaneID: rightID, paneCount: 3) },
            [Optional(-0.5..<11.5), Optional(11.5..<24.5)]
        )
    }

    /// The screen draws a line over its cells, `width` points across; a square cap reaches half the
    /// width past each end, so a box's corner closes.
    func testALineIsDrawnOverItsCellsAndASquareCapClosesACorner() {
        let origin = CGPoint(x: 3, y: 0)
        let cell = CGSize(width: 10, height: 20)
        let divider = GhosttyPaneLine(
            orientation: .vertical, position: 39.5, start: -0.5, end: 24.5, ink: .separator, width: 1, cap: .butt
        )
        XCTAssertEqual(divider.frame(origin: origin, cellSize: cell), CGRect(x: 397.5, y: -10, width: 1, height: 500))

        let top = GhosttyPaneLine(
            orientation: .horizontal, position: 0.5, start: 0.5, end: 39.5, ink: .focus, width: 1, cap: .square
        )
        let left = GhosttyPaneLine(
            orientation: .vertical, position: 0.5, start: 0.5, end: 21.5, ink: .focus, width: 1, cap: .square
        )
        let topFrame = top.frame(origin: origin, cellSize: cell)
        let leftFrame = left.frame(origin: origin, cellSize: cell)
        XCTAssertEqual(topFrame, CGRect(x: 7.5, y: 9.5, width: 391, height: 1))
        XCTAssertEqual(leftFrame, CGRect(x: 7.5, y: 9.5, width: 1, height: 421))
        XCTAssertEqual(topFrame.minX, leftFrame.minX, "the corner has no notch")
        XCTAssertEqual(topFrame.minY, leftFrame.minY, "the corner has no notch")
    }

    /// tmux's lines for a window: each separator, then the accent along the focused pane's side, as the
    /// screen has always drawn them; none for one pane or a zoomed window.
    func testTmuxLinesAreItsSeparatorsThenTheFocusedPanesAccent() {
        func pane(_ id: UUID, _ frame: GhosttyTerminalGridRect, visible: Bool = true, focused: Bool = false)
            -> GhosttyTerminalViewportPresentationProjection.Pane
        {
            .init(
                id: id, normalFrame: frame, visibleFrame: visible ? frame : nil, isFocused: focused,
                currentCommand: "", currentPath: ""
            )
        }
        let left = UUID()
        let right = UUID()
        let panes = [
            pane(left, .init(x: 0, y: 0, columns: 39, rows: 24)),
            pane(right, .init(x: 40, y: 0, columns: 40, rows: 24), focused: true),
        ]
        XCTAssertEqual(GhosttyPaneSeparatorLayout.lines(for: panes), [
            GhosttyPaneLine(orientation: .vertical, position: 39.5, start: -0.5, end: 24.5, ink: .separator, width: 1, cap: .butt),
            GhosttyPaneLine(orientation: .vertical, position: 39.5, start: 12, end: 24.5, ink: .focus, width: 2, cap: .butt),
        ])
        XCTAssertEqual(GhosttyPaneSeparatorLayout.lines(for: [panes[1]]), [])
        XCTAssertEqual(GhosttyPaneSeparatorLayout.lines(for: [
            pane(left, .init(x: 0, y: 0, columns: 39, rows: 24), visible: false),
            pane(right, .init(x: 0, y: 0, columns: 80, rows: 24), focused: true),
        ]), [])
    }

    func testSinglePaneHasNoSeparatorOrFocusMarker() {
        let paneID = UUID()
        XCTAssertTrue(
            GhosttyPaneSeparatorLayout.segments(for: [
                .init(
                    id: paneID,
                    frame: .init(x: 0, y: 0, columns: 80, rows: 24)
                ),
            ]).isEmpty
        )
    }

    func testReadinessProjectionReportsRuntimeStateSemantics() {
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        let cases: [(TerminalReadinessSnapshot, TerminalRuntimeState)] = [
            (
                Self.readinessSnapshot(phase: .idle, focused: false),
                .connecting
            ),
            (
                Self.readinessSnapshot(phase: .starting, focused: true),
                .connecting
            ),
            (
                Self.readinessSnapshot(phase: .running, focused: false),
                .connecting
            ),
            (
                Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: false,
                    topLevelCount: 0,
                    focused: true
                ),
                .connecting
            ),
            (
                Self.readinessSnapshot(phase: .failed(message: "fallback", reason: reason), focused: false),
                .disconnected(reason)
            ),
            (
                Self.readinessSnapshot(phase: .failed(message: "runtime failed", reason: nil), focused: true),
                .disconnected(
                    TerminalDisconnectReason(
                        kind: .unknown,
                        message: "runtime failed"
                    )
                )
            ),
        ]

        for (readiness, expectedState) in cases {
            XCTAssertEqual(TerminalReadinessProjector.runtimeState(readiness), expectedState)
        }
    }

    func testReadinessProjectionSeparatesInteractionAndTransportInputGates() {
        XCTAssertFalse(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .idle, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: true)
            )
        )
    }

    func testScalarCanSubmitInputProjectionMatchesSnapshotProjection() {
        let cases: [TerminalReadinessSnapshot] = [
            Self.readinessSnapshot(phase: .idle, transportWritable: true, focused: true),
            Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true),
            Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true),
            Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false),
            Self.readinessSnapshot(phase: .running, transportWritable: true, focused: true),
        ]

        for snapshot in cases {
            XCTAssertEqual(
                TerminalReadinessProjector.canSubmitInput(
                    phase: snapshot.phase,
                    transportWritable: snapshot.transportWritable,
                    hasFocusedSurface: snapshot.hasFocusedSurface
                ),
                TerminalReadinessProjector.canSubmitInput(snapshot)
            )
        }
    }

    func testStatusAndInputReadinessBothRequirePresentedSelectedPane() {
        let statusReadyWithoutFocusedSurface = Self.readinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            focused: false
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                statusReadyWithoutFocusedSurface,
                commandFailureMessage: nil
            )
        )
        XCTAssertFalse(TerminalReadinessProjector.uiTestInputReady(statusReadyWithoutFocusedSurface))

        let notTransportWritable = Self.readinessSnapshot(
            phase: .running,
            transportWritable: false,
            topLevelCount: 1,
            focused: true
        )
        XCTAssertFalse(TerminalReadinessProjector.uiTestInputReady(notTransportWritable))

        let inputReady = Self.readinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            focused: true
        )
        XCTAssertTrue(TerminalReadinessProjector.uiTestInputReady(inputReady))

        XCTAssertFalse(
            TerminalReadinessProjector.uiTestInputReady(
                Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.uiTestInputReady(
                Self.readinessSnapshot(
                    phase: .failed(message: "failed", reason: nil),
                    transportWritable: true,
                    focused: true
                )
            )
        )
        XCTAssertEqual(
            TerminalReadinessProjector.uiTestInputReady(inputReady),
            TerminalReadinessProjector.canSubmitInput(inputReady)
        )
    }

    func testReadinessProjectionPreservesStatusAndTraceConditions() {
        XCTAssertTrue(
            TerminalReadinessProjector.isWaitingForPanes(
                phase: .running,
                topLevelCount: 0
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isWaitingForPanes(
                phase: .failed(message: "runtime failed", reason: nil),
                topLevelCount: 0
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: nil
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: true),
                commandFailureMessage: "tmux command failed"
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false),
                commandFailureMessage: nil
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .starting, topLevelCount: 1, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false)
            )
        )
    }

    func testStatusOverlayProjectionPreservesStatePrecedence() {
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .idle, topLevelCount: 0, focused: false),
                commandFailureMessage: "ignored",
                debugStatus: "idle debug",
                registryDebugSummary: "idle registry"
            ),
            .starting
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .starting, topLevelCount: 0, focused: false),
                commandFailureMessage: nil,
                debugStatus: "starting debug",
                registryDebugSummary: "starting registry"
            ),
            .starting
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(
                    phase: .failed(message: "transport lost", reason: nil),
                    topLevelCount: 1,
                    focused: true
                ),
                commandFailureMessage: "ignored",
                debugStatus: "failed debug",
                registryDebugSummary: "failed registry"
            ),
            .failed(message: "transport lost", reason: nil)
        )
    }

    func testStatusOverlayProjectionPreservesHostKeyChallengeReason() {
        let challenge = SSHHostKeyTrustChallenge(
            kind: .changed,
            serverID: UUID(uuidString: "7b882734-5e15-48dd-a48c-40ff7b8906db")!,
            host: "macbook.local",
            trustedKeyType: "ssh-ed25519",
            trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 received"
        )
        let reason = TerminalDisconnectReason(
            kind: .hostKey,
            message: "Host key changed",
            hostKeyChallenge: challenge
        )

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(
                    phase: .failed(message: "Host key changed", reason: reason),
                    topLevelCount: 1,
                    focused: true
                ),
                commandFailureMessage: nil,
                debugStatus: "failed debug",
                registryDebugSummary: "failed registry"
            ),
            .failed(message: "Host key changed", reason: reason)
        )
    }

    func testStatusOverlayProjectionPreservesRunningPrecedence() {
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: "No space for another pane.",
                debugStatus: "running debug",
                registryDebugSummary: "running registry"
            ),
            .commandFailure("No space for another pane.")
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: nil,
                debugStatus: "transport started",
                registryDebugSummary: "top=0"
            ),
            .waitingForPanes(
                debugStatus: "transport started",
                registryDebugSummary: "top=0"
            )
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false),
                commandFailureMessage: nil,
                debugStatus: "transport started",
                registryDebugSummary: "top=1"
            ),
            .waitingForPanes(debugStatus: "transport started", registryDebugSummary: "top=1")
        )
    }

    /// A switch to another tab under way says where it goes over the session's notice and over the screen's
    /// readiness, never as the session opening; a failure says why instead.
    func testStatusOverlayProjectionSaysWhereASwitchGoes() {
        let ready = Self.readinessSnapshot(phase: .running, transportWritable: true, focused: true)
        func overlay(
            _ readiness: TerminalReadinessSnapshot,
            failure: String? = nil,
            notice: String? = nil,
            switchingTo tab: String?
        ) -> GhosttyTerminalStatusOverlayProjection {
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: readiness,
                commandFailureMessage: failure,
                noticeMessage: notice,
                switchingTo: tab,
                debugStatus: "",
                registryDebugSummary: ""
            )
        }
        XCTAssertEqual(overlay(ready, switchingTo: "build"), .switching("build"))
        XCTAssertEqual(overlay(ready, notice: "Copied to clipboard", switchingTo: "build"), .switching("build"))
        XCTAssertEqual(overlay(ready, failure: "Herdr: select tab failed", switchingTo: "build"), .commandFailure("Herdr: select tab failed"))
        XCTAssertEqual(overlay(Self.readinessSnapshot(phase: .running, focused: false), switchingTo: "build"), .switching("build"))
        XCTAssertEqual(
            overlay(Self.readinessSnapshot(phase: .failed(message: "lost", reason: nil), focused: true), switchingTo: "build"),
            .failed(message: "lost", reason: nil)
        )
        XCTAssertEqual(overlay(ready, switchingTo: nil), .ready)
    }

    func testViewportProjectionKeepsSurfaceInstanceSeparateFromPaneIdentity() {
        let paneID = UUID()
        let surfaceInstanceID = UUID()
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [
                GhosttyTopLevelSurface(
                    id: UUID(),
                    leafIDs: [paneID],
                    focusedLeafID: paneID
                ),
            ],
            selectedTopLevelID: nil
        )

        let projection = GhosttyTerminalPresentationProjector
            .terminalScreenPresentationProjection(
                phase: .running,
                transportWritable: true,
                commandFailureMessage: nil,
                debugStatus: "ready",
                registryDebugSummary: "one surface",
                presentedSurfaceID: surfaceInstanceID,
                snapshot: snapshot,
                viewportProjection: .init(
                    windowGrid: nil,
                    cellMetrics: nil,
                    panes: [],
                    paneLines: [],
                    focusedSurfaceID: surfaceInstanceID,
                    isServerZoomed: false,
                    windowCount: 1
                )
            )

        XCTAssertEqual(projection.viewport.focusedSurfaceID, surfaceInstanceID)
        XCTAssertEqual(projection.interaction.selectedActiveLeafID, surfaceInstanceID)
        XCTAssertNotEqual(projection.viewport.focusedSurfaceID, paneID)
    }

    func testPaneSheetDismissesWhenItsWindowIsNoLongerSelected() {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [
                GhosttyTopLevelSurface(id: firstWindowID, leafIDs: []),
                GhosttyTopLevelSurface(id: secondWindowID, leafIDs: []),
            ],
            selectedTopLevelID: secondWindowID
        )

        XCTAssertTrue(
            GhosttyTerminalPresentationProjector.paneSelectionSheetTopologyProjection(
                topLevelID: firstWindowID,
                snapshot: snapshot
            ).shouldDismissPaneSheet
        )
        XCTAssertFalse(
            GhosttyTerminalPresentationProjector.paneSelectionSheetTopologyProjection(
                topLevelID: secondWindowID,
                snapshot: snapshot
            ).shouldDismissPaneSheet
        )
    }

    func testWindowSelectionProjectionRemovesControlScalarsOnceAndPreservesUnicode() throws {
        let windowID = UUID()
        let paneID = UUID()
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [
                GhosttyTopLevelSurface(
                    id: windowID,
                    name: "dé\u{0001}ploy\n-漢字",
                    leafIDs: [paneID],
                    focusedLeafID: paneID
                ),
            ],
            selectedTopLevelID: windowID
        )

        let projection = GhosttyTerminalPresentationProjector
            .windowSelectionSheetRenderProjection(snapshot: snapshot)

        XCTAssertEqual(
            try XCTUnwrap(projection.windows.first).displayName,
            "déploy-漢字"
        )
    }

    func testWindowPreviewCapturePrioritizesTheSelectedWindow() {
        let firstWindowID = UUID()
        let selectedWindowID = UUID()
        let thirdWindowID = UUID()
        let firstPaneID = UUID()
        let selectedPaneID = UUID()
        let thirdPaneID = UUID()
        let snapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: [
                GhosttyTopLevelSurface(
                    id: firstWindowID,
                    leafIDs: [firstPaneID],
                    focusedLeafID: firstPaneID
                ),
                GhosttyTopLevelSurface(
                    id: selectedWindowID,
                    leafIDs: [selectedPaneID],
                    focusedLeafID: selectedPaneID
                ),
                GhosttyTopLevelSurface(
                    id: thirdWindowID,
                    leafIDs: [thirdPaneID],
                    focusedLeafID: thirdPaneID
                ),
            ],
            selectedTopLevelID: selectedWindowID
        )

        let projection = GhosttyTerminalPresentationProjector
            .windowSelectionSheetRenderProjection(snapshot: snapshot)

        XCTAssertEqual(
            projection.windows.map(\.id),
            [firstWindowID, selectedWindowID, thirdWindowID],
            "capture priority must not reorder the picker tiles"
        )
        XCTAssertEqual(
            projection.previewLeafIDs,
            [selectedPaneID, firstPaneID, thirdPaneID]
        )
    }

    /// The window sheet offers the three most recent groups as capsules, and the rest behind More only when
    /// some don't fit.
    func testTheGroupsThatDontFitAsCapsulesAreTheOnlyOnesBehindMore() {
        for count in [1, 3, 4, 5] {
            let groups = (1...count).map { GhosttyWindowSelectionSheetRenderProjection.Grouping.Group(id: UUID(), name: "w\($0)") }
            let grouping = GhosttyWindowSelectionSheetRenderProjection.Grouping(
                noun: .workspace,
                groups: groups,
                shownGroupID: groups[0].id,
                largestWindowCount: 1
            )
            XCTAssertEqual(grouping.capsules, Array(groups.prefix(3)), "\(count) groups")
            XCTAssertEqual(grouping.overflow, Array(groups.dropFirst(3)), "\(count) groups")
        }
    }

    /// Closing reads the current tiles: their last-tab confirmation may have changed while a menu was open.
    func testATileRemovalAsksWhatClosingItAsksWhenTheActionIsChosen() {
        func tab(_ id: UUID, asking confirmation: GhosttyCloseConfirmation?) -> GhosttyWindowSelectionSheetRenderProjection.Window {
            GhosttyWindowSelectionSheetRenderProjection.Window(
                id: id, displayName: "build", displayIndex: 1, totalCount: 1, paneCount: 1, isSelected: false,
                focusedPreviewPaneID: nil, closeConfirmation: confirmation
            )
        }
        let id = UUID()
        let lastTab = GhosttyCloseConfirmation(
            title: "Close Workspace?",
            message: "“web” and its 1 tab and 1 pane will close.",
            action: "Close Workspace"
        )
        var removal = GhosttyTileRemoval<GhosttyWindowSelectionSheetRenderProjection.Window>()

        XCTAssertNil(removal.remove(id, among: [tab(id, asking: lastTab)]), "The tab closed without asking.")
        XCTAssertEqual(removal.asked?.closeConfirmation, lastTab)
        removal.end()

        XCTAssertEqual(removal.remove(id, among: [tab(id, asking: nil)])?.id, id, "A tab with a sibling again asked.")
        XCTAssertNil(removal.asked)

        XCTAssertNil(removal.remove(id, among: []), "A tab the sheet no longer lists was removed.")
        XCTAssertNil(removal.asked)
    }

    /// A tile that goes while its question is up, as when another client closes it, takes the question with it,
    /// so nothing is left to agree to; a question about a tile still listed stays.
    func testATileThatGoesTakesItsRemovalQuestionWithIt() {
        let lastTab = GhosttyCloseConfirmation(title: "Close Workspace?", message: "“web” will close.", action: "Close Workspace")
        let id = UUID()
        let other = UUID()
        let tab = GhosttyWindowSelectionSheetRenderProjection.Window(
            id: id, displayName: "build", displayIndex: 1, totalCount: 1, paneCount: 1, isSelected: false,
            focusedPreviewPaneID: nil, closeConfirmation: lastTab
        )
        var removal = GhosttyTileRemoval<GhosttyWindowSelectionSheetRenderProjection.Window>()

        XCTAssertNil(removal.remove(tab.id, among: [tab]), "The workspace's only tab closed without asking.")
        removal.keep(among: [id, other])
        XCTAssertEqual(removal.asked?.id, id, "A question about a tab still listed went.")

        removal.keep(among: [other])
        XCTAssertNil(removal.asked, "A question about a tab no longer listed stayed.")
    }

    func testTerminalReadyTraceFieldsPreserveExistingKeysAndAddRawReadinessFacts() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let selectedLeafID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let snapshot = TerminalReadinessProjector.snapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 2,
            selectedActiveLeafID: selectedLeafID
        )

        XCTAssertEqual(
            TerminalReadinessProjector.terminalReadyTraceFields(
                snapshot,
                managedSurfaceCount: 3,
                workspaceID: workspaceID
            ),
            [
                "topLevels": "2",
                "managedSurfaces": "3",
                "workspaceID": workspaceID.uuidString,
                "phase": "running",
                "transportWritable": "true",
                "selectedActiveLeafID": "AAAAAAAA",
            ]
        )
    }

    private static func readinessSnapshot(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool = false,
        topLevelCount: Int = 1,
        focused: Bool
    ) -> TerminalReadinessSnapshot {
        TerminalReadinessProjector.snapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: topLevelCount,
            selectedActiveLeafID: focused ? UUID() : nil,
            selectedPanePresentation: focused ? .ready : .pending
        )
    }
}
