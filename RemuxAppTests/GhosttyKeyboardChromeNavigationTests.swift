import XCTest
import SwiftUI
import UIKit
@testable import Remux

/// Resizing the production screen must preserve the live session and its compose draft.
@MainActor
final class GhosttySurfaceScreenResizeTests: XCTestCase {
    func testRegularWidthResizingPreservesSessionAndComposerDraft() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The regular-width phone layout switches between portrait controls and landscape chrome.")
        }
        let server = SavedServer(displayName: "Test Host", host: "host.example.test", username: "tester")
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "main")
        let target = SessionTarget(server: server, workspace: workspace,
            sshAuth: .password(username: server.username, password: "test",
                identityID: server.identityID, displayLabel: server.displayName))
        let transport = ResizeTestTmuxTransport()
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = TmuxScreenModel(target: target, sessionInstanceID: UUID(),
            transportFactory: { _ in transport }, onRuntimeStateChange: { updates.append($0) })
        let composer = GhosttyComposerModel()
        composer.isPresented = true
        composer.draft = "Keep this draft\nwhen the screen resizes"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let screen = GhosttySurfaceScreen(
            model: model.terminalScreenAdapter,
            presentation: GhosttySurfaceScreenPresentation(workspaceID: workspace.id,
                sessionName: workspace.sessionName, serverName: server.displayName,
                terminalTheme: .remuxDark, toolbarKeys: .default, loadingTitle: "Opening Session"),
            isSelected: true, composer: composer,
            shortcutStore: ShortcutStore(repository: FileBackedShortcutRepository(rootURL: root)),
            attachmentTransferServiceFactory: { FailingComposerAttachmentTransferService() },
            onReconnect: {}, onCloseSession: {}, onRestartSession: {}, onShowSessions: {},
            onShowLibrary: {}, onUpdateCredentials: {}, onEditServer: {}, onTrustHostKey: {}
        )
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: screen)
        host.safeAreaRegions = []
        let portrait = CGSize(width: 720, height: 1000)
        let landscape = CGSize(width: 1000, height: 720)
        let window = UIWindow(frame: CGRect(origin: .zero, size: portrait))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        model.setSelected(true)
        model.handleAppLifecyclePhase(.active)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: root)
            Task { await model.stop() }
        }

        try await waitUntil("the terminal did not become ready", in: host) {
            model.session?.state == .ready && self.runtimeState(model) == .connected
        }
        try await waitUntil("the compose draft was not displayed", in: host) {
            self.textViews(in: host.view).contains { $0.text == composer.draft }
        }
        let draft = composer.draft
        let initialSize = try XCTUnwrap(model.carriedClientSize)
        updates.removeAll()

        for size in [landscape, portrait] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await waitUntil("the terminal did not resize to \(size)", in: host) {
                guard let clientSize = model.carriedClientSize else { return false }
                return size == landscape
                    ? clientSize.cols > initialSize.cols
                    : clientSize.cols == initialSize.cols
            }
            try await waitUntil("the terminal or compose draft did not recover after resizing", in: host) {
                self.runtimeState(model) == .connected
                    && self.textViews(in: host.view).contains { $0.text == draft }
            }
            XCTAssertEqual(model.session?.state, .ready)
            XCTAssertFalse(model.isDisconnected)
            XCTAssertTrue(composer.isPresented)
            XCTAssertEqual(composer.draft, draft)
            XCTAssertFalse(updates.contains { $0.state.disconnectedReason != nil },
                "resizing must not disconnect the session, even temporarily")
        }
        await model.stop()
    }

    private func runtimeState(_ model: TmuxScreenModel) -> TerminalRuntimeState {
        TerminalReadinessProjector.runtimeState(model.terminalScreenAdapter.terminalScreenPresentationProjection.readiness)
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func waitUntil(_ message: String, in host: UIViewController, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}

}

/// Answers commands as they arrive, so additional startup queries cannot shift the pane's reply.
private actor ResizeTestTmuxTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var partialLine = ""
    private var nextCommand = 2

    init() {
        (receivedBytes, continuation) = AsyncThrowingStream.makeStream()
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        continuation.yield(Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8))
    }

    func send(_ data: Data) async throws {
        if TmuxControlClientExit.isRequested(in: data) {
            continuation.finish()
            return
        }
        partialLine += String(decoding: data, as: UTF8.self)
        while let newline = partialLine.firstIndex(of: "\n") {
            let line = String(partialLine[..<newline])
            partialLine = String(partialLine[partialLine.index(after: newline)...])
            for command in line.components(separatedBy: " ; ") {
                let number = nextCommand
                nextCommand += 1
                let body: String
                if command.contains("#{version}") {
                    body = "3.1\n"
                } else if command.hasPrefix("list-windows"), command.contains("#{session_id}") {
                    body = "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 window-0\n"
                } else if command.hasPrefix("list-panes"), command.contains("#{cursor_flag}") {
                    body = "%0;83;44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;43;8,16;zsh;/home/test\n"
                } else if command.hasPrefix("list-panes") {
                    body = "%0;83;44;0;0;0;0;b7dd,83x44,0,0,0;\n"
                } else {
                    body = ""
                }
                continuation.yield(Data("%begin \(number) \(number) 1\n\(body)%end \(number) \(number) 1\n".utf8))
            }
        }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        continuation.finish()
    }
}

/// The toolbar's Tabs and Panes buttons, which a popup over the tab holds as Herdr's client holds its tab bar.
final class GhosttyKeyboardChromeNavigationTests: XCTestCase {
    func testNavigationStatusIncludesSelectedWindowAndPaneCount() {
        let status = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: 1, windowCount: 3, paneCount: 2)
        XCTAssertEqual(status.windowBadge, "2")
        XCTAssertEqual(status.windowAccessibilityLabel, "Window 2 of 3")
        XCTAssertEqual(status.paneBadge, "2")
        XCTAssertEqual(status.paneAccessibilityLabel, "Panes, 2 panes")
    }

    func testNavigationStatusOmitsBadgesForSingleItemsAndCapsLargeCounts() {
        let single = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: nil, windowCount: 1, paneCount: 1)
        XCTAssertNil(single.windowBadge)
        XCTAssertNil(single.paneBadge)
        XCTAssertEqual(single.windowAccessibilityLabel, "Window 1 of 1")
        XCTAssertEqual(single.paneAccessibilityLabel, "Panes, 1 pane")
        let large = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: 99, windowCount: 3, paneCount: 100)
        XCTAssertEqual(large.windowBadge, "3")
        XCTAssertEqual(large.paneBadge, "99+")
        let empty = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: nil, windowCount: 0, paneCount: 0)
        XCTAssertEqual(empty.windowAccessibilityLabel, "Windows")
        XCTAssertEqual(empty.paneAccessibilityLabel, "Panes")
    }

    /// While a popup holds the tab, Tabs and Panes stay on the toolbar, dimmed, and say why; once it
    /// closes they work and say what they do again.
    func testAPopupHoldsTheToolbarsTabsAndPanes() {
        let held = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: true, windowCount: 3, paneCount: 2)
        XCTAssertFalse(held.isTabsEnabled)
        XCTAssertFalse(held.isPanesEnabled)
        XCTAssertEqual(held.tabsHint, GhosttyKeyboardChromeNavigation.heldByPopupHint)
        XCTAssertEqual(held.panesHint, GhosttyKeyboardChromeNavigation.heldByPopupHint)

        let free = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 3, paneCount: 2)
        XCTAssertTrue(free.isTabsEnabled)
        XCTAssertTrue(free.isPanesEnabled)
        XCTAssertEqual(free.tabsHint, "switch or create")
        XCTAssertEqual(free.panesHint, "switch or split")
    }

    /// Without a popup the buttons follow the terminal's input and what there is to list, as before.
    func testWithoutAPopupTheButtonsFollowInputAndCounts() {
        let noInput = GhosttyKeyboardChromeNavigation(isEnabled: false, isHeldByPopup: false, windowCount: 1, paneCount: 1)
        XCTAssertFalse(noInput.isTabsEnabled)
        XCTAssertFalse(noInput.isPanesEnabled)
        let one = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 1, paneCount: 1)
        XCTAssertEqual(one.tabsHint, "create")
        XCTAssertEqual(one.panesHint, "split or stack")
        let none = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 0, paneCount: 0)
        XCTAssertFalse(none.isTabsEnabled)
        XCTAssertFalse(none.isPanesEnabled)
    }
}

final class GhosttyRailViewportTests: XCTestCase {
    func testStatusAndKeyboardBoundTheScrollableArea() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 700),
            avoiding: [CGRect(x: 300, y: 20, width: 76, height: 110),
                       CGRect(x: 0, y: 400, width: 400, height: 300)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 142, width: 76, height: 246))
    }

    func testKeyboardResizingDoesNotDiscardATallSystemRegion() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 200),
            avoiding: [CGRect(x: 300, y: 0, width: 76, height: 110)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 122, width: 76, height: 66))
    }

    func testBottomOcclusionAndUnrelatedHorizontalRegion() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 700),
            avoiding: [CGRect(x: 300, y: 600, width: 76, height: 100),
                       CGRect(x: 0, y: 0, width: 200, height: 700)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 12, width: 76, height: 576))
    }

    func testFullyBlockedRailHasNoVisibleViewport() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 100),
            avoiding: [CGRect(x: 300, y: 0, width: 76, height: 150)], spacing: 12)
        XCTAssertEqual(frame.height, 0)
    }
}

final class GhosttyTerminalSafeAreaPolicyTests: XCTestCase {
    func testBottomControlsRestoreReservationWithoutLosingTopPolicy() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges(.bottom, hasBottomControls: true), [])
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges([.top, .bottom], hasBottomControls: true), .top)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges([.top, .bottom], hasBottomControls: false), [.top, .bottom])
    }

    func testInnerLandscapeAddsMissingTopBandWithoutDoublingInsets() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 0, bottomInset: 34), 34)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 34, bottomInset: 34), 0)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 0, bottomInset: 34), 0)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: true, isLandscape: false, topInset: 0, bottomInset: 34), 0)
    }

    func testOuterDisplayExtendsOnlyAtBottom() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: true, hasVerticalControls: true, isCompact: true, isLandscape: false), .bottom)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: true, isLandscape: false), .bottom)
    }
    func testInnerLandscapeExtendsAtBothEdges() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: true), [.top, .bottom])
    }
    func testInnerPortraitAndHorizontalControlsKeepSafeAreas() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: false), [])
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: false, isCompact: true, isLandscape: false), [])
    }
    func testEnabledSpacingPreservesAllEdges() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true), [])
    }
}

final class GhosttyWholeRowLayoutTests: XCTestCase {
    func testResizingControlsAlwaysUsesTheFinalAvailableArea() {
        // Hidden keyboard, visible keyboard, six growing Compose sizes, then
        // shrinking Compose and returning to the original available height.
        let heights: [CGFloat] = [790, 510, 488, 466, 444, 422, 400, 378, 444, 488, 510, 790]
        for scale: CGFloat in [2, 3] {
            for height in heights {
                let fitted = GhosttyWholeRowLayout.viewportHeight(availableHeight: height, cellPixelHeight: 47, scale: scale)
                let expectedRows = floor((height * scale).rounded() / 47)
                XCTAssertEqual((fitted * scale).rounded(), expectedRows * 47, accuracy: 0.001)
                XCTAssertLessThan(height - fitted, 47 / scale)
                XCTAssertGreaterThanOrEqual(height - fitted, 0)
            }
        }
    }

    func testTrimmingRemainderPreservesWholeRowCount() {
        for pixels in [1590, 1600, 1602, 1603] {
            let height = CGFloat(pixels) / 3
            let remainder = height - GhosttyWholeRowLayout.viewportHeight(availableHeight: height, cellPixelHeight: 48, scale: 3)
            XCTAssertEqual(floor((height * 3).rounded() / 48), floor(((height - remainder) * 3).rounded() / 48))
            XCTAssertEqual(((height - remainder) * 3).rounded().truncatingRemainder(dividingBy: 48), 0)
        }
    }
}

final class GhosttyTerminalControlsGeometryTests: XCTestCase {
    func testComposerGrowthAndSelectionKeepTopGapStable() {
        for windowHeight: CGFloat in [820, 510, 496] {
            for controlsHeight: CGFloat in [78, 99, 120, 141, 162, 183, 183, 120, 78] {
                let bounds = CGRect(x: 13, y: 21, width: 700, height: windowHeight)
                let frames = GhosttyTerminalControlsGeometry.frames(bounds: bounds, controlsHeight: controlsHeight,
                    cellPixelHeight: 47, scale: 3, centersControls: false)
                XCTAssertEqual(frames.controls.minY, frames.terminal.maxY, accuracy: 0.001)
                XCTAssertEqual(frames.controls.height, controlsHeight)
                XCTAssertLessThanOrEqual(frames.controls.maxY, bounds.maxY + 0.001)
                XCTAssertLessThan(bounds.maxY - frames.controls.maxY, 47 / 3)
                XCTAssertEqual((frames.terminal.height * 3).rounded().truncatingRemainder(dividingBy: 47), 0)
            }
        }
    }

    func testPillsAreCenteredInSpaceBelowTerminal() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 820)
        let frames = GhosttyTerminalControlsGeometry.frames(bounds: bounds, controlsHeight: 54,
            cellPixelHeight: 47, scale: 3, centersControls: true)
        XCTAssertEqual(frames.controls.minY - frames.terminal.maxY,
                       bounds.maxY - frames.controls.maxY, accuracy: 0.001)
    }
}
