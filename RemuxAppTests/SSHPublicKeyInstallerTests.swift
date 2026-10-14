@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import NIO
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHPublicKeyInstallerTests: XCTestCase {
    func testPreflightReturnsAlreadyInstalledAfterZeroKeyProbe() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .alreadyInstalled)
        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, Self.target)
        XCTAssertEqual(recordedCommand.credential, .privateKey(Self.target.privateKey))
        XCTAssertEqual(recordedCommand.command, "exit 0")
        XCTAssertNil(recordedCommand.stdin)
    }

    func testPreflightRequestsPasswordOnlyForAllAuthenticationOptionsFailed() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(SSHClientError.allAuthenticationOptionsFailed),
        ])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .passwordRequired)
    }

    func testPreflightRequestsPasswordWhenPublicKeyAuthenticationIsUnsupported() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(SSHClientError.unsupportedPrivateKeyAuthentication),
        ])
        let installer = makeInstaller(recorder: recorder)

        let outcome = try await installer.preflight(Self.target)

        XCTAssertEqual(outcome, .passwordRequired)
    }

    func testPreflightDoesNotConvertHostTrustOrNetworkErrorsToPasswordRequired() async {
        await assertPreflightPassesThrough(TrustedHostStoreError.invalidHostKey) { error in
            error is TrustedHostStoreError
        }
        await assertPreflightPassesThrough(SSHPublicKeyInstallerTestError.networkUnavailable) { error in
            error as? SSHPublicKeyInstallerTestError == .networkUnavailable
        }
    }

    func testPreflightDoesNotConvertOtherCitadelAuthenticationErrorsToPasswordRequired() async {
        for error in [
            SSHClientError.unsupportedPasswordAuthentication,
            SSHClientError.unsupportedHostBasedAuthentication,
        ] {
            await assertPreflightPassesThrough(error) { received in
                guard let received = received as? SSHClientError else { return false }
                switch (error, received) {
                case (.unsupportedPasswordAuthentication, .unsupportedPasswordAuthentication),
                     (.unsupportedHostBasedAuthentication, .unsupportedHostBasedAuthentication):
                    return true
                default:
                    return false
                }
            }
        }
    }

    func testPreflightReportsAcceptedKeyWhenExecProbeFails() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: SSHPublicKeyInstallerTestError.execFailed
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(.keyAcceptedButProbeFailed) {
            _ = try await installer.preflight(Self.target)
        }
    }

    func testPreflightPreservesCancellationAfterKeyAuthentication() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: CancellationError()
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertCancellationError {
            _ = try await installer.preflight(Self.target)
        }
    }

    func testPreflightReportsAcceptedKeyWhenProbeExitsNonzero() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(.failure(exitStatus: 127, stderr: "missing shell")),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(.keyAcceptedButProbeFailed) {
            _ = try await installer.preflight(Self.target)
        }
    }

    func testAppendUsesPasswordAndSendsOnlyPublicKeyLineWithNewline() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)
        let target = Self.target

        try await installer.append(target, password: "one-time-password")

        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, target)
        XCTAssertEqual(recordedCommand.credential, .password("one-time-password"))
        XCTAssertEqual(recordedCommand.stdin, Data("\(target.publicKeyLine)\n".utf8))
    }

    func testAppendMapsPasswordAuthenticationFailure() async {
        for error in [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
        ] {
            let recorder = SSHPublicKeyCommandRecorder(results: [.failure(error)])
            let installer = makeInstaller(recorder: recorder)

            await assertInstallerError(.passwordRejected) {
                try await installer.append(Self.target, password: "rejected-password")
            }
        }
    }

    func testAppendPassesThroughPreAuthenticationHostTrustFailure() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(TrustedHostStoreError.invalidHostKey),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.append(Self.target, password: "one-time-password")
            XCTFail("expected host-trust failure")
        } catch {
            XCTAssertTrue(error is TrustedHostStoreError)
        }
    }

    func testAppendSanitizesPostClaimCommandFailure() async {
        let reflectedSecret = "REFLECTED-REMOTE-DIAGNOSTIC"
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: SSHPublicKeyReflectedCommandError(
                        diagnostic: reflectedSecret
                    )
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.append(Self.target, password: "one-time-password")
            XCTFail("expected sanitized command failure")
        } catch {
            XCTAssertTrue(error is SSHPublicKeyInstallerError)
            XCTAssertFalse(error.localizedDescription.contains(reflectedSecret))
            XCTAssertFalse(String(reflecting: error).contains(reflectedSecret))
        }
    }

    func testAppendPreservesPostClaimCancellation() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: CancellationError()
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertCancellationError {
            try await installer.append(Self.target, password: "one-time-password")
        }
    }

    func testAppendDoesNotRetainSecretsReflectedInCommandOutput() async {
        let secrets = [
            "PUBLIC-KEY-SENTINEL",
            "PASSWORD-SENTINEL",
            "PRIVATE-KEY-SENTINEL",
            "PASSPHRASE-SENTINEL",
        ]
        let reflectedOutput = secrets.joined(separator: "|")
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(
                .failure(
                    exitStatus: 73,
                    stderr: "stderr:\(reflectedOutput)",
                    stdout: "stdout:\(reflectedOutput)"
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.append(
                SSHPublicKeyInstallTarget(
                    serverID: Self.target.serverID,
                    host: Self.target.host,
                    port: Self.target.port,
                    username: Self.target.username,
                    privateKey: SSHPrivateKeyCredential(
                        privateKeyPEM: secrets[2],
                        passphrase: secrets[3]
                    ),
                    publicKeyLine: secrets[0]
                ),
                password: secrets[1]
            )
            XCTFail("expected installation command failure")
        } catch let error as SSHPublicKeyInstallerError {
            guard case .installationCommandFailed(let exitStatus, let recordedDiagnostic) = error else {
                return XCTFail("unexpected installer error: \(error)")
            }
            XCTAssertEqual(exitStatus, 73)
            XCTAssertNil(recordedDiagnostic)
            for secret in secrets {
                XCTAssertFalse(error.localizedDescription.contains(secret))
                XCTAssertFalse(String(reflecting: error).contains(secret))
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVerifyMapsKeyAuthenticationFailure() async {
        for error in [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPrivateKeyAuthentication,
        ] {
            let recorder = SSHPublicKeyCommandRecorder(results: [.failure(error)])
            let installer = makeInstaller(recorder: recorder)

            await assertInstallerError(.verificationRejected) {
                try await installer.verify(Self.target)
            }
        }
    }

    func testVerifyMapsNonzeroStatusWithStderrDiagnostic() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .success(.failure(exitStatus: 126, stderr: "exec prohibited")),
        ])
        let installer = makeInstaller(recorder: recorder)

        await assertInstallerError(
            .verificationCommandFailed(exitStatus: 126, diagnostic: "exec prohibited")
        ) {
            try await installer.verify(Self.target)
        }
    }

    func testVerifyUnwrapsPostClaimCommandFailure() async {
        let recorder = SSHPublicKeyCommandRecorder(results: [
            .failure(
                SSHPublicKeyCommandExecutionError(
                    underlying: SSHPublicKeyLocalizedCommandError.execFailed
                )
            ),
        ])
        let installer = makeInstaller(recorder: recorder)

        do {
            try await installer.verify(Self.target)
            XCTFail("expected localized command failure")
        } catch let error as SSHPublicKeyLocalizedCommandError {
            XCTAssertEqual(error, .execFailed)
            XCTAssertEqual(error.localizedDescription, "The authenticated SSH command failed.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVerifyUsesFreshKeyProbe() async throws {
        let recorder = SSHPublicKeyCommandRecorder(results: [.success(.success)])
        let installer = makeInstaller(recorder: recorder)

        try await installer.verify(Self.target)

        let commands = await recorder.commands()
        let recordedCommand = try XCTUnwrap(commands.first)
        XCTAssertEqual(recordedCommand.target, Self.target)
        XCTAssertEqual(recordedCommand.credential, .privateKey(Self.target.privateKey))
        XCTAssertEqual(recordedCommand.command, "exit 0")
        XCTAssertNil(recordedCommand.stdin)
    }

    func testEveryLiveCommandUsesDedicatedRootAndClosesIt() async throws {
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(comment: "live-installer-test")
        let serverID = UUID()
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHPublicKeyInstallerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let trustedHostStore = TrustedHostStore(
            rootURL: trustedHostRoot
        )
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
        let target = SSHPublicKeyInstallTarget(
            serverID: serverID,
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            privateKey: SSHPrivateKeyCredential(privateKeyPEM: generatedKey.privateKeyPEM),
            publicKeyLine: generatedKey.publicKeyLine
        )
        let installer = try SSHPublicKeyInstaller(trustedHostStore: trustedHostStore)

        let preflightOutcome = try await installer.preflight(target)
        XCTAssertEqual(preflightOutcome, .alreadyInstalled)
        let didClosePreflightRoot = await server.waitForClosedRootCount(1)
        XCTAssertTrue(didClosePreflightRoot, "\(server.recordedRoots)")

        try await installer.append(target, password: "one-time-password")
        let didCloseAppendRoot = await server.waitForClosedRootCount(2)
        XCTAssertTrue(didCloseAppendRoot, "\(server.recordedRoots)")

        try await installer.verify(target)
        let didCloseVerificationRoot = await server.waitForClosedRootCount(3)
        XCTAssertTrue(didCloseVerificationRoot, "\(server.recordedRoots)")

        let roots = server.recordedRoots
        XCTAssertEqual(roots.opened.count, 3)
        XCTAssertEqual(Set(roots.opened).count, 3)
        XCTAssertEqual(Set(roots.closed), Set(roots.opened))
    }

    func testRegisteredLegacyRSAHostKeyNegotiatesAndVerifiesAgainstTrustedLine() async throws {
        RemuxSSHAlgorithmRegistration.ensureRegistered()
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(comment: "rsa-host-key-test")
        let serverID = UUID()
        let hostKey = try Insecure.RSA.PrivateKey(sshRsa: SSHPrivateKeyInspectorTests.rsaKey)
        let server = try await SSHPublicKeyLiveTestServer.start(
            username: "remux",
            hostKey: NIOSSHPrivateKey(custom: hostKey)
        )
        defer { server.stop() }
        XCTAssertEqual(server.hostKeyType, "ssh-rsa")
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHPublicKeyInstallerRSAHostKeyTests-\(UUID().uuidString)")
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
        let target = SSHPublicKeyInstallTarget(
            serverID: serverID,
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            privateKey: SSHPrivateKeyCredential(privateKeyPEM: generatedKey.privateKeyPEM),
            publicKeyLine: generatedKey.publicKeyLine
        )
        let installer = try SSHPublicKeyInstaller(trustedHostStore: trustedHostStore)

        let outcome = try await installer.preflight(target)

        XCTAssertEqual(outcome, .alreadyInstalled)
        XCTAssertEqual(server.recordedRoots.execRequestCount, 1)
    }

    func testCancellationDuringLiveAuthenticationClosesRootWithoutExecutingAppend() async throws {
        let generatedKey = SSHPrivateKeyInspector.generateEd25519(
            comment: "cancelled-live-installer-test"
        )
        let serverID = UUID()
        let server = try await SSHPublicKeyLiveTestServer.start(
            username: "remux",
            suspendAuthentication: true
        )
        defer { server.stop() }
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHPublicKeyInstallerCancellationTests-\(UUID().uuidString)")
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
        let target = SSHPublicKeyInstallTarget(
            serverID: serverID,
            host: "127.0.0.1",
            port: server.port,
            username: "remux",
            privateKey: SSHPrivateKeyCredential(privateKeyPEM: generatedKey.privateKeyPEM),
            publicKeyLine: generatedKey.publicKeyLine
        )
        let installer = try SSHPublicKeyInstaller(trustedHostStore: trustedHostStore)
        let appendTask = Task {
            try await installer.append(target, password: "one-time-password")
        }

        let didSuspendAuthentication = await server.waitForSuspendedAuthentication()
        XCTAssertTrue(didSuspendAuthentication)
        appendTask.cancel()
        server.resumeAuthentication()

        await assertCancellationError {
            try await appendTask.value
        }
        let didCloseRoot = await server.waitForClosedRootCount(1)
        XCTAssertTrue(didCloseRoot, "\(server.recordedRoots)")
        XCTAssertEqual(server.recordedRoots.execRequestCount, 0)
    }

    private func makeInstaller(
        recorder: SSHPublicKeyCommandRecorder
    ) -> SSHPublicKeyInstaller {
        SSHPublicKeyInstaller(
            installationCommand: "fixture installer command",
            commandRunner: { target, credential, command, stdin in
                try await recorder.run(
                    target: target,
                    credential: credential,
                    command: command,
                    stdin: stdin
                )
            }
        )
    }

    private func assertPreflightPassesThrough(
        _ expectedError: Error,
        matches: @escaping (Error) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = SSHPublicKeyCommandRecorder(results: [.failure(expectedError)])
        let installer = makeInstaller(recorder: recorder)

        do {
            _ = try await installer.preflight(Self.target)
            XCTFail("expected preflight failure", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertInstallerError(
        _ expectedError: SSHPublicKeyInstallerError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected installer error", file: file, line: line)
        } catch let error as SSHPublicKeyInstallerError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertCancellationError(
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected cancellation", file: file, line: line)
        } catch is CancellationError {
            return
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private static let target = SSHPublicKeyInstallTarget(
        serverID: UUID(uuidString: "CF6C1653-2B17-41DC-8277-FD31E6222F61")!,
        host: "server.example.test",
        port: 2222,
        username: "remux",
        privateKey: SSHPrivateKeyCredential(
            privateKeyPEM: "fixture private key",
            passphrase: "fixture passphrase"
        ),
        publicKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture remux@test"
    )
}

private actor SSHPublicKeyCommandRecorder {
    private var results: [Result<RemuxSSHExecResult, Error>]
    private var recordedCommands: [SSHPublicKeyRecordedCommand] = []

    init(results: [Result<RemuxSSHExecResult, Error>]) {
        self.results = results
    }

    func run(
        target: SSHPublicKeyInstallTarget,
        credential: SSHCredential,
        command: String,
        stdin: Data?
    ) throws -> RemuxSSHExecResult {
        recordedCommands.append(
            SSHPublicKeyRecordedCommand(
                target: target,
                credential: credential,
                command: command,
                stdin: stdin
            )
        )
        guard !results.isEmpty else {
            throw SSHPublicKeyInstallerTestError.missingResult
        }
        return try results.removeFirst().get()
    }

    func commands() -> [SSHPublicKeyRecordedCommand] {
        recordedCommands
    }
}

private struct SSHPublicKeyRecordedCommand: Equatable, Sendable {
    let target: SSHPublicKeyInstallTarget
    let credential: SSHCredential
    let command: String
    let stdin: Data?
}

private enum SSHPublicKeyInstallerTestError: Error, Equatable {
    case execFailed
    case missingResult
    case networkUnavailable
}

private enum SSHPublicKeyLocalizedCommandError: LocalizedError, Equatable {
    case execFailed

    var errorDescription: String? {
        "The authenticated SSH command failed."
    }
}

private struct SSHPublicKeyReflectedCommandError: LocalizedError {
    let diagnostic: String

    var errorDescription: String? {
        diagnostic
    }
}

/// One write an exec channel makes after `delay` from the previous step.
struct SSHPublicKeyLiveExecStep: Sendable {
    let type: SSHChannelData.DataType
    let data: Data
    var delay: TimeAmount = .zero
}

final class SSHPublicKeyLiveTestServer: @unchecked Sendable {
    let port: Int
    let openSSHPublicKey: String
    let hostKeyType: String

    private let serverChannel: Channel
    private let authenticationDelegate: SSHPublicKeyLiveAuthenticationDelegate
    private let rootRecorder: SSHPublicKeyLiveRootRecorder
    private let connections: SSHPublicKeyLiveConnections

    var recordedRoots: SSHPublicKeyLiveRootRecorder.Snapshot {
        rootRecorder.snapshot()
    }

    private init(
        serverChannel: Channel,
        hostPublicKey: NIOSSHPublicKey,
        authenticationDelegate: SSHPublicKeyLiveAuthenticationDelegate,
        rootRecorder: SSHPublicKeyLiveRootRecorder,
        connections: SSHPublicKeyLiveConnections
    ) throws {
        guard let port = serverChannel.localAddress?.port else {
            throw SSHPublicKeyLiveTestServerError.missingPort
        }
        let openSSHPublicKey = String(openSSHPublicKey: hostPublicKey)
        guard let hostKeyType = openSSHPublicKey
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) else {
            throw SSHPublicKeyLiveTestServerError.invalidHostKey
        }

        self.port = port
        self.openSSHPublicKey = openSSHPublicKey
        self.hostKeyType = hostKeyType
        self.serverChannel = serverChannel
        self.authenticationDelegate = authenticationDelegate
        self.rootRecorder = rootRecorder
        self.connections = connections
    }

    /// With `execOutput`, each accepted exec sends those bytes on stdout right away; with `execSteps`,
    /// it makes those writes in order.
    static func start(
        username: String,
        suspendAuthentication: Bool = false,
        execOutput: Data? = nil,
        execSteps: [SSHPublicKeyLiveExecStep] = [],
        hostKey: NIOSSHPrivateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    ) async throws -> SSHPublicKeyLiveTestServer {
        let steps = execOutput.map { [SSHPublicKeyLiveExecStep(type: .channel, data: $0)] } ?? execSteps
        let connections = SSHPublicKeyLiveConnections()
        let authenticationDelegate = SSHPublicKeyLiveAuthenticationDelegate(
            username: username,
            suspendAuthentication: suspendAuthentication
        )
        let rootRecorder = SSHPublicKeyLiveRootRecorder()
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                let rootID = UUID()
                rootRecorder.open(rootID)
                connections.add(channel)
                channel.closeFuture.whenComplete { _ in
                    rootRecorder.close(rootID)
                }
                let sshConfiguration = SSHServerConfiguration(
                    hostKeys: [hostKey],
                    userAuthDelegate: authenticationDelegate
                )
                let sshHandler = NIOSSHHandler(
                    role: .server(sshConfiguration),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(
                                SSHPublicKeyLiveTestServerError.invalidChannelType
                            )
                        }
                        return childChannel
                            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            .flatMap {
                                childChannel.pipeline.addHandler(
                                    SSHPublicKeyLiveExecHandler(rootRecorder: rootRecorder, execSteps: steps)
                                )
                            }
                    }
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(SSHPublicKeyLiveErrorHandler())
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        return try SSHPublicKeyLiveTestServer(
            serverChannel: serverChannel,
            hostPublicKey: hostKey.publicKey,
            authenticationDelegate: authenticationDelegate,
            rootRecorder: rootRecorder,
            connections: connections
        )
    }

    /// Stops reading from every client connection, as a dead network path would: nothing the client
    /// sends, a channel close included, is answered any more.
    func stopReadingFromClients() async throws {
        for channel in connections.all {
            try await channel.setOption(ChannelOptions.autoRead, value: false).get()
        }
    }

    func waitForSuspendedAuthentication() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if authenticationDelegate.hasSuspendedRequest {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return authenticationDelegate.hasSuspendedRequest
    }

    func resumeAuthentication() {
        authenticationDelegate.resumeAuthentication()
    }

    func waitForClosedRootCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if rootRecorder.snapshot().closed.count == count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return rootRecorder.snapshot().closed.count == count
    }

    func stop() {
        serverChannel.close(promise: nil)
    }
}

private final class SSHPublicKeyLiveAuthenticationDelegate:
    NIOSSHServerUserAuthenticationDelegate,
    @unchecked Sendable
{
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [
        .password,
        .publicKey,
    ]

    private let username: String
    private let suspendAuthentication: Bool
    private let lock = NSLock()
    private var suspendedResponsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>?

    var hasSuspendedRequest: Bool {
        lock.withLock {
            suspendedResponsePromise != nil
        }
    }

    init(
        username: String,
        suspendAuthentication: Bool
    ) {
        self.username = username
        self.suspendAuthentication = suspendAuthentication
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username else {
            responsePromise.succeed(.failure)
            return
        }
        if suspendAuthentication {
            lock.withLock {
                suspendedResponsePromise = responsePromise
            }
            return
        }
        switch request.request {
        case .password, .publicKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }

    func resumeAuthentication() {
        let responsePromise = lock.withLock {
            let responsePromise = suspendedResponsePromise
            suspendedResponsePromise = nil
            return responsePromise
        }
        responsePromise?.succeed(.success)
    }
}

private final class SSHPublicKeyLiveExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let rootRecorder: SSHPublicKeyLiveRootRecorder
    private let execSteps: [SSHPublicKeyLiveExecStep]
    private var didAcceptExec = false

    init(rootRecorder: SSHPublicKeyLiveRootRecorder, execSteps: [SSHPublicKeyLiveExecStep] = []) {
        self.rootRecorder = rootRecorder
        self.execSteps = execSteps
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.ExecRequest:
            didAcceptExec = true
            rootRecorder.recordExecRequest()
            if request.wantReply {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            let channel = context.channel
            var delay = TimeAmount.zero
            for step in execSteps {
                delay = delay + step.delay
                channel.eventLoop.scheduleTask(in: delay) {
                    var buffer = channel.allocator.buffer(capacity: step.data.count)
                    buffer.writeBytes(step.data)
                    channel.writeAndFlush(SSHChannelData(type: step.type, data: .byteBuffer(buffer)), promise: nil)
                }
            }
        case ChannelEvent.inputClosed:
            guard didAcceptExec else {
                context.close(promise: nil)
                return
            }
            let channel = context.channel
            _ = channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitStatus(exitStatus: 0)
            ).flatMap {
                channel.close()
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class SSHPublicKeyLiveErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

final class SSHPublicKeyLiveConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []

    var all: [Channel] {
        lock.withLock { channels }
    }

    func add(_ channel: Channel) {
        lock.withLock { channels.append(channel) }
    }
}

final class SSHPublicKeyLiveRootRecorder: @unchecked Sendable {
    struct Snapshot {
        let opened: [UUID]
        let closed: [UUID]
        let execRequestCount: Int
    }

    private let lock = NSLock()
    private var opened: [UUID] = []
    private var closed: [UUID] = []
    private var execRequestCount = 0

    func open(_ rootID: UUID) {
        lock.withLock {
            opened.append(rootID)
        }
    }

    func close(_ rootID: UUID) {
        lock.withLock {
            closed.append(rootID)
        }
    }

    func recordExecRequest() {
        lock.withLock {
            execRequestCount += 1
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                opened: opened,
                closed: closed,
                execRequestCount: execRequestCount
            )
        }
    }
}

private enum SSHPublicKeyLiveTestServerError: Error {
    case invalidChannelType
    case invalidHostKey
    case missingPort
}

private extension RemuxSSHExecResult {
    static let success = RemuxSSHExecResult(
        exitStatus: 0,
        stdout: Data(),
        stderr: Data()
    )

    static func failure(
        exitStatus: Int,
        stderr: String,
        stdout: String = ""
    ) -> RemuxSSHExecResult {
        RemuxSSHExecResult(
            exitStatus: exitStatus,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
