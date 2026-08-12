import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalPresentationProjectorTests: XCTestCase {
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
        XCTAssertEqual(layout.origin, CGPoint(x: 40, y: 54))
        XCTAssertEqual(
            layout.frame(for: .init(x: 0, y: 0, columns: 39, rows: 24)),
            CGRect(x: 40, y: 54, width: 156, height: 192)
        )
        XCTAssertEqual(
            layout.frame(for: .init(x: 40, y: 0, columns: 40, rows: 24)),
            CGRect(x: 200, y: 54, width: 160, height: 192)
        )
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
                .connected
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

    func testUITestInputReadyUsesSubmitInputContractNotStatusReady() {
        let statusReadyWithoutFocusedSurface = Self.readinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            focused: false
        )
        XCTAssertTrue(
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
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isWaitingForPanes(
                phase: .running,
                topLevelCount: 0
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isWaitingForPanes(
                Self.readinessSnapshot(phase: .starting, topLevelCount: 0, focused: false)
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
        XCTAssertTrue(
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
        XCTAssertTrue(
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
            .ready
        )
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
            selectedActiveLeafID: focused ? UUID() : nil
        )
    }
}
