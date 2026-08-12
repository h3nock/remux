import Foundation
import XCTest

@testable import Remux

@MainActor
final class TmuxSessionControllerClientSizeTests: XCTestCase {
    func testCrossWindowSelectionCommandPolicy() {
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 20,
                zoomed: false
            ),
            ["select-window -t @2"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 21,
                zoomed: true
            ),
            ["select-window -t @2", "select-pane -Z -t %21"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 20,
                zoomed: true
            ),
            ["select-window -t @2"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: nil,
                zoomed: false
            ),
            ["select-window -t @2"]
        )
        XCTAssertEqual(
            TmuxSessionController.crossWindowSelectionCommands(
                windowID: 2,
                activePaneID: 20,
                preferredPaneID: 21,
                zoomed: false
            ),
            ["select-window -t @2", "select-pane -t %21"]
        )
    }

    func testPaneCurrentDirectoryUsesOneTargetedCommandAndReturnsItsBody() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        let query = Task {
            try await harness.controller.paneCurrentDirectory(for: 1)
        }
        try await waitUntil("current-directory query was not written") {
            harness.recorder.hasWrites
        }
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["display-message -p -t %1 '#{pane_current_path}'\n"]
        )

        harness.controller.pump(Data(responseBlock(
            commandNumber: &nextCommandNumber,
            body: "/Users/macbook/scratchpad\n"
        ).utf8))
        let currentDirectory = try await query.value
        XCTAssertEqual(currentDirectory, "/Users/macbook/scratchpad")
    }

    func testPaneCurrentDirectoryReturnsCommandFailureWithoutRequestFailureUI() async throws {
        let requestFailure = expectation(description: "no request failure callback")
        requestFailure.isInverted = true
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3,
            callbacks: .init(onRequestFailed: { _ in requestFailure.fulfill() })
        )
        var nextCommandNumber = harness.nextCommandNumber

        let query = Task {
            try await harness.controller.paneCurrentDirectory(for: 1)
        }
        try await waitUntil("current-directory query was not written") {
            harness.recorder.hasWrites
        }
        _ = harness.recorder.takeStrings()
        harness.controller.pump(Data(errorBlock(
            commandNumber: &nextCommandNumber,
            body: "can't find pane: %1"
        ).utf8))

        do {
            _ = try await query.value
            XCTFail("expected the query to fail")
        } catch {
            XCTAssertEqual(
                error as? TmuxSessionController.PaneCurrentDirectoryError,
                .commandFailed("can't find pane: %1")
            )
        }
        await fulfillment(of: [requestFailure], timeout: 0.05)
    }

    func testShutdownResumesOutstandingPaneCurrentDirectoryQuery() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        let query = Task {
            try await harness.controller.paneCurrentDirectory(for: 1)
        }
        try await waitUntil("current-directory query was not written") {
            harness.recorder.hasWrites
        }
        _ = harness.recorder.takeStrings()

        await shutDown(harness.controller)

        do {
            _ = try await query.value
            XCTFail("expected shutdown to fail the query")
        } catch {
            XCTAssertEqual(
                error as? TmuxSessionController.PaneCurrentDirectoryError,
                .sessionUnavailable
            )
        }
    }

    func testSideBySideNavigationCoalescesOnEachRevisit() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %2\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2"
        )
    }

    func testPaneNavigationWaitsWhenCommandEndsBeforeTopology() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            responseBlock(commandNumber: &nextCommandNumber).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "command completion must not admit the deferred intent against stale topology"
        )

        harness.controller.pump(Data(
            "%window-pane-changed @0 %1\n".utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %0"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %0\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testPaneNavigationUsesTopologyThatArrivedBeforeCompletion() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data("%window-pane-changed @0 %1\n".utf8))
        await drain(harness.controller)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the outstanding mutation must still coalesce later navigation"
        )

        harness.controller.pump(Data(
            responseBlock(commandNumber: &nextCommandNumber).utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2"
        )
    }

    func testPaneNavigationWaitsWhenSubmittedAfterCompletionBeforeTopology() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            responseBlock(commandNumber: &nextCommandNumber).utf8
        ))
        await drain(harness.controller)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "a successful mutation remains pending until newer topology arrives"
        )

        harness.controller.pump(Data(
            "%window-pane-changed @0 %1\n".utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2"
        )
    }

    func testPaneNavigationReevaluatesImmediatelyAfterCommandError() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            errorBlock(commandNumber: &nextCommandNumber, body: "can't find pane: %1").utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %2"
        )
    }

    func testFailedSelectionRetriesTheLatestTarget() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            errorBlock(commandNumber: &nextCommandNumber, body: "can't find pane: %1").utf8
        ))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-pane -Z -t %1\n"],
            "the latest selection is retried after the first command fails"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testRepeatedCrossWindowUnzoomedSelectionDoesNotQueueSecondSelection() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.splitTargetWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @1\n"])

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the repeated intent must re-evaluate as zero after the first selection"
        )
    }

    func testExplicitZoomRunsAfterUnzoomedWindowSelection() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.splitTargetWindow,
            expectedPaneCount: 3
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestSetPaneZoomed(paneID: 1, zoomed: true)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @1\n"])

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "resize-pane -Z -t %1"
        )
    }

    func testExplicitUnzoomTogglesAnAuthoritativelyZoomedWindow() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneSameColumnZoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestSetPaneZoomed(paneID: 0, zoomed: false)
        await drain(harness.controller)

        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "resize-pane -Z -t %0"
        )
    }

    func testWindowSelectionLeavesZoomedSourceWindowUntouched() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.zoomedSourceAndTargetWindow,
            expectedPaneCount: 3
        )

        harness.controller.requestSelectWindow(
            windowID: 1,
            preferredPaneID: 2
        )
        await drain(harness.controller)

        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-window -t @1\n"]
        )
    }

    func testLifecycleCleanupBatchesEveryOwnedZoomedWindow() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoZoomedWindows,
            expectedPaneCount: 4
        )

        harness.controller.requestSetWindowsZoomed(
            windowIDs: [0, 1],
            zoomed: false
        )
        await drain(harness.controller)

        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["resize-pane -Z -t @0 ; resize-pane -Z -t @1\n"]
        )
    }

    func testGlobalDefaultZoomsEveryRequestedMultipaneWindowInOneWrite() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoUnzoomedWindows,
            expectedPaneCount: 4
        )

        harness.controller.requestSetWindowsZoomed(
            windowIDs: [0, 1],
            zoomed: true
        )
        await drain(harness.controller)

        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["resize-pane -Z -t %0 ; resize-pane -Z -t %2\n"]
        )
    }

    func testGlobalDefaultSendsNothingWhenEveryWindowAlreadyMatches() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoZoomedWindows,
            expectedPaneCount: 4
        )

        harness.controller.requestSetWindowsZoomed(
            windowIDs: [0, 1],
            zoomed: true
        )
        await drain(harness.controller)

        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testLatestGlobalZoomSettingRunsAfterAnInFlightZoom() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSetWindowsZoomed(windowIDs: [1], zoomed: true)
        harness.controller.requestSetWindowsZoomed(windowIDs: [1], zoomed: false)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["resize-pane -Z -t %1\n"])

        let layout = "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}"
        harness.controller.pump(Data(
            (responseBlock(commandNumber: &nextCommandNumber)
                + "%layout-change @1 \(layout) b7de,83x44,0,0,1 *Z\n").utf8
        ))
        await drain(harness.controller)

        XCTAssertEqual(harness.recorder.takeStrings(), ["resize-pane -Z -t @1\n"])
    }

    func testGlobalZoomIsNotDiscardedByLaterPaneNavigation() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 2)
        harness.controller.requestSetWindowsZoomed(windowIDs: [1], zoomed: true)
        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-pane -t %2\n"])

        harness.controller.pump(Data(
            ("%window-pane-changed @1 %2\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["resize-pane -Z -t %2\n"])

        let layout = "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}"
        harness.controller.pump(Data(
            (responseBlock(commandNumber: &nextCommandNumber)
                + "%layout-change @1 \(layout) b7df,83x44,0,0,2 *Z\n").utf8
        ))
        await drain(harness.controller)

        XCTAssertEqual(harness.recorder.takeStrings(), ["select-pane -Z -t %1\n"])
    }

    func testWindowNavigationCoalescesRollbackToLatestWindow() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoSinglePaneWindows,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectWindow(windowID: 1, preferredPaneID: 1)
        harness.controller.requestSelectWindow(windowID: 0, preferredPaneID: 0)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @1\n"])

        harness.controller.pump(Data(
            ("%session-window-changed $42 @1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @0\n"])
    }

    func testUnzoomedPaneSelectionUsesOnlySelectPane() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)

        XCTAssertEqual(harness.recorder.takeStrings(), ["select-pane -t %2\n"])
    }

    func testUnzoomedPaneSelectionDoesNotReplaceTerminal() async throws {
        let lifecycle = ControllerLifecycleRecorder()
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2,
            callbacks: lifecycle.callbacks
        )
        try await waitUntil("initial terminals were not handed off") {
            lifecycle.terminalPaneIDs.count == 2
        }
        let initialTerminalPaneIDs = lifecycle.terminalPaneIDs
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 2)
        await drain(harness.controller)
        _ = harness.recorder.takeStrings()
        harness.controller.pump(Data(
            ("%window-pane-changed @1 %2\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)

        XCTAssertEqual(lifecycle.terminalPaneIDs, initialTerminalPaneIDs)
    }

    func testTopBottomRoundTripUsesOnlySelectionCommands() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneSameColumnZoomedWindow,
            expectedPaneCount: 2
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestSelectPane(paneID: 1)
        await drain(harness.controller)

        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %1"
        )

        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + responseBlock(commandNumber: &nextCommandNumber)).utf8
        ))
        await drain(harness.controller)

        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "select-pane -Z -t %0"
        )
    }

    func testClientSizePublishesOnlyDistinctViewportChanges() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        harness.controller.setClientSize(cols: 83, rows: 44)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "the renderer reporting the already-submitted initial grid must do no work"
        )

        harness.controller.setClientSize(cols: 83, rows: 40)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["refresh-client -C 83x40\n"])

        harness.controller.setClientSize(cols: 100, rows: 40)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["refresh-client -C 100x40\n"])
    }

    func testClientSizeRevertPublishesEachDistinctSize() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        harness.controller.setClientSize(cols: 100, rows: 40)
        harness.controller.setClientSize(cols: 83, rows: 44)
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["refresh-client -C 100x40\n", "refresh-client -C 83x44\n"]
        )
    }

    func testActiveViewportClaimDoesNothingWhenWindowMatchesClientSize() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )

        harness.controller.claimActiveViewportIfNeeded()
        await drain(harness.controller)

        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testExplicitViewportReclaimRunsWhenTopologyStillMatches() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.reclaimActiveViewport()
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["select-window -t @0\n"])

        harness.controller.pump(Data(responseBlock(
            commandNumber: &nextCommandNumber
        ).utf8))
        await drain(harness.controller)

        harness.controller.reclaimActiveViewport()
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-window -t @0\n"],
            "a matching reclaim must not wait for a layout change that tmux will not emit"
        )
    }

    func testInputClaimsMismatchedActiveViewportBeforeSendingBytes() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        var nextCommandNumber = harness.nextCommandNumber
        let desktopLayout = "d4fd,189x49,0,0,0"
        harness.controller.pump(Data(
            "%layout-change @0 \(desktopLayout) \(desktopLayout) *\n".utf8
        ))
        await drain(harness.controller)

        XCTAssertTrue(harness.controller.sendInput(paneID: 0, Data("a".utf8)))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-window -t @0\nsend-keys -H -t %0 61\n"]
        )

        XCTAssertTrue(harness.controller.sendInput(paneID: 0, Data("b".utf8)))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["send-keys -H -t %0 62\n"],
            "key repeat must not enqueue duplicate viewport claims"
        )

        harness.controller.pump(Data(
            "%layout-change @0 \(desktopLayout) \(desktopLayout) *\n".utf8
        ))
        harness.controller.pump(Data(responseBlock(
            commandNumber: &nextCommandNumber
        ).utf8))
        await drain(harness.controller)

        XCTAssertTrue(harness.controller.sendInput(paneID: 0, Data("c".utf8)))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["send-keys -H -t %0 63\n"],
            "a command reply must not settle the claim while the viewport still mismatches"
        )

        let remuxLayout = "b7dd,83x44,0,0,0"
        harness.controller.pump(Data(
            "%layout-change @0 \(remuxLayout) \(remuxLayout) *\n".utf8
        ))
        harness.controller.pump(Data(
            "%layout-change @0 \(desktopLayout) \(desktopLayout) *\n".utf8
        ))
        await drain(harness.controller)

        XCTAssertTrue(harness.controller.sendInput(paneID: 0, Data("d".utf8)))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-window -t @0\nsend-keys -H -t %0 64\n"]
        )
    }

    func testSelectedViewportResizePublishesRefreshThenClaimInOneWrite() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )

        harness.controller.setClientSize(
            cols: 100,
            rows: 40,
            claimActiveViewport: true
        )
        await drain(harness.controller)

        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["refresh-client -C 100x40\nselect-window -t @0\n"]
        )
    }

    func testActiveViewportClaimPrecedesTopologyActionInOneWrite() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        let desktopLayout = "d4fd,189x49,0,0,0"
        harness.controller.pump(Data(
            "%layout-change @0 \(desktopLayout) \(desktopLayout) *\n".utf8
        ))
        await drain(harness.controller)

        harness.controller.requestNewWindow()
        await drain(harness.controller)

        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["select-window -t @0\nnew-window\n"]
        )
    }

    func testNewWindowAndSplitSendOnlyTheirTmuxMutations() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )

        harness.controller.requestSelectPane(paneID: 0)
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        harness.controller.requestNewWindow()
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["new-window\n"])

        harness.controller.requestSplit(paneID: 0, direction: .right, zoom: false)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["split-window -h -t %0\n"])

        harness.controller.requestSplit(paneID: 0, direction: .right, zoom: true)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["split-window -h -Z -t %0\n"])
    }

    func testZoomingSplitReportsOwnershipAfterTmuxAcceptsIt() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        var nextCommandNumber = harness.nextCommandNumber
        let zoomCreated = expectation(description: "zooming split accepted")

        harness.controller.requestSplit(
            paneID: 0,
            direction: .right,
            zoom: true,
            onZoomCreated: { zoomCreated.fulfill() }
        )
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["split-window -h -Z -t %0\n"])

        harness.controller.pump(Data(responseBlock(
            commandNumber: &nextCommandNumber
        ).utf8))
        await fulfillment(of: [zoomCreated], timeout: 1)
    }

    func testZoomedInactivePaneCloseBatchesDeleteAndRezoom() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )

        harness.controller.requestClosePane(paneID: 1)
        await drain(harness.controller)

        assertCommandWrite(
            harness.recorder.takeStrings(),
            command: "kill-pane -t %1 ; resize-pane -Z -t @0"
        )
    }

    func testZoomedActivePaneCloseUsesTmuxSelectedSuccessor() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.threePaneZoomedWindow,
            expectedPaneCount: 3
        )

        harness.controller.requestClosePane(paneID: 0)
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["kill-pane -t %0 ; resize-pane -Z -t @0\n"]
        )

        let layout = "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}"
        harness.controller.pump(Data(
            ("%window-pane-changed @0 %1\n"
                + "%layout-change @0 \(layout) \(layout) *\n"
                + "%layout-change @0 \(layout) b7de,83x44,0,0,1 *Z\n").utf8
        ))
        await drain(harness.controller)

        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testZoomedTwoPaneCloseLeavesSinglePaneUnzoomed() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneSameColumnZoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestClosePane(paneID: 0)
        await drain(harness.controller)

        XCTAssertEqual(harness.recorder.takeStrings(), ["kill-pane -t %0\n"])
    }

    func testNormalPaneCloseWaitsForExpandedTopologyBeforeAnotherClose() async throws {
        let topologyRecorder = ControllerTopologyRecorder()
        let harness = try await readyController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2,
            callbacks: .init(onTopology: { topologyRecorder.append($0) })
        )
        topologyRecorder.clear()
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestClosePane(paneID: 1)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["kill-pane -t %1\n"])

        harness.controller.pump(Data(responseBlock(commandNumber: &nextCommandNumber).utf8))
        await drain(harness.controller)
        harness.controller.requestClosePane(paneID: 2)
        await drain(harness.controller)
        XCTAssertTrue(
            harness.recorder.takeStrings().isEmpty,
            "another close must wait for authoritative topology after a successful mutation"
        )

        let expandedLayout = "b7df,83x44,0,0,2"
        harness.controller.pump(Data(
            "%layout-change @1 \(expandedLayout) \(expandedLayout) *\n".utf8
        ))
        await drain(harness.controller)

        let topology = try XCTUnwrap(topologyRecorder.latest)
        let pane = try XCTUnwrap(topology.panes.first)
        XCTAssertEqual(topology.panes.count, 1)
        XCTAssertEqual(pane.id, 2)
        XCTAssertEqual(pane.x, 0)
        XCTAssertEqual(pane.y, 0)
        XCTAssertEqual(pane.width, 83)
        XCTAssertEqual(pane.height, 44)

        harness.controller.requestClosePane(paneID: 2)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["kill-pane -t %2\n"])
    }

    func testWindowCloseWaitsForAuthoritativeRemovalBeforeAnotherClose() async throws {
        let topologyRecorder = ControllerTopologyRecorder()
        let harness = try await readyController(
            listWindowsBody: Self.twoSinglePaneWindows,
            expectedPaneCount: 2,
            callbacks: .init(onTopology: { topologyRecorder.append($0) })
        )
        topologyRecorder.clear()
        var nextCommandNumber = harness.nextCommandNumber

        harness.controller.requestCloseWindow(windowID: 1)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["kill-window -t @1\n"])

        harness.controller.pump(Data(responseBlock(commandNumber: &nextCommandNumber).utf8))
        await drain(harness.controller)
        harness.controller.requestCloseWindow(windowID: 0)
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)

        harness.controller.pump(Data("%unlinked-window-close @1\n".utf8))
        await drain(harness.controller)
        let topology = try XCTUnwrap(topologyRecorder.latest)
        XCTAssertEqual(topology.windows.map(\.id), [0])

        harness.controller.requestCloseWindow(windowID: 0)
        await drain(harness.controller)
        XCTAssertEqual(harness.recorder.takeStrings(), ["kill-window -t @0\n"])
    }

    func testZoomDuringInitialHydrationDoesNotQueueExtraCommands() async throws {
        let harness = try await hydratingController(
            listWindowsBody: Self.twoPaneUnzoomedWindow,
            expectedPaneCount: 2
        )

        harness.controller.requestSetPaneZoomed(paneID: 1, zoomed: true)
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["resize-pane -Z -t %1\n"]
        )

        let hydrationEnd = harness.firstHydrationCommandNumber + harness.hydrationCommandCount
        let hydration = (harness.firstHydrationCommandNumber..<hydrationEnd)
            .map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }
            .joined()
        harness.controller.pump(Data(hydration.utf8))
        await drain(harness.controller)

        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
    }

    func testDetachedRequestReportsImmediateFailure() async throws {
        let recorder = RequestFailureRecorder()
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                Task { await recorder.append(request) }
            })
        )

        controller.requestCopyMode(paneID: 1)

        try await waitUntil("detached request failure was not reported") {
            await recorder.requests().contains(.copyMode)
        }
        await shutDown(controller)
    }

    func testDetachedInputSubmissionReturnsImmediatelyThenReportsFailure() async {
        let failureReported = expectation(description: "input failure reported")
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                XCTAssertEqual(request, .sendInput)
                failureReported.fulfill()
            })
        )

        XCTAssertTrue(controller.sendInput(paneID: 1, Data([0x61])))
        await fulfillment(of: [failureReported], timeout: 1)
        await shutDown(controller)
    }

    func testInputSubmissionDoesNotWaitForEarlierWriterQueueWork() async {
        let failureReported = expectation(description: "input failure reported")
        let controller = TmuxSessionController(
            callbacks: .init(onRequestFailed: { request in
                XCTAssertEqual(request, .sendInput)
                failureReported.fulfill()
            })
        )
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        controller.queue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        let clock = ContinuousClock()
        let startedAt = clock.now
        XCTAssertTrue(controller.sendInput(paneID: 1, Data([0x61])))
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(25))

        releaseBlocker.signal()
        await fulfillment(of: [failureReported], timeout: 1)
        await shutDown(controller)
    }

    func testTrackedInputCompletesForItsExactTmuxResponse() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        let completed = expectation(description: "tracked input completed")

        XCTAssertTrue(harness.controller.sendTrackedInput(
            paneID: 0,
            Data("message".utf8),
            completion: { succeeded in
                XCTAssertTrue(succeeded)
                completed.fulfill()
            }
        ))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            ["send-keys -H -t %0 6d 65 73 73 61 67 65\n"]
        )

        let commandNumber = harness.nextCommandNumber
        harness.controller.pump(Data(
            ("%begin \(commandNumber) \(commandNumber) 1\n"
                + "%end \(commandNumber) \(commandNumber) 1\n").utf8
        ))
        await fulfillment(of: [completed], timeout: 1)
    }

    func testTrackedLiteralInputUsesOneEscapedTmuxArgument() async throws {
        let harness = try await readyController(
            listWindowsBody: Self.onePaneWindow,
            expectedPaneCount: 1
        )
        let completed = expectation(description: "tracked literal input completed")
        let payload = "\u{1B}[200~paste \"$HOME\"\n🙂\u{1B}[201~"

        XCTAssertTrue(harness.controller.sendTrackedLiteralInput(
            paneID: 0,
            Data(payload.utf8),
            completion: { succeeded in
                XCTAssertTrue(succeeded)
                completed.fulfill()
            }
        ))
        await drain(harness.controller)
        XCTAssertEqual(
            harness.recorder.takeStrings(),
            [
                "send-keys -l -t %0 -- \"\\033[200\\176paste \\042\\044HOME"
                    + "\\042\\012🙂\\033[201\\176\"\n"
            ]
        )

        let commandNumber = harness.nextCommandNumber
        harness.controller.pump(Data(
            ("%begin \(commandNumber) \(commandNumber) 1\n"
                + "%end \(commandNumber) \(commandNumber) 1\n").utf8
        ))
        await fulfillment(of: [completed], timeout: 1)
    }

    private struct ReadyControllerHarness {
        let runtime: GhosttyKitRuntime
        let controller: TmuxSessionController
        let recorder: ControllerOutboundRecorder
        let nextCommandNumber: Int
    }

    private struct HydratingControllerHarness {
        let runtime: GhosttyKitRuntime
        let controller: TmuxSessionController
        let recorder: ControllerOutboundRecorder
        let firstHydrationCommandNumber: Int
        let hydrationCommandCount: Int
    }

    private func readyController(
        listWindowsBody: String,
        expectedPaneCount: Int,
        callbacks: TmuxSessionController.Callbacks = .init()
    ) async throws -> ReadyControllerHarness {
        let harness = try await hydratingController(
            listWindowsBody: listWindowsBody,
            expectedPaneCount: expectedPaneCount,
            callbacks: callbacks
        )
        let hydrationEnd = harness.firstHydrationCommandNumber + harness.hydrationCommandCount
        let hydration = (harness.firstHydrationCommandNumber..<hydrationEnd)
            .map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }
            .joined()
        harness.controller.pump(Data(hydration.utf8))
        await drain(harness.controller)
        XCTAssertTrue(harness.recorder.takeStrings().isEmpty)
        return ReadyControllerHarness(
            runtime: harness.runtime,
            controller: harness.controller,
            recorder: harness.recorder,
            nextCommandNumber: harness.firstHydrationCommandNumber
                + harness.hydrationCommandCount
        )
    }

    private func hydratingController(
        listWindowsBody: String,
        expectedPaneCount: Int,
        callbacks: TmuxSessionController.Callbacks = .init()
    ) async throws -> HydratingControllerHarness {
        let runtime = try GhosttyKitRuntime()
        let recorder = ControllerOutboundRecorder()
        let controller = TmuxSessionController(callbacks: callbacks)
        addTeardownBlock {
            await withCheckedContinuation { continuation in
                controller.shutdown { continuation.resume() }
            }
        }
        controller.setOutboundSink { recorder.append($0) }
        await drain(controller)
        try await withCheckedThrowingContinuation { continuation in
            controller.start(initialSize: .init(cols: 83, rows: 44)) { result in
                continuation.resume(with: result)
            }
        }
        controller.pump(Data(
            "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8
        ))
        await drain(controller)
        XCTAssertEqual(
            recorder.takeStrings(),
            [
                "display-message -p '#{version}'\n"
                    + "refresh-client -C 83x44\n"
                    + "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout} #{window_name}'\n"
            ]
        )
        controller.pump(Data(
            ("%begin 2 2 1\n3.1\n%end 2 2 1\n"
                + "%begin 3 3 1\n%end 3 3 1\n"
                + "%begin 4 4 1\n\(listWindowsBody)%end 4 4 1\n").utf8
        ))
        await drain(controller)
        let hydrationWrites = recorder.takeStrings()
        let hydrationOutbound = hydrationWrites.joined()
        let hydrationCommandCount = hydrationOutbound
            .split(separator: "\n")
            .reduce(0) { count, line in
                count + 1 + line.components(separatedBy: " ; ").count - 1
            }
        XCTAssertEqual(
            hydrationCommandCount,
            1 + expectedPaneCount * 4,
            "hydration must use one pane-state scan and four captures per pane"
        )
        let firstHydrationCommandNumber = 5
        return HydratingControllerHarness(
            runtime: runtime,
            controller: controller,
            recorder: recorder,
            firstHydrationCommandNumber: firstHydrationCommandNumber,
            hydrationCommandCount: hydrationCommandCount
        )
    }

    private func responseBlock(commandNumber: inout Int) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + "%end \(commandNumber) \(commandNumber) 1\n"
    }

    private func responseBlock(
        commandNumber: inout Int,
        body: String
    ) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + body
            + "%end \(commandNumber) \(commandNumber) 1\n"
    }

    private func assertCommandWrite(
        _ writes: [String],
        command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(writes, [command + "\n"], file: file, line: line)
    }

    private func errorBlock(commandNumber: inout Int, body: String) -> String {
        defer { commandNumber += 1 }
        return "%begin \(commandNumber) \(commandNumber) 1\n"
            + "\(body)\n"
            + "%error \(commandNumber) \(commandNumber) 1\n"
    }

    private func drain(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.queue.async { continuation.resume() }
        }
    }

    private func shutDown(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }

    private static let threePaneZoomedWindow = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "85ff,83x44,0,0{27x44,0,0,0,27x44,28,0,1,27x44,56,0,2}",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    )

    private static let splitTargetWindow = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "b7dd,83x44,0,0,0",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    ) + windowRecord(
        id: 1,
        active: false,
        paneID: 1,
        layout: "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}",
        visibleLayout: "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}",
        name: "window-1"
    )

    private static let twoSinglePaneWindows = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "b7dd,83x44,0,0,0",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    ) + windowRecord(
        id: 1,
        active: false,
        paneID: 1,
        layout: "b7de,83x44,0,0,1",
        visibleLayout: "b7de,83x44,0,0,1",
        name: "window-1"
    )

    private static let zoomedSourceAndTargetWindow = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    ) + windowRecord(
        id: 1,
        active: false,
        paneID: 2,
        layout: "b7df,83x44,0,0,2",
        visibleLayout: "b7df,83x44,0,0,2",
        name: "window-1"
    )

    private static let twoZoomedWindows = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    ) + windowRecord(
        id: 1,
        active: false,
        paneID: 2,
        layout: "4084,83x44,0,0[83x22,0,0,2,83x21,0,23,3]",
        visibleLayout: "b7df,83x44,0,0,2",
        name: "window-1"
    )

    private static let twoUnzoomedWindows = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
        visibleLayout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
        name: "window-0"
    ) + windowRecord(
        id: 1,
        active: false,
        paneID: 2,
        layout: "4084,83x44,0,0[83x22,0,0,2,83x21,0,23,3]",
        visibleLayout: "4084,83x44,0,0[83x22,0,0,2,83x21,0,23,3]",
        name: "window-1"
    )

    private static let onePaneWindow = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "b7dd,83x44,0,0,0",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    )

    private static let twoPaneUnzoomedWindow = windowRecord(
        id: 1,
        active: true,
        paneID: 1,
        layout: "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}",
        visibleLayout: "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}",
        name: "window-1"
    )

    private static let twoPaneSameColumnZoomedWindow = windowRecord(
        id: 0,
        active: true,
        paneID: 0,
        layout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
        visibleLayout: "b7dd,83x44,0,0,0",
        name: "window-0"
    )

    private static func windowRecord(
        id: Int,
        active: Bool,
        paneID: Int,
        layout: String,
        visibleLayout: String,
        name: String
    ) -> String {
        "$42 @\(id) \(active ? 1 : 0) %\(paneID) 83 44 "
            + "\(layout) \(visibleLayout) \(name)\n"
    }
}

private actor RequestFailureRecorder {
    private var recordedRequests: [TmuxSessionController.Request] = []

    func append(_ request: TmuxSessionController.Request) {
        recordedRequests.append(request)
    }

    func requests() -> [TmuxSessionController.Request] {
        recordedRequests
    }
}

private final class ControllerOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Data] = []

    func append(_ data: Data) {
        lock.withLock { writes.append(data) }
    }

    var hasWrites: Bool {
        lock.withLock { !writes.isEmpty }
    }

    func takeStrings() -> [String] {
        lock.withLock {
            defer { writes.removeAll() }
            return writes.map { String(decoding: $0, as: UTF8.self) }
        }
    }
}

private final class ControllerLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var terminals: [TmuxSessionController.RetainedPaneTerminal] = []

    var callbacks: TmuxSessionController.Callbacks {
        .init(
            onPaneTerminal: { [self] terminal in
                lock.withLock { terminals.append(terminal) }
            }
        )
    }

    var terminalPaneIDs: [TmuxPaneID] {
        lock.withLock { terminals.map(\.paneID).sorted() }
    }
}

private final class ControllerTopologyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [TmuxSessionController.TopologySnapshot] = []

    func append(_ snapshot: TmuxSessionController.TopologySnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    func clear() {
        lock.withLock { snapshots.removeAll() }
    }

    var latest: TmuxSessionController.TopologySnapshot? {
        lock.withLock { snapshots.last }
    }
}
