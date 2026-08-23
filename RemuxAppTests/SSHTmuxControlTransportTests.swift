@preconcurrency import Citadel
import NIO
import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHTmuxControlTransportTests: XCTestCase {
    func testPasswordResolvedAuthFingerprintChangesWithSecret() {
        let first = ResolvedSSHAuth.password(
            username: "deploy",
            password: "first",
            identityID: UUID(),
            displayLabel: "deploy"
        )
        let second = ResolvedSSHAuth.password(
            username: "deploy",
            password: "second",
            identityID: UUID(),
            displayLabel: "deploy"
        )

        XCTAssertNotEqual(first.authFingerprint, second.authFingerprint)
    }

    func testPasswordResolvedAuthFingerprintDoesNotExposeSecret() {
        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "super-secret",
            identityID: UUID(),
            displayLabel: "deploy"
        )

        XCTAssertFalse(auth.authFingerprint.contains("super-secret"))
        XCTAssertTrue(auth.authFingerprint.hasPrefix("password:"))
    }

    func testPasswordResolvedAuthCarriesUsernameAndDisplayLabel() {
        let identityID = UUID()

        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "secret",
            identityID: identityID,
            displayLabel: "Work password"
        )

        XCTAssertEqual(auth.identityID, identityID)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testConfigurationStoresOptionalTraceFlowID() {
        let server = SavedServer(displayName: "Trace Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let defaultConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            sessionName: "base"
        )
        XCTAssertNil(defaultConfiguration.traceFlowID)
        XCTAssertEqual(defaultConfiguration.controlNoResponseTimeout, .seconds(15))
        XCTAssertEqual(defaultConfiguration.tmuxExecutable, "tmux")

        let tracedConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            connectTimeout: .seconds(10),
            controlNoResponseTimeout: .seconds(12),
            sessionName: "base",
            traceFlowID: "session.open.test"
        )
        XCTAssertEqual(tracedConfiguration.traceFlowID, "session.open.test")
        XCTAssertEqual(tracedConfiguration.connectTimeout, .seconds(10))
        XCTAssertEqual(tracedConfiguration.controlNoResponseTimeout, .seconds(12))
    }

    func testAppDependenciesTmuxConfigurationUsesSavedServerExecutable() {
        let executablePath = "/home/deploy/.local/share/mise/shims/tmux"
        let server = SavedServer(
            displayName: "Custom tmux",
            host: "example.com",
            username: "deploy",
            identityID: UUID(),
            tmuxExecutablePath: executablePath
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let target = TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: makePasswordAuth(server: server, password: "pw")
        )
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let configuration = RemuxAppDependencies.sshConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            traceFlowID: nil
        )

        XCTAssertEqual(configuration.tmuxExecutable, executablePath)
    }

    func testAppDependenciesUsesExtendedAuthenticationOnlyForTailscale() {
        let server = SavedServer(
            displayName: "Tailscale",
            host: "100.64.0.10",
            username: "deploy",
            identityID: UUID()
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let broker = TailscaleSSHCheckChallengeBroker()
        let tailscaleTarget = TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: .none(
                username: server.username,
                identityID: server.identityID,
                displayLabel: server.displayName
            )
        )
        let passwordTarget = TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: makePasswordAuth(server: server, password: "pw")
        )

        let tailscale = RemuxAppDependencies.sshConfiguration(
            for: tailscaleTarget,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: broker,
            traceFlowID: nil
        )
        let password = RemuxAppDependencies.sshConfiguration(
            for: passwordTarget,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: broker,
            traceFlowID: nil
        )

        XCTAssertEqual(tailscale.authenticationTimeout, .minutes(5))
        XCTAssertNotNil(tailscale.onTailscaleSSHCheck)
        XCTAssertNil(password.authenticationTimeout)
        XCTAssertNil(password.onTailscaleSSHCheck)
    }

    func testSFTPLeaseOpenTimeoutReturnsSuccessfulOperation() async throws {
        let value = try await RemuxSFTPTimeout.run(
            timeout: .seconds(1),
            operation: {
                42
            }
        )

        XCTAssertEqual(value, 42)
    }

    func testSFTPLeaseOpenTimeoutReturnsBeforeStalledOperationCompletes() async {
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await RemuxSFTPTimeout.run(
                timeout: .milliseconds(20),
                operation: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return 42
                }
            )
            XCTFail("expected SFTP lease open to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(elapsedMilliseconds, 1_000)
    }

    func testSFTPLeaseOpenTimeoutCleansLateSuccess() async throws {
        let recorder = LateSFTPOpenCleanupRecorder()

        do {
            _ = try await RemuxSFTPTimeout.run(
                timeout: .milliseconds(20),
                operation: {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return 42
                },
                cleanupLateSuccess: { value in
                    await recorder.record(value)
                }
            )
            XCTFail("expected SFTP lease open to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        let cleanedValues = await recorder.values()
        XCTAssertEqual(cleanedValues, [42])
    }

    func testSFTPTimeoutRunsInvalidationBeforeReturning() async {
        let recorder = SFTPTimeoutRecorder()

        do {
            _ = try await RemuxSFTPTimeout.run(
                timeout: .milliseconds(20),
                operation: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return 42
                },
                onTimeout: {
                    await recorder.recordInvalidation()
                }
            )
            XCTFail("expected SFTP operation to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let didInvalidate = await recorder.didInvalidate
        XCTAssertTrue(didInvalidate)
    }

    func testSFTPLeaseInvalidationReleasesRootOnceWithoutWaitingForHungChildClose() async throws {
        let recorder = SFTPLeaseTeardownRecorder()
        let teardown = RemuxSFTPLeaseTeardown(
            closeChild: {
                await recorder.closeChild()
            },
            releaseRoot: { disposition in
                await recorder.releaseRoot(disposition)
            }
        )
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await RemuxSFTPTimeout.run(
                timeout: .milliseconds(20),
                operation: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                onTimeout: {
                    await teardown.invalidate()
                }
            )
            XCTFail("expected SFTP operation to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - start
        ) / 1_000_000
        XCTAssertLessThan(elapsedMilliseconds, 1_000)

        await recorder.waitForChildCloseToStart()
        let isChildCloseFinished = await recorder.isChildCloseFinished
        XCTAssertFalse(isChildCloseFinished)

        try await teardown.close()
        await teardown.invalidate()
        try await teardown.close()

        let childCloseCount = await recorder.childCloseCount
        let rootDispositions = await recorder.rootDispositions
        XCTAssertEqual(childCloseCount, 1)
        XCTAssertEqual(rootDispositions, [.invalidated])

        await recorder.finishChildClose()
    }

    func testSFTPLeaseCloseTimeoutInvalidatesRootOnce() async throws {
        let recorder = SFTPLeaseTeardownRecorder()
        let teardown = RemuxSFTPLeaseTeardown(
            closeChild: {
                throw RemuxSFTPClientError.operationTimedOut
            },
            releaseRoot: { disposition in
                await recorder.releaseRoot(disposition)
            }
        )

        do {
            try await teardown.close()
            XCTFail("expected SFTP child close timeout")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        try await teardown.close()
        await teardown.invalidate()

        let rootDispositions = await recorder.rootDispositions
        XCTAssertEqual(rootDispositions, [.invalidated])
    }

    func testSFTPLeaseTeardownRejectsFollowUpWorkAfterInvalidation() async throws {
        let teardown = RemuxSFTPLeaseTeardown(
            closeChild: {},
            releaseRoot: { _ in }
        )

        try await teardown.checkActive()
        await teardown.invalidate()

        do {
            try await teardown.checkActive()
            XCTFail("expected invalidated SFTP lease to reject follow-up work")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSFTPLeaseTeardownReportsSessionShutdownReason() async {
        let teardown = RemuxSFTPLeaseTeardown(
            closeChild: {},
            releaseRoot: { _ in }
        )

        await teardown.invalidate(reason: .sessionUnavailable)

        do {
            try await teardown.checkActive()
            XCTFail("expected session shutdown to reject follow-up work")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .sessionUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSFTPTimeoutCancellationCleansLateSuccess() async throws {
        let recorder = LateSFTPOpenCleanupRecorder()
        let task = Task {
            try await RemuxSFTPTimeout.run(
                timeout: .seconds(5),
                operation: {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return 42
                },
                cleanupLateSuccess: { value in
                    await recorder.record(value)
                }
            )
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected SFTP operation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        let cleanedValues = await recorder.values()
        XCTAssertEqual(cleanedValues, [42])
    }

    func testSessionSFTPScopeUsesExactActivatedRootAndRejectsAfterClose() async throws {
        let rootChannel = EmbeddedChannel()
        let scope = RemuxSessionSFTPChildScope()

        try await scope.activate(rootChannel: rootChannel)
        let registration = try await scope.begin()

        XCTAssertTrue((registration.rootChannel as AnyObject) === rootChannel)

        await scope.finish(registration)
        let childDrain = await scope.close()
        XCTAssertEqual(childDrain, .clean)

        do {
            _ = try await scope.begin()
            XCTFail("expected a closed session scope to reject new SFTP children")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .sessionUnavailable)
        }
    }

    func testSessionSFTPScopeCloseWaitsForPendingChildOpen() async throws {
        let scope = RemuxSessionSFTPChildScope()
        try await scope.activate(rootChannel: EmbeddedChannel())
        let pending = try await scope.begin()
        let recorder = SessionSFTPScopeRecorder()

        let closeTask = Task {
            _ = await scope.close()
            await recorder.recordClosed()
        }
        try await Task.sleep(for: .milliseconds(20))
        let didCloseWhileChildWasPending = await recorder.didClose
        XCTAssertFalse(didCloseWhileChildWasPending)

        await scope.finish(pending)
        await closeTask.value

        let didCloseAfterChildFinished = await recorder.didClose
        XCTAssertTrue(didCloseAfterChildFinished)
    }

    func testSessionSFTPScopeClosesChildrenBeforeDraining() async throws {
        let scope = RemuxSessionSFTPChildScope()
        try await scope.activate(rootChannel: EmbeddedChannel())
        let registration = try await scope.begin()
        let recorder = SessionSFTPScopeRecorder()
        let teardown = RemuxSFTPLeaseTeardown(
            closeBorrowedChild: {
                await recorder.recordChildClose()
            }
        )

        let didRegister = await scope.register(teardown, for: registration)
        XCTAssertTrue(didRegister)
        let childDrain = await scope.close()

        let childCloseCount = await recorder.childCloseCount
        XCTAssertEqual(childCloseCount, 1)
        XCTAssertEqual(childDrain, .clean)
    }

    func testSessionSFTPScopeDirtyChildRetiresRootOnce() async throws {
        enum ChildCloseFailure: Error {
            case failed
        }

        let scope = RemuxSessionSFTPChildScope()
        let recorder = SessionSFTPScopeRecorder()
        try await scope.activate(
            rootChannel: EmbeddedChannel(),
            invalidateRootForReuse: {
                await recorder.recordRootInvalidation()
            }
        )
        let registration = try await scope.begin()
        let teardown = RemuxSFTPLeaseTeardown(
            closeBorrowedChild: {
                throw ChildCloseFailure.failed
            }
        )

        let didRegister = await scope.register(teardown, for: registration)
        XCTAssertTrue(didRegister)

        let firstDrain = await scope.close()
        let secondDrain = await scope.close()

        XCTAssertEqual(firstDrain, .dirty)
        XCTAssertEqual(secondDrain, .dirty)
        let rootInvalidationCount = await recorder.rootInvalidationCount
        XCTAssertEqual(rootInvalidationCount, 1)
    }

    func testSessionSFTPScopeCannotBeReactivated() async throws {
        let scope = RemuxSessionSFTPChildScope()
        try await scope.activate(rootChannel: EmbeddedChannel())

        do {
            try await scope.activate(rootChannel: EmbeddedChannel())
            XCTFail("expected a session SFTP scope to bind only once")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .sessionUnavailable)
        }

        _ = await scope.close()
    }

    func testSessionScopeActivationFailureDuringCloseIsAClosedStart() {
        XCTAssertTrue(
            SSHTmuxControlTransport.startWasInterruptedByClose(
                RemuxSFTPClientError.sessionUnavailable,
                transportWasClosed: true
            )
        )
        XCTAssertFalse(
            SSHTmuxControlTransport.startWasInterruptedByClose(
                RemuxSFTPClientError.sessionUnavailable,
                transportWasClosed: false
            )
        )
        XCTAssertFalse(
            SSHTmuxControlTransport.startWasInterruptedByClose(
                RemuxSFTPClientError.operationTimedOut,
                transportWasClosed: true
            )
        )
    }

    func testDirectTCPIPTargetBuildsNIOSSHChannelType() throws {
        let target = try RemuxSSHDirectTCPIPTarget(
            host: "127.0.0.1",
            port: 8_080
        )
        let originatorAddress = try SocketAddress(
            ipAddress: "127.0.0.1",
            port: 49_152
        )

        XCTAssertEqual(
            target.channelType(originatorAddress: originatorAddress),
            .directTCPIP(.init(
                targetHost: "127.0.0.1",
                targetPort: 8_080,
                originatorAddress: originatorAddress
            ))
        )
    }

    func testDirectTCPIPTargetRejectsEmptyHost() {
        XCTAssertThrowsError(
            try RemuxSSHDirectTCPIPTarget(host: "", port: 80)
        ) { error in
            XCTAssertEqual(error as? RemuxSSHDirectTCPIPTargetError, .invalidHost)
        }
    }

    func testDirectTCPIPTargetRejectsPortsOutsideUInt16Range() {
        for port in [-1, 0, Int(UInt16.max) + 1] {
            XCTAssertThrowsError(
                try RemuxSSHDirectTCPIPTarget(host: "localhost", port: port)
            ) { error in
                XCTAssertEqual(
                    error as? RemuxSSHDirectTCPIPTargetError,
                    .invalidPort(port)
                )
            }
        }
    }

    func testSSHRootServiceKeyIsServerAndCredentialScoped() {
        let server = SavedServer(
            displayName: "Build Host",
            host: "server.example.com",
            username: "tester"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")

        let baseTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            sshAuth: makePasswordAuth(server: server, password: "test-password")
        )
        let logsTarget = TmuxConnectionTarget(
            server: server,
            workspace: logs,
            sshAuth: makePasswordAuth(server: server, password: "test-password")
        )
        let changedPasswordTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            sshAuth: makePasswordAuth(server: server, password: "other-test-password")
        )
        let changedSavedUserPreservedAuthTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester",
                identityID: server.identityID
            ),
            workspace: base,
            sshAuth: baseTarget.sshAuth
        )
        let changedAuthUserTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester",
                identityID: server.identityID
            ),
            workspace: base,
            sshAuth: makePasswordAuth(
                server: server,
                username: "other-tester",
                password: "test-password"
            )
        )

        XCTAssertEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: logsTarget)
        )
        XCTAssertNotEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedPasswordTarget)
        )
        XCTAssertEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedSavedUserPreservedAuthTarget)
        )
        XCTAssertNotEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedAuthUserTarget)
        )
    }

    func testSSHRootServiceReusableReleaseKeepsRootIdleReusable() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceInvalidatedReleaseRemovesRoot() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testSSHRootServiceLeaseCancelsIdleCloseAndIncrementsActiveCount() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 0,
            idleCloseScheduled: true
        )
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceSecondReservationSharesRoot() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)

        // SSH multiplexes session channels over one authenticated
        // connection: concurrent opens to the same server share the
        // root (and its in-flight authentication) instead of paying
        // a full TCP + auth handshake each.
        let first = await pool.reserveEntryForTesting(for: key)
        let second = await pool.reserveEntryForTesting(for: key)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.reservationCount, 2)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceCapacityBoundsSharedRoot() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        _ = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: RemuxSSHRootService.maxConcurrentLeases - 1
        )

        // One slot left: a reservation takes it, the next must fall
        // back to a dedicated connection (nil = pool refuses).
        let last = await pool.reserveEntryForTesting(for: key)
        XCTAssertNotNil(last)
        let overflow = await pool.reserveEntryForTesting(for: key)
        XCTAssertNil(overflow)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceClaimRequiresMatchingReservation() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        do {
            try await pool.leaseEntryForTesting(
                for: key,
                generation: generation,
                reservationID: UUID()
            )
            XCTFail("expected stale reservation to fail")
        } catch let error as RemuxSSHRootServiceError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 1)
        XCTAssertEqual(entry?.activeLeaseCount, 0)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceReleasedReservationReturnsRootToIdle() async throws {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        await pool.releaseReservationForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceReusableReleasesMultipleLeasesIndependently() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceInvalidationRetiresSharedRootUntilLastLease() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        // One session invalidates: the root leaves the pool (no new
        // leases) but must NOT close under the sibling still using it.
        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        var snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 1)

        // The sibling's release drains the retired root.
        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )
        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceChildFailureRetiresRootWithoutConsumingLiveLease() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2,
            reservationID: UUID()
        )

        await pool.invalidateForReuseForTesting(
            for: key,
            generation: generation
        )

        var snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 1)
        let replacementReservation = await pool.reserveEntryForTesting(for: key)
        XCTAssertNil(replacementReservation)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )
        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 1)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )
        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceStaleReservationDoesNotOwnRetiredSharedRootClose() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let reservationID = UUID()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2,
            reservationID: reservationID
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        var snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 1)

        let retiredStaleReservationOwnsClose = await pool.staleLeaseShouldCloseConnectionForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )
        XCTAssertEqual(retiredStaleReservationOwnsClose, false)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceStaleReservationForUnknownRootOwnsClose() async {
        let pool = RemuxSSHRootService()

        let unknownStaleReservationOwnsClose = await pool.staleLeaseShouldCloseConnectionForTesting(
            for: makeSSHRootKey(),
            generation: UUID(),
            reservationID: UUID()
        )
        XCTAssertEqual(unknownStaleReservationOwnsClose, true)
    }

    func testSSHRootServiceCloseIdleConnectionsPreservesActiveEntries() async {
        let pool = RemuxSSHRootService()
        let serverID = UUID()
        let idleKey = makeSSHRootKey(
            serverID: serverID,
            host: "idle.example.com"
        )
        let reservedKey = makeSSHRootKey(
            serverID: serverID,
            host: "reserved.example.com"
        )
        let activeKey = makeSSHRootKey(
            serverID: serverID,
            host: "active.example.com"
        )
        let otherServerKey = makeSSHRootKey(
            serverID: UUID(),
            host: "other.example.com"
        )
        await pool.insertEntryForTesting(for: idleKey, activeLeaseCount: 0)
        await pool.insertEntryForTesting(
            for: reservedKey,
            activeLeaseCount: 0,
            reservationID: UUID()
        )
        await pool.insertEntryForTesting(for: activeKey, activeLeaseCount: 1)
        await pool.insertEntryForTesting(for: otherServerKey, activeLeaseCount: 0)

        await pool.closeIdleConnections(forServerID: serverID)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: idleKey))
        XCTAssertNotNil(snapshot.entry(for: reservedKey))
        XCTAssertNotNil(snapshot.entry(for: activeKey))
        XCTAssertNotNil(snapshot.entry(for: otherServerKey))
        XCTAssertEqual(snapshot.entryCount, 3)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceTestingCleanupEvictsAllEntries() async {
        let pool = RemuxSSHRootService()
        await pool.insertEntryForTesting(
            for: makeSSHRootKey(host: "first.example.com")
        )
        await pool.insertEntryForTesting(
            for: makeSSHRootKey(host: "second.example.com")
        )

        await pool.closeAllConnectionsForTesting()

        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testSSHRootServiceAuthenticationFailureRemovesEntry() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            idleCloseScheduled: true
        )

        await pool.markAuthenticationFailedForTesting(for: key, generation: generation)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
    }

    func testSSHRootServiceAuthenticationSuccessMarksReadyAndSchedulesIdleClose() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceAuthenticationSuccessKeepsReservedEntryOpen() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let reservationID = UUID()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0,
            reservationID: reservationID
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        _ = reservationID
        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.reservationCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnectionsForTesting()
    }

    func testSSHRootServiceClosedIdleRootIsEvicted() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)

        await pool.markRootChannelClosedForTesting(for: key, generation: generation)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceClosedActiveRootRetiresUntilLeaseReleases() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.markRootChannelClosedForTesting(for: key, generation: generation)

        var snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 1)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceGenerationMismatchDoesNotMutateCurrentEntry() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1,
            idleCloseScheduled: false
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: UUID(),
            disposition: .invalidated
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnectionsForTesting()
    }

    func testInboundStreamYieldsBytesInCallOrder() async throws {
        let stream = SSHTmuxControlInboundStream()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)

        stream.yield(first)
        stream.yield(second)
        stream.yield(third)
        stream.finish(nil)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let receivedFirst = try await iterator.next()
        let receivedSecond = try await iterator.next()
        let receivedThird = try await iterator.next()
        let end = try await iterator.next()

        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)
        XCTAssertEqual(receivedThird, third)
        XCTAssertNil(end)
    }

    func testInboundStreamIgnoresYieldsAfterFinish() async throws {
        let stream = SSHTmuxControlInboundStream()

        stream.finish(nil)
        stream.yield(Data("late".utf8))

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let end = try await iterator.next()

        XCTAssertNil(end)
    }

    func testInboundStreamFinishesWithFirstError() async {
        enum Failure: Error, Equatable {
            case first
            case second
        }

        let stream = SSHTmuxControlInboundStream()

        stream.finish(Failure.first)
        stream.finish(Failure.second)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected first finish error")
        } catch let error as Failure {
            XCTAssertEqual(error, .first)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testChannelRequestFailureDescriptionNamesRejectedRequest() {
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
    }

    func testChannelDataRouterForwardsOnlyStdoutAsControlOutput() {
        let router = SSHTmuxControlChannelDataRouter()
        let first = Data("%begin 1 0\\n".utf8)
        let second = Data("%end 1 0\\n".utf8)

        XCTAssertEqual(
            router.route(type: .channel, data: first),
            .stdout(reportFirstOutput: true)
        )
        XCTAssertEqual(
            router.route(type: .channel, data: second),
            .stdout(reportFirstOutput: false)
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, first.count + second.count)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
    }

    func testChannelDataRouterCapturesStderrWithoutControlOutput() {
        let router = SSHTmuxControlChannelDataRouter()
        let stderr = Data("tmux: no server running\\n".utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, stderr.count)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
        XCTAssertTrue(diagnostics?.stderrPreview?.contains("tmux: no server running") == true)
    }

    func testChannelDataRouterCapturesUnknownExtendedDataWithoutControlOutput() {
        let router = SSHTmuxControlChannelDataRouter()
        let extended = Data("extended diagnostic\\n".utf8)

        XCTAssertEqual(
            router.route(type: SSHChannelData.DataType(extended: 2), data: extended),
            .extendedData
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, extended.count)
        XCTAssertTrue(diagnostics?.extendedDataPreview?.contains("extended diagnostic") == true)
    }

    func testStartupDiagnosticsBoundsStderrPreview() {
        let router = SSHTmuxControlChannelDataRouter()
        let stderr = Data(String(repeating: "x", count: 500).utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stderrByteCount, 500)
        XCTAssertLessThanOrEqual(diagnostics?.stderrPreview?.count ?? 0, 260)
    }

    func testTransportFailureDescriptionIncludesBoundedDiagnosticsWhenPresent() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )

        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.remoteExit(1)),
            "remoteExit(1)"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stderr_preview=\"tmux failed\"")
        )
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec, diagnostics: diagnostics))
                .contains("stderr_bytes=18")
        )
        XCTAssertFalse(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stdout_preview")
        )
    }

    func testChannelCompletionReportsRemoteExitWithDiagnosticsOnClose() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 12,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        let completionState = SSHTmuxControlChannelCompletionState()

        completionState.recordExitStatus(1)

        let completion = completionState.finish(nil, diagnostics: diagnostics)
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport remote exit failure")
            return
        }

        XCTAssertEqual(
            String(describing: error),
            "remoteExit(1) stdout_bytes=12 stderr_bytes=18 extended_bytes=0 stderr_preview=\"tmux failed\""
        )
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testChannelCompletionKeepsRequestRejectionAsImmediateFailure() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        let completionState = SSHTmuxControlChannelCompletionState()

        let completion = completionState.finish(
            RemuxSSHExecSessionError.requestFailed,
            diagnostics: diagnostics
        )
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport request failure")
            return
        }

        XCTAssertEqual(
            error,
            SSHTmuxControlTransportError.channelRequestFailed(
                .exec,
                diagnostics: diagnostics
            )
        )
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testFirstOutputGateKeepsEarlyFailure() throws {
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let gate = SSHTmuxControlFirstOutputGate(promise: promise)
        let failure = SSHTmuxControlTransportError.remoteExit(1)

        gate.fail(failure)
        gate.succeed()

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? SSHTmuxControlTransportError, failure)
        }
    }

    func testFirstOutputGateIgnoresFinishAfterFirstOutput() throws {
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let gate = SSHTmuxControlFirstOutputGate(promise: promise)

        gate.succeed()
        gate.fail(SSHTmuxControlTransportError.remoteExit(1))

        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testControlSessionCommandDelegatesStartupToPOSIXShell() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "tmux",
            sessionName: "base",
            initialViewport: TmuxControlViewport(
                columns: 45,
                rows: 37,
                pixelWidth: 1_190,
                pixelHeight: 2_162
            )
        )

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains(#"PATH="${PATH:+$PATH:}/opt/homebrew/bin"#))
        XCTAssertTrue(command.contains(#"exec "$resolved" -u -C new-session -A"#))
        XCTAssertTrue(command.hasSuffix(" 45 37"))
    }

    func testControlSessionCommandKeepsValuesOutOfLoginShellSyntax() {
        let tmuxExecutable = "/home/owner's tools/tmux"
        let sessionName = "owner's bäse! back\\slash"
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: tmuxExecutable,
            sessionName: sessionName,
            initialViewport: TmuxControlViewport(
                columns: 120,
                rows: 40,
                pixelWidth: 0,
                pixelHeight: 0
            )
        )

        XCTAssertFalse(command.contains(tmuxExecutable))
        XCTAssertFalse(command.contains(sessionName))
        XCTAssertFalse(command.contains("\n"))
        XCTAssertFalse(command.contains("!"))
        XCTAssertTrue(command.hasSuffix(" 120 40"))
    }

    func testSendAfterCloseFailsInsteadOfQueueingBytes() async {
        let server = SavedServer(displayName: "Closed Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let transport = SSHTmuxControlTransport(
            configuration: SSHTmuxControlConfiguration(
                host: server.host,
                authenticationMethod: {
                    .passwordBased(username: server.username, password: "pw")
                },
                hostKeyValidator: trustedHostStore.validator(for: server),
                sessionName: "base"
            )
        )

        await transport.close(disposition: .reusable)

        do {
            try await transport.send(Data("opaque outbound bytes".utf8))
            XCTFail("expected closed transport failure")
        } catch let error as SSHTmuxControlTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeSSHRootKey(
        serverID: SavedServer.ID = UUID(),
        host: String = "server.example.com",
        port: Int = 22,
        username: String = "tester",
        password: String = "pw"
    ) -> RemuxSSHRootKey {
        let server = SavedServer(
            id: serverID,
            displayName: host,
            host: host,
            port: port,
            username: username
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        return RemuxSSHRootKey(
            target: TmuxConnectionTarget(
                server: server,
                workspace: workspace,
                sshAuth: makePasswordAuth(
                    server: server,
                    username: username,
                    password: password
                )
            )
        )
    }

    private func makePasswordAuth(
        server: SavedServer,
        username: String? = nil,
        password: String
    ) -> ResolvedSSHAuth {
        .password(
            username: username ?? server.username,
            password: password,
            identityID: server.identityID,
            displayLabel: server.displayName
        )
    }
}

private actor LateSFTPOpenCleanupRecorder {
    private var recordedValues: [Int] = []

    func record(_ value: Int) {
        recordedValues.append(value)
    }

    func values() -> [Int] {
        recordedValues
    }
}

private actor SFTPTimeoutRecorder {
    private(set) var didInvalidate = false

    func recordInvalidation() {
        didInvalidate = true
    }
}

private actor SessionSFTPScopeRecorder {
    private(set) var didClose = false
    private(set) var childCloseCount = 0
    private(set) var rootInvalidationCount = 0

    func recordClosed() {
        didClose = true
    }

    func recordChildClose() {
        childCloseCount += 1
    }

    func recordRootInvalidation() {
        rootInvalidationCount += 1
    }
}

private actor SFTPLeaseTeardownRecorder {
    private(set) var childCloseCount = 0
    private(set) var isChildCloseFinished = false
    private(set) var rootDispositions: [RemuxSSHRootLeaseDisposition] = []
    private var childCloseContinuation: CheckedContinuation<Void, Never>?
    private var childCloseStartWaiters: [CheckedContinuation<Void, Never>] = []

    func closeChild() async {
        childCloseCount += 1
        let waiters = childCloseStartWaiters
        childCloseStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            childCloseContinuation = continuation
        }
        isChildCloseFinished = true
    }

    func waitForChildCloseToStart() async {
        guard childCloseCount == 0 else { return }
        await withCheckedContinuation { continuation in
            childCloseStartWaiters.append(continuation)
        }
    }

    func releaseRoot(_ disposition: RemuxSSHRootLeaseDisposition) {
        rootDispositions.append(disposition)
    }

    func finishChildClose() {
        childCloseContinuation?.resume()
        childCloseContinuation = nil
    }
}
