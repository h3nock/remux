import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class RemuxSSHExecSessionTests: XCTestCase {
    func testRoutesStdoutAndStderrSeparately() throws {
        let dataRecorder = RemuxSSHExecDataRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { type, data in
                dataRecorder.record(type: type, data: data)
            },
            onFinish: { _, _ in }
        )
        let channel = EmbeddedChannel(handler: handler)

        _ = try channel.writeInbound(sshData(type: .channel, string: "stdout"))
        _ = try channel.writeInbound(sshData(type: .stdErr, string: "stderr"))

        XCTAssertEqual(dataRecorder.stdout, Data("stdout".utf8))
        XCTAssertEqual(dataRecorder.stderr, Data("stderr".utf8))
        XCTAssertNoThrow(try channel.finish())
    }

    func testExecRequestFailureCompletesWithRequestFailed() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handler: handler)
        handler.expectExecReply()

        channel.pipeline.fireUserInboundEventTriggered(NIOSSH.ChannelFailureEvent())

        XCTAssertEqual(completionRecorder.finishCount, 1)
        XCTAssertNil(completionRecorder.exitStatus)
        XCTAssertEqual(completionRecorder.error, .requestFailed)
        XCTAssertNoThrow(try channel.finish())
    }

    func testFailureWithoutPendingExecReplyContinuesThroughPipeline() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let eventRecorder = RemuxSSHExecUserEventRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handlers: [handler, eventRecorder])

        channel.pipeline.fireUserInboundEventTriggered(NIOSSH.ChannelFailureEvent())

        XCTAssertEqual(completionRecorder.finishCount, 0)
        XCTAssertEqual(eventRecorder.failureCount, 1)
        XCTAssertNoThrow(try channel.finish())
    }

    func testFiniteResultRequiresExitStatus() async {
        let collector = RemuxSSHExecResultCollector()

        collector.finish(exitStatus: nil, error: nil)

        do {
            _ = try await collector.value()
            XCTFail("expected missing exit status")
        } catch let error as RemuxSSHExecSessionError {
            XCTAssertEqual(error, .missingExitStatus)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFiniteResultReturnsZeroStatusAndCapturedStreams() async throws {
        let collector = RemuxSSHExecResultCollector()
        let stdout = Data("installed\n".utf8)
        let stderr = Data("diagnostic\n".utf8)

        collector.receive(type: .channel, data: stdout)
        collector.receive(type: .stdErr, data: stderr)
        collector.finish(exitStatus: 0, error: nil)

        let result = try await collector.value()
        XCTAssertEqual(
            result,
            RemuxSSHExecResult(
                exitStatus: 0,
                stdout: stdout,
                stderr: stderr
            )
        )
    }

    func testFiniteResultRejectsMoreThanSixtyFourKiBPerStream() async {
        let limit = 64 * 1024
        let stdoutCollector = RemuxSSHExecResultCollector()
        stdoutCollector.receive(type: .stdErr, data: Data(repeating: 1, count: limit))
        stdoutCollector.receive(type: .channel, data: Data(repeating: 2, count: limit + 1))

        await assertOutputTooLarge(stdoutCollector)

        let stderrCollector = RemuxSSHExecResultCollector()
        stderrCollector.receive(type: .channel, data: Data(repeating: 3, count: limit))
        stderrCollector.receive(type: .stdErr, data: Data(repeating: 4, count: limit + 1))

        await assertOutputTooLarge(stderrCollector)
    }

    func testFinishInputClosesOnlyChannelOutput() async throws {
        let outboundRecorder = RemuxSSHExecOutboundRecorder()
        let channel = EmbeddedChannel(handler: outboundRecorder)
        let connection = RemuxSSHExecConnection(
            sessionChannel: channel,
            releaseRoot: { _ in }
        )
        let publicKey = Data("ssh-ed25519 AAAA test@example\n".utf8)

        try await connection.write(publicKey)
        try await connection.finishInput()

        XCTAssertEqual(
            outboundRecorder.events,
            [
                .write(publicKey),
                .closeOutput,
            ]
        )
        _ = try channel.readOutbound(as: SSHChannelData.self)
        XCTAssertThrowsError(try channel.finish())
    }

    func testFiniteCompletionClosesChannelForExitStatusThenRemoteEOF() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let outboundRecorder = RemuxSSHExecOutboundRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handlers: [outboundRecorder, handler])

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.ExitStatus(exitStatus: 0)
        )
        XCTAssertEqual(completionRecorder.finishCount, 0)
        XCTAssertEqual(outboundRecorder.events, [])

        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(completionRecorder.finishCount, 1)
        XCTAssertEqual(completionRecorder.exitStatus, 0)
        XCTAssertFalse(completionRecorder.hasError)
        XCTAssertEqual(outboundRecorder.events, [.closeAll])
        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }
        XCTAssertEqual(completionRecorder.finishCount, 1)
    }

    func testFiniteCompletionClosesChannelForRemoteEOFThenExitStatus() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let outboundRecorder = RemuxSSHExecOutboundRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handlers: [outboundRecorder, handler])

        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertEqual(completionRecorder.finishCount, 0)
        XCTAssertEqual(outboundRecorder.events, [])

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.ExitStatus(exitStatus: 23)
        )
        channel.embeddedEventLoop.run()

        XCTAssertEqual(completionRecorder.finishCount, 1)
        XCTAssertEqual(completionRecorder.exitStatus, 23)
        XCTAssertFalse(completionRecorder.hasError)
        XCTAssertEqual(outboundRecorder.events, [.closeAll])
        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }
        XCTAssertEqual(completionRecorder.finishCount, 1)
    }

    func testLongLivedCompletionWaitsForFullCloseAfterExitStatusAndEOF() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let outboundRecorder = RemuxSSHExecOutboundRecorder()
        let handler = RemuxSSHExecChannelHandler(
            closeOnRemoteEOFAndExitStatus: false,
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handlers: [outboundRecorder, handler])

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.ExitStatus(exitStatus: 0)
        )
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(completionRecorder.finishCount, 0)
        XCTAssertEqual(outboundRecorder.events, [])

        XCTAssertNoThrow(try channel.finish())
        XCTAssertEqual(completionRecorder.finishCount, 1)
        XCTAssertEqual(completionRecorder.exitStatus, 0)
        XCTAssertFalse(completionRecorder.hasError)
    }

    func testCompletionFiresExactlyOnceForErrorThenClose() throws {
        let completionRecorder = RemuxSSHExecCompletionRecorder()
        let handler = RemuxSSHExecChannelHandler(
            onData: { _, _ in },
            onFinish: { exitStatus, error in
                completionRecorder.record(exitStatus: exitStatus, error: error)
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.fireErrorCaught(RemuxSSHExecTestError.failed)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(completionRecorder.finishCount, 1)
        XCTAssertTrue(completionRecorder.hasError)
        XCTAssertThrowsError(try channel.finish())
        XCTAssertEqual(completionRecorder.finishCount, 1)
    }

    func testPublicOpenCancellationDuringSuspendedOpenThrowsAfterInvalidation() async {
        let suspension = RemuxSSHExecTestSuspension()
        let releaseRecorder = RemuxSSHExecReleaseRecorder()
        let connectionCleanupRecorder = RemuxSSHExecReleaseRecorder()
        let lifetime = RemuxSSHExecLifetimeOwner { disposition in
            await releaseRecorder.record(disposition)
        }

        let operation = Task { () -> Error? in
            do {
                _ = try await RemuxSSHExecSession.open(lifetime: lifetime) {
                    await suspension.wait()
                    lifetime.installConnectionCleanup { disposition in
                        await connectionCleanupRecorder.record(disposition)
                    }
                }
                return nil
            } catch {
                return error
            }
        }

        await suspension.waitUntilSuspended()
        operation.cancel()
        await releaseRecorder.waitForRelease()

        let cancellationDispositions = await releaseRecorder.dispositions()
        XCTAssertEqual(cancellationDispositions, [.invalidated])

        await suspension.resume()
        let error = await operation.value

        XCTAssertTrue(error is CancellationError)
        let connectionCleanupDispositions = await connectionCleanupRecorder.dispositions()
        XCTAssertEqual(connectionCleanupDispositions, [.invalidated])
    }

    func testCancellationReleasesSuspendedClaimAndLateCompletionDoesNotReleaseTwice() async {
        let suspension = RemuxSSHExecTestSuspension()
        let releaseRecorder = RemuxSSHExecReleaseRecorder()
        let connectionCleanupRecorder = RemuxSSHExecReleaseRecorder()
        let lifetime = RemuxSSHExecLifetimeOwner { disposition in
            await releaseRecorder.record(disposition)
        }

        let operation = Task {
            await withTaskCancellationHandler {
                await suspension.wait()

                lifetime.installConnectionCleanup { disposition in
                    await connectionCleanupRecorder.record(disposition)
                }
                await lifetime.close(disposition: .reusable)
            } onCancel: {
                lifetime.cancel()
            }
        }

        await suspension.waitUntilSuspended()
        operation.cancel()
        await releaseRecorder.waitForRelease()

        let cancellationDispositions = await releaseRecorder.dispositions()
        XCTAssertEqual(cancellationDispositions, [.invalidated])

        await suspension.resume()
        await operation.value

        let finalDispositions = await releaseRecorder.dispositions()
        let connectionCleanupDispositions = await connectionCleanupRecorder.dispositions()
        XCTAssertEqual(finalDispositions, [.invalidated])
        XCTAssertEqual(connectionCleanupDispositions, [.invalidated])
    }

    func testAlreadyCancelledRunClosesClaimedRootWithoutDispatchingExec() async throws {
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(
            comment: "cancelled-exec-session-test"
        )
        let serverID = UUID()
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxSSHExecSessionCancellationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let trustedHostStore = TrustedHostStore(rootURL: trustedHostRoot)
        try trustedHostStore.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: serverID,
                host: "127.0.0.1",
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: server.hostKeyType,
                receivedOpenSSHPublicKey: server.openSSHPublicKey
            )
        )
        let savedServer = SavedServer(
            id: serverID,
            displayName: "loopback",
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            identityID: serverID
        )
        let privateKey = SSHPrivateKeyCredential(
            privateKeyPEM: generatedKey.privateKeyPEM
        )
        let trace = RemuxTransportStartupTrace(flowID: "cancelled-exec-session-test")
        let prepared = RemuxSSHPreparedRoot.dedicated(
            configuration: RemuxSSHRootConfiguration(
                host: "127.0.0.1",
                port: server.port,
                authenticationMethod: {
                    try SSHAuthenticationMethodFactory.make(
                        username: "remux",
                        credential: .privateKey(privateKey)
                    )
                },
                hostKeyValidator: trustedHostStore.validator(for: savedServer),
                connectTimeout: .seconds(10)
            ),
            trace: trace
        )
        let root: RemuxSSHRoot
        do {
            root = try await prepared.sshRoot()
        } catch {
            await prepared.cancelAndCleanup()
            throw error
        }
        let claimed: RemuxSSHClaimedRoot
        do {
            claimed = try await prepared.claim(root, trace: trace)
        } catch {
            await prepared.cancelAndCleanup()
            throw error
        }
        let suspension = RemuxSSHExecTestSuspension()
        let operation = Task {
            await suspension.wait()
            return try await RemuxSSHExecSession.run(
                using: claimed,
                command: "exit 0",
                stdin: nil,
                trace: trace
            )
        }

        await suspension.waitUntilSuspended()
        operation.cancel()
        await suspension.resume()

        do {
            _ = try await operation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let didCloseRoot = await server.waitForClosedRootCount(1)
        XCTAssertTrue(didCloseRoot, "\(server.recordedRoots)")
        XCTAssertEqual(server.recordedRoots.execRequestCount, 0)
    }

    /// With reads on demand the server's bytes wait in the SSH window until `requestRead()`.
    func testReadsOnDemandDeliverDataOnlyAfterARead() async throws {
        let output = Data("herdr bridge bytes".utf8)
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux", execOutput: output)
        defer { server.stop() }
        let recorder = RemuxSSHExecDataRecorder()
        let trace = RemuxTransportStartupTrace(flowID: "reads-on-demand-test")
        let connection = try await RemuxSSHExecSession.open(
            using: try await claimedLoopbackRoot(server: server, trace: trace),
            command: "bridge",
            pseudoTerminal: false,
            readsOnDemand: true,
            trace: trace,
            onData: { recorder.record(type: $0, data: $1) },
            onFinish: { _, _ in }
        )

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recorder.stdout, Data())
        connection.requestRead()
        let received = await Self.waitForStdout(output, in: recorder)
        XCTAssertEqual(received, output)
        await connection.close(disposition: .reusable)
    }

    /// The same server's bytes arrive unasked on an ordinary channel, so the test above isn't vacuous.
    func testAutomaticReadsDeliverDataUnasked() async throws {
        let output = Data("unasked bytes".utf8)
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux", execOutput: output)
        defer { server.stop() }
        let recorder = RemuxSSHExecDataRecorder()
        let trace = RemuxTransportStartupTrace(flowID: "automatic-reads-test")
        let connection = try await RemuxSSHExecSession.open(
            using: try await claimedLoopbackRoot(server: server, trace: trace),
            command: "bridge",
            pseudoTerminal: false,
            trace: trace,
            onData: { recorder.record(type: $0, data: $1) },
            onFinish: { _, _ in }
        )

        let received = await Self.waitForStdout(output, in: recorder)
        XCTAssertEqual(received, output)
        await connection.close(disposition: .reusable)
    }

    private static func waitForStdout(_ expected: Data, in recorder: RemuxSSHExecDataRecorder) async -> Data {
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.stdout != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recorder.stdout
    }

    private func sshData(
        type: SSHChannelData.DataType,
        string: String
    ) -> SSHChannelData {
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return SSHChannelData(type: type, data: .byteBuffer(buffer))
    }

    private func assertOutputTooLarge(
        _ collector: RemuxSSHExecResultCollector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await collector.value()
            XCTFail("expected bounded output failure", file: file, line: line)
        } catch let error as RemuxSSHExecSessionError {
            XCTAssertEqual(error, .outputTooLarge, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

private enum RemuxSSHExecTestError: Error {
    case failed
}

private actor RemuxSSHExecTestSuspension {
    private var didSuspend = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        didSuspend = true
        observerContinuation?.resume()
        observerContinuation = nil

        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !didSuspend else { return }
        await withCheckedContinuation { continuation in
            observerContinuation = continuation
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private actor RemuxSSHExecReleaseRecorder {
    private var recordedDispositions: [RemuxSSHRootLeaseDisposition] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ disposition: RemuxSSHRootLeaseDisposition) {
        recordedDispositions.append(disposition)
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitForRelease() async {
        guard recordedDispositions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func dispositions() -> [RemuxSSHRootLeaseDisposition] {
        recordedDispositions
    }
}

private final class RemuxSSHExecDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStdout = Data()
    private var recordedStderr = Data()

    var stdout: Data {
        lock.withLock { recordedStdout }
    }

    var stderr: Data {
        lock.withLock { recordedStderr }
    }

    func record(type: SSHChannelData.DataType, data: Data) {
        lock.withLock {
            switch type {
            case .channel:
                recordedStdout.append(data)
            case .stdErr:
                recordedStderr.append(data)
            default:
                break
            }
        }
    }
}

private final class RemuxSSHExecCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFinishCount = 0
    private var recordedExitStatus: Int?
    private var recordedError: Error?

    var finishCount: Int {
        lock.withLock { recordedFinishCount }
    }

    var exitStatus: Int? {
        lock.withLock { recordedExitStatus }
    }

    var error: RemuxSSHExecSessionError? {
        lock.withLock { recordedError as? RemuxSSHExecSessionError }
    }

    var hasError: Bool {
        lock.withLock { recordedError != nil }
    }

    func record(exitStatus: Int?, error: Error?) {
        lock.withLock {
            recordedFinishCount += 1
            recordedExitStatus = exitStatus
            recordedError = error
        }
    }
}

private final class RemuxSSHExecUserEventRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let lock = NSLock()
    private var recordedFailureCount = 0

    var failureCount: Int {
        lock.withLock { recordedFailureCount }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is NIOSSH.ChannelFailureEvent {
            lock.withLock {
                recordedFailureCount += 1
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class RemuxSSHExecOutboundRecorder: ChannelOutboundHandler, @unchecked Sendable {
    enum Event: Equatable {
        case write(Data)
        case closeOutput
        case closeInput
        case closeAll
    }

    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let channelData = unwrapOutboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else {
            context.write(wrapOutboundOut(channelData), promise: promise)
            return
        }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.withLock {
            recordedEvents.append(.write(Data(bytes)))
        }
        context.write(wrapOutboundOut(channelData), promise: promise)
    }

    func close(
        context: ChannelHandlerContext,
        mode: CloseMode,
        promise: EventLoopPromise<Void>?
    ) {
        let event: Event
        switch mode {
        case .output:
            event = .closeOutput
        case .input:
            event = .closeInput
        case .all:
            event = .closeAll
        }
        lock.withLock {
            recordedEvents.append(event)
        }
        context.close(mode: mode, promise: promise)
    }
}

extension XCTestCase {
    /// A dedicated SSH root to the in-process test server, trusted for this test only.
    func claimedLoopbackRoot(
        server: SSHPublicKeyLiveTestServer,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHClaimedRoot {
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(comment: "loopback-exec-test")
        let serverID = UUID()
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxSSHExecSessionLoopback-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let trustedHostStore = TrustedHostStore(rootURL: trustedHostRoot)
        try trustedHostStore.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: serverID,
                host: "127.0.0.1",
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: server.hostKeyType,
                receivedOpenSSHPublicKey: server.openSSHPublicKey
            )
        )
        let savedServer = SavedServer(
            id: serverID,
            displayName: "loopback",
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            identityID: serverID
        )
        let privateKey = SSHPrivateKeyCredential(privateKeyPEM: generatedKey.privateKeyPEM)
        let prepared = RemuxSSHPreparedRoot.dedicated(
            configuration: RemuxSSHRootConfiguration(
                host: "127.0.0.1",
                port: server.port,
                authenticationMethod: {
                    try SSHAuthenticationMethodFactory.make(
                        username: "remux",
                        credential: .privateKey(privateKey)
                    )
                },
                hostKeyValidator: trustedHostStore.validator(for: savedServer),
                connectTimeout: .seconds(10)
            ),
            trace: trace
        )
        do {
            let root = try await prepared.sshRoot()
            return try await prepared.claim(root, trace: trace)
        } catch {
            await prepared.cancelAndCleanup()
            throw error
        }
    }
}
