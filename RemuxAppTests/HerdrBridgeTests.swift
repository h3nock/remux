import Foundation
import NIOCore
import XCTest
@testable import Remux

/// The launch command, the ready marker, and the bridge transport on a real SSH channel (an in-process
/// SSH server).
final class HerdrBridgeTests: XCTestCase {
    // MARK: - Launch command

    func testCommandKeepsTheExecutableAndSessionOutOfTheLoginShell() {
        let executable = "/home/owner's tools/herdr; touch pwned"
        let session = "work'; rm -rf ~"

        let command = HerdrSSHBridge.command(herdrExecutable: executable, session: session, kind: .session)

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains(session))
        XCTAssertTrue(command.hasSuffix(
            " sh \(RemoteShellArgument.octalEncoded(executable)) \(RemoteShellArgument.octalEncoded(session))"
        ))
    }

    func testCommandAsksForTheIdleTimeoutOnlyWhereHerdrReportsIt() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default", kind: .session)
        XCTAssertTrue(command.contains(#""$resolved" status client --json"#))
        XCTAssertTrue(command.contains(#"remote_bridge_idle_timeout\": *true"#))
        XCTAssertTrue(command.contains(#"--session "$session" remote-client-bridge --idle-timeout-v1"#))
        XCTAssertTrue(command.contains(#"exec "$resolved" --session "$session" remote-client-bridge' sh"#))
    }

    /// A terminal's bridge is quiet while the terminal is, so it never asks for the idle timeout, as Herdr's
    /// client runs its interactive attach.
    func testATerminalsBridgeNeverAsksForTheIdleTimeout() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default", kind: .terminal)
        XCTAssertFalse(command.contains("--idle-timeout-v1"))
        XCTAssertFalse(command.contains("remote_bridge_idle_timeout"))
        XCTAssertTrue(command.contains(#"exec "$resolved" --session "$session" remote-client-bridge' sh"#))
    }

    // MARK: - On an SSH channel

    /// Stderr, here from the server's startup files, takes a read of its own; the bridge asks again,
    /// so the stdout behind it still arrives.
    func testStderrDoesNotStallTheStream() async throws {
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .stdErr, data: Data("stty: not a tty\n".utf8)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine + Data("payload".utf8), delay: .milliseconds(100)),
        ])
        let bytes = try await Self.read(from: bridge, count: 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "payload")
        await bridge.close(.finished)
    }

    /// What the server's startup files print before the marker never reaches the protocol.
    func testStartupOutputIsSkipped() async throws {
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .channel, data: Data("Welcome to the server\n".utf8)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine, delay: .milliseconds(50)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Data("payload".utf8), delay: .milliseconds(50)),
        ])
        let bytes = try await Self.read(from: bridge, count: 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "payload")
        await bridge.close(.finished)
    }

    /// More than one SSH window (2 MiB) arrives over several reads, from a single server write that the
    /// server splits into packets and sends as the window refills.
    func testMoreThanOneWindowArrivesOverReads() async throws {
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine + payload),
        ])
        let bytes = try await Self.read(from: bridge, count: payload.count)
        XCTAssertEqual(Data(bytes), payload)
        await bridge.close(.finished)
    }

    /// On a dead path the server never answers the channel close; closing still ends the waiting read
    /// at once.
    func testCloseEndsAWaitingReadWithoutTheServersAnswer() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let bridge = try await openBridge(on: server)
        let reading = Task { try await bridge.read() }
        try await Task.sleep(for: .milliseconds(50))
        try await server.stopReadingFromClients()
        let started = ContinuousClock.now
        await bridge.close(.unresponsive)
        let result = try await reading.value
        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        do {
            try await bridge.write([1])
            XCTFail("wrote after the end")
        } catch let error as HerdrBridgeError {
            XCTAssertEqual(error, .channel("the bridge has ended"))
        }
    }

    /// A write the server never takes (it stopped reading, so the SSH window never refills) fails at once
    /// when the bridge closes, also on a reusable close, where the SSH connection stays open for others.
    func testCloseFailsAWriteTheServerNeverTakes() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let (bridge, _) = try await openBridgeAndRoot(on: server)
        try await server.stopReadingFromClients()
        let outcome = WriteOutcome()
        // Four times the 2 MiB window.
        let bytes = [UInt8](repeating: 0x61, count: 8 * 1024 * 1024)
        Task {
            do {
                try await bridge.write(bytes)
                outcome.record(.success(()))
            } catch {
                outcome.record(.failure(error))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(outcome.result, "the write finished although the server stopped reading")

        let started = ContinuousClock.now
        await bridge.close(.finished)
        while outcome.result == nil, ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failure(let error)? = outcome.result else {
            XCTFail("the write didn't fail when the bridge closed: \(String(describing: outcome.result))")
            return
        }
        XCTAssertEqual(error as? HerdrBridgeError, .channel("the bridge has ended"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    /// A close for a path that went silent gives the SSH connection back without the server's answer
    /// and before returning, so a connection nobody else uses (here a dedicated one) is already closed.
    func testAnUnreusableCloseReleasesTheSSHConnectionWithoutTheServersAnswer() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let (bridge, root) = try await openBridgeAndRoot(on: server)
        try await server.stopReadingFromClients()

        let started = ContinuousClock.now
        await bridge.close(.unresponsive)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertFalse(root.sshRoot.rootChannel.isActive, "the SSH connection is still open")
    }

    /// The bridge decides from its close's cause whether the pool offers its SSH connection again: not
    /// after an opening was given up or Herdr went silent, and then not even right after the close
    /// returns, so a reconnect made at once gets a new one; after anything else it does, as Herdr's
    /// client keeps its SSH connection for its next bridge.
    func testTheCloseCauseDecidesWhetherThePoolOffersTheSSHConnectionAgain() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let trace = RemuxTransportStartupTrace(flowID: "herdr-bridge-pool-test")
        let id = UUID()
        let saved = SavedServer(id: id, displayName: "loopback", host: "127.0.0.1", port: server.port, username: "remux", identityID: id)
        let trustedHostRoot = FileManager.default.temporaryDirectory.appendingPathComponent("HerdrBridgePool-\(id)")
        addTeardownBlock { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let trustedHostStore = TrustedHostStore(rootURL: trustedHostRoot)
        try trustedHostStore.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: id,
                host: "127.0.0.1",
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: server.hostKeyType,
                receivedOpenSSHPublicKey: server.openSSHPublicKey
            )
        )
        let key = RemuxSSHRootKey(
            target: SessionTarget(
                server: saved,
                workspace: SavedWorkspace(serverID: id, sessionName: "pool"),
                sshAuth: .password(username: "remux", password: "pool", identityID: id, displayLabel: "pool")
            )
        )
        let configuration = RemuxSSHRootConfiguration(
            host: "127.0.0.1",
            port: server.port,
            authenticationMethod: { try SSHAuthenticationMethodFactory.make(username: "remux", credential: .password("pool")) },
            hostKeyValidator: trustedHostStore.validator(for: saved),
            connectTimeout: .seconds(10)
        )
        let pool = RemuxSSHRootService()
        addTeardownBlock { await pool.closeAllConnectionsForTesting() }

        let causes: [(HerdrBridgeCloseCause, offeredAgain: Bool)] = [
            (.givenUpWhileOpening, false), (.unresponsive, false), (.finished, true),
            (.unresponsive, false), (.finished, true), (.givenUpWhileOpening, false),
        ]
        for (cause, offeredAgain) in causes {
            let prepared = await pool.preparedRoot(for: key, configuration: configuration, trace: trace)
            let root = try await prepared.sshRoot()
            let bridge = try await HerdrSSHBridge.open(
                using: try await prepared.claim(root, trace: trace),
                herdrExecutable: "herdr",
                session: "pool",
                kind: .session,
                trace: trace
            )
            await bridge.close(cause)

            let next = await pool.preparedRoot(for: key, configuration: configuration, trace: trace)
            let nextRoot = try await next.sshRoot()
            XCTAssertEqual(nextRoot === root, offeredAgain, "\(cause)")
            // Each round starts on a new SSH connection.
            let claimed = try await next.claim(nextRoot, trace: trace)
            await claimed.release(.invalidated)
        }
    }

    // MARK: - Helpers

    private static let readyLine = Data("\n\(RemoteProgramCommand.readyMarker)\n".utf8)

    private func openBridge(steps: [SSHPublicKeyLiveExecStep]) async throws -> HerdrSSHBridge {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux", execSteps: steps)
        addTeardownBlock { server.stop() }
        return try await openBridge(on: server)
    }

    private func openBridge(on server: SSHPublicKeyLiveTestServer) async throws -> HerdrSSHBridge {
        try await openBridgeAndRoot(on: server).bridge
    }

    /// The bridge on a dedicated SSH connection, which the test closes afterwards whatever the bridge
    /// left open.
    private func openBridgeAndRoot(
        on server: SSHPublicKeyLiveTestServer
    ) async throws -> (bridge: HerdrSSHBridge, root: RemuxSSHClaimedRoot) {
        let trace = RemuxTransportStartupTrace(flowID: "herdr-bridge-test")
        let root = try await claimedLoopbackRoot(server: server, trace: trace)
        addTeardownBlock { await root.sshRoot.close() }
        let bridge = try await HerdrSSHBridge.open(
            using: root,
            herdrExecutable: "herdr",
            session: "default",
            kind: .session,
            trace: trace
        )
        return (bridge, root)
    }

    /// Reads until `count` bytes arrived, failing after five seconds.
    private static func read(from bridge: HerdrSSHBridge, count: Int) async throws -> [UInt8] {
        try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask {
                var bytes: [UInt8] = []
                while bytes.count < count, let chunk = try await bridge.read() {
                    bytes += chunk
                }
                return bytes
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                await bridge.close(.finished)
                return []
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}

/// How a write ended, for a test that can't await a write that may never return.
private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, Error>?

    var result: Result<Void, Error>? {
        lock.withLock { stored }
    }

    func record(_ result: Result<Void, Error>) {
        lock.withLock { stored = result }
    }
}

