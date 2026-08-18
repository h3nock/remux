import Foundation
import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxScreenModelForegroundActiveCheckTests: XCTestCase {
    func testInitialConnectWaitsForMeasuredViewport() async throws {
        let target = makeTarget()
        let transport = ForegroundInactiveTransport(isActive: true)
        var transportFactoryCallCount = 0
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: UUID(),
            transportFactory: { _ in
                transportFactoryCallCount += 1
                return transport
            },
            onRuntimeStateChange: { _ in }
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        XCTAssertEqual(transportFactoryCallCount, 1)
        try await Task.sleep(for: .milliseconds(80))
        let didStartBeforeViewport = await transport.didStart()
        XCTAssertFalse(didStartBeforeViewport)

        model.terminalScreenAdapter.prepareInitialViewport(
            size: CGSize(width: 420, height: 756),
            scale: 3
        )

        try await waitUntil("transport did not start after viewport report") {
            await transport.didStart()
        }
        let viewport = await transport.startedViewport()
        XCTAssertNotNil(viewport)
        XCTAssertNotEqual(viewport, .default)
        XCTAssertEqual(viewport?.pixelWidth, 1260)
        XCTAssertEqual(viewport?.pixelHeight, 2268)
        let measuredViewport = try XCTUnwrap(viewport)
        let measuredSize = TmuxSessionController.ClientSize(
            cols: UInt32(measuredViewport.columns),
            rows: UInt32(measuredViewport.rows)
        )
        XCTAssertEqual(model.carriedClientSize, measuredSize)
        XCTAssertFalse(
            model.submitClientSizeIfChanged(measuredSize),
            "the measured pre-connect grid must seed the screen-model authority"
        )
        await model.stop()
    }

    func testStopBeforeViewportClosesClaimedTransportExactlyOnce() async throws {
        let transport = ForegroundInactiveTransport(isActive: true)
        var transportFactoryCallCount = 0
        let model = TmuxScreenModel(
            target: makeTarget(),
            sessionInstanceID: UUID(),
            transportFactory: { _ in
                transportFactoryCallCount += 1
                return transport
            },
            onRuntimeStateChange: { _ in }
        )

        XCTAssertEqual(transportFactoryCallCount, 1)
        let didStart = await transport.didStart()
        XCTAssertFalse(didStart)

        await model.stop()
        await model.stop()

        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.reusable])
    }

    func testScreenModelRejectsRepeatedGridUnlessViewportClaimRequested() async throws {
        let transport = ForegroundInactiveTransport(isActive: true)
        let model = TmuxScreenModel(
            target: makeTarget(),
            sessionInstanceID: UUID(),
            transportFactory: { _ in transport },
            onRuntimeStateChange: { _ in },
            initialClientSize: Self.initialClientSize
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        XCTAssertEqual(model.carriedClientSize, Self.initialClientSize)
        XCTAssertFalse(model.submitClientSizeIfChanged(Self.initialClientSize))
        XCTAssertTrue(model.submitClientSizeIfChanged(
            Self.initialClientSize,
            claimActiveViewport: true
        ))
        XCTAssertEqual(model.carriedClientSize, Self.initialClientSize)

        let changed = TmuxSessionController.ClientSize(cols: 52, rows: 31)
        XCTAssertTrue(model.submitClientSizeIfChanged(changed))
        XCTAssertEqual(model.carriedClientSize, changed)

        await model.stop()
    }

    func testForegroundInvalidatesInactiveTransportAndReportsForegroundDisconnect() async throws {
        let target = makeTarget()
        let instanceID = UUID()
        let transport = ForegroundInactiveTransport(isActive: false)
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: instanceID,
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) },
            initialClientSize: Self.initialClientSize
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        model.session?.handleStateForTesting(.ready)
        updates.removeAll()

        model.handleAppLifecyclePhase(.active)

        try await waitUntil("inactive foreground transport was not invalidated") {
            await transport.closeDispositions().contains(.invalidated)
        }
        try await waitUntil("foreground disconnect was not reported") {
            updates.contains {
                $0.workspaceID == target.workspace.id
                    && $0.instanceID == instanceID
                    && $0.source == .foreground
                    && $0.state.disconnectedReason == GhosttyTerminalDisconnectReasonClassifier
                        .foregroundMissingHost()
            }
        }
        await model.stop()
    }

    func testForegroundDoesNotProbeTransportWhileSessionIsStillConnecting() async throws {
        let target = makeTarget()
        let transport = ForegroundInactiveTransport(isActive: false)
        var updates: [TerminalRuntimeStateUpdate] = []
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: UUID(),
            transportFactory: { _ in transport },
            onRuntimeStateChange: { updates.append($0) },
            initialClientSize: Self.initialClientSize
        )
        defer {
            Task { @MainActor in
                await model.stop()
            }
        }

        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        try await waitUntil("session did not enter a connecting state") {
            guard let state = model.session?.state else { return false }
            switch state {
            case .attaching, .syncing:
                return true
            case .detached, .ready, .closed:
                return false
            }
        }
        updates.removeAll()

        model.handleAppLifecyclePhase(.active)
        try await Task.sleep(for: .milliseconds(80))

        let activeCheckCount = await transport.activeCheckCount()
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(activeCheckCount, 0)
        XCTAssertTrue(closeDispositions.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0.source != .foreground })
        await model.stop()
    }

    func testStaleForegroundProbeDoesNotInvalidateStoppedLink() async throws {
        let runtime = try GhosttyKitRuntime()
        let transport = ForegroundSuspendingTransport(isActiveAfterResume: false)
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: transport,
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, _, _, _, _, _, completion in
                completion(.failure(.surfaceCreationFailed(
                    GHOSTTY_TERMINAL_SURFACE_RESULT_INVALID_INPUT
                )))
            }
        )
        defer {
            Task { @MainActor in
                await session.shutdown()
            }
        }

        session.connect(viewport: .default)
        try await waitUntil("transport did not start") {
            await transport.didStart()
        }
        session.handleStateForTesting(.ready)

        var invalidatedReasons: [TerminalDisconnectReason] = []
        let probe = Task { @MainActor in
            await session.invalidateInactiveTransportOnForeground { reason in
                invalidatedReasons.append(reason)
            }
        }
        try await waitUntil("transport was not probed") {
            await transport.activeCheckCount() == 1
        }

        await session.disconnect()
        await transport.resumeActiveCheck()
        let reason = await probe.value
        let closeDispositions = await transport.closeDispositions()

        XCTAssertNil(reason)
        XCTAssertTrue(invalidatedReasons.isEmpty)
        XCTAssertEqual(closeDispositions, [.reusable])
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }

    private func makeTarget() -> TmuxConnectionTarget {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        return TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: .password(
                username: server.username,
                password: "secret",
                identityID: server.identityID,
                displayLabel: server.displayName
            )
        )
    }

    private static let initialClientSize = TmuxSessionController.ClientSize(
        cols: 47,
        rows: 38
    )
}

private actor ForegroundInactiveTransport: TmuxControlTransport, TmuxControlTransportLivenessChecking {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let isActive: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var started = false
    private var recordedInitialViewport: TmuxControlViewport?
    private var recordedActiveCheckCount = 0
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init(isActive: Bool) {
        self.isActive = isActive

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        recordedInitialViewport = initialViewport
        started = true
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func isControlChannelActive() async -> Bool {
        recordedActiveCheckCount += 1
        return isActive
    }

    func didStart() -> Bool {
        started
    }

    func startedViewport() -> TmuxControlViewport? {
        recordedInitialViewport
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }

    func activeCheckCount() -> Int {
        recordedActiveCheckCount
    }
}

private actor ForegroundSuspendingTransport: TmuxControlTransport, TmuxControlTransportLivenessChecking {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let isActiveAfterResume: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var activeCheckContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var recordedActiveCheckCount = 0
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []

    init(isActiveAfterResume: Bool) {
        self.isActiveAfterResume = isActiveAfterResume

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        started = true
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func isControlChannelActive() async -> Bool {
        recordedActiveCheckCount += 1
        await withCheckedContinuation { continuation in
            activeCheckContinuation = continuation
        }
        return isActiveAfterResume
    }

    func resumeActiveCheck() {
        activeCheckContinuation?.resume()
        activeCheckContinuation = nil
    }

    func didStart() -> Bool {
        started
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }

    func activeCheckCount() -> Int {
        recordedActiveCheckCount
    }
}
