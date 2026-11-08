import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import Remux

/// The pool against a real OpenSSH server: a refused session moves to a second pooled connection, an unanswered
/// open closes a dead connection and opens on a fresh one, and the connection check closes a stalled connection
/// while keeping a healthy one. `REMUX_LIVE_SSH_POOL_CONFIG` names a JSON file with these fields (pass it to
/// `xcodebuild test` as `TEST_RUNNER_REMUX_LIVE_SSH_POOL_CONFIG`); without it the tests skip.
struct SSHPoolLiveConfiguration: Decodable {
    let host: String
    let username: String
    let privateKeyPEM: String
    /// The server's key as an OpenSSH public key line, trusted for these tests only.
    let hostKey: String
    /// A server with OpenSSH's default MaxSessions (10).
    let port: Int
    /// The same server allowing two sessions per connection (`MaxSessions 2`).
    let limitedPort: Int

    static func load() throws -> SSHPoolLiveConfiguration {
        guard let path = ProcessInfo.processInfo.environment["REMUX_LIVE_SSH_POOL_CONFIG"], !path.isEmpty else {
            throw XCTSkip("Set REMUX_LIVE_SSH_POOL_CONFIG to run the live SSH pool tests.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

final class SSHPoolLiveTests: XCTestCase {
    func testRefusedSessionOpensOnASecondPooledConnectionThatTheNextOneReuses() async throws {
        let configuration = try SSHPoolLiveConfiguration.load()
        let endpoint = try SSHPoolLiveEndpoint(configuration, port: configuration.limitedPort)
        let pool = RemuxSSHRootService()
        addTeardownBlock { await pool.closeAllConnectionsForTesting() }

        let first = try await endpoint.openEcho(on: pool)
        let second = try await endpoint.openEcho(on: pool)
        XCTAssertTrue(second.rootChannel === first.rootChannel)

        // The server allows two sessions per connection: the third is refused there and opens on a new one.
        let third = try await endpoint.openEcho(on: pool)
        XCTAssertFalse(third.rootChannel === first.rootChannel)
        let fourth = try await endpoint.openEcho(on: pool)
        XCTAssertTrue(fourth.rootChannel === third.rootChannel, "the overflow connection is pooled and reused")

        // The refusal left the first connection and its sessions alone.
        _ = try await first.roundTrip(0x41)
        _ = try await second.roundTrip(0x42)
        var entries = await pool.snapshot().entries(for: endpoint.key)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.isRefusingSessions, true)

        // A session closed on the first connection frees a place there.
        await first.close()
        entries = await pool.snapshot().entries(for: endpoint.key)
        XCTAssertEqual(entries.first?.isRefusingSessions, false)
        let fifth = try await endpoint.openEcho(on: pool)
        XCTAssertTrue(fifth.rootChannel === second.rootChannel)
        for echo in [second, third, fourth, fifth] { await echo.close() }
    }

    func testUnansweredOpenClosesTheConnectionAndOpensOnAFreshOne() async throws {
        let configuration = try SSHPoolLiveConfiguration.load()
        let relay = try await SSHPoolLiveRelay.start(host: configuration.host, port: configuration.port)
        addTeardownBlock { relay.close() }
        let endpoint = try SSHPoolLiveEndpoint(configuration, port: relay.port)
        let pool = RemuxSSHRootService()
        addTeardownBlock { await pool.closeAllConnectionsForTesting() }

        let open = try await endpoint.openEcho(on: pool)
        relay.stall()
        let start = ContinuousClock.now
        let reopening = Task { try await endpoint.openEcho(on: pool) }
        // Carry bytes again once the open's deadline has passed, so the fresh connection can sign in.
        try await Task.sleep(for: .seconds(Int64(RemuxSSHRoot.channelOpenDeadline.nanoseconds / 1_000_000_000) + 1))
        relay.resume()
        let reopened = try await reopening.value
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(elapsed, .seconds(10))
        XCTAssertLessThan(elapsed, .seconds(30))
        XCTAssertFalse(reopened.rootChannel === open.rootChannel)
        XCTAssertFalse(open.rootChannel.isActive, "the unanswered connection was closed as dead")
        _ = try await reopened.roundTrip(0x43)
        await reopened.close()
        await open.close()
    }

    func testConnectionCheckClosesAStalledConnectionAndKeepsAHealthyOne() async throws {
        let configuration = try SSHPoolLiveConfiguration.load()
        let relay = try await SSHPoolLiveRelay.start(host: configuration.host, port: configuration.port)
        addTeardownBlock { relay.close() }
        let stalledEndpoint = try SSHPoolLiveEndpoint(configuration, port: relay.port)
        let healthyEndpoint = try SSHPoolLiveEndpoint(configuration, port: configuration.port)
        let pool = RemuxSSHRootService()
        addTeardownBlock { await pool.closeAllConnectionsForTesting() }

        let stalled = try await stalledEndpoint.openEcho(on: pool)
        let healthy = try await healthyEndpoint.openEcho(on: pool)
        relay.stall()
        await pool.checkConnections(reason: "test")

        let deadline = ContinuousClock.now + .seconds(20)
        while stalled.rootChannel.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(stalled.rootChannel.isActive, "the stalled connection was closed")
        XCTAssertTrue(healthy.rootChannel.isActive)
        _ = try await healthy.roundTrip(0x44)
        relay.resume()
        await healthy.close()
        await stalled.close()
    }
}

/// The live server as the app sees a saved server: a trusted host key and a pooled interactive connection.
final class SSHPoolLiveEndpoint: @unchecked Sendable {
    let key: RemuxSSHRootKey
    let rootConfiguration: RemuxSSHRootConfiguration
    private let trustRoot: URL

    init(_ configuration: SSHPoolLiveConfiguration, port: Int) throws {
        let id = UUID()
        trustRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SSHPoolLiveTests-\(id.uuidString)")
        let store = TrustedHostStore(rootURL: trustRoot)
        let server = SavedServer(
            id: id,
            displayName: "ssh-pool-live",
            host: configuration.host,
            port: port,
            username: configuration.username,
            identityID: id
        )
        let keyParts = configuration.hostKey.split(separator: " ")
        guard keyParts.count >= 2 else {
            throw XCTSkip("hostKey must be an OpenSSH public key line")
        }
        try store.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: id,
                host: configuration.host,
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: String(keyParts[0]),
                receivedOpenSSHPublicKey: "\(keyParts[0]) \(keyParts[1])"
            )
        )
        let credential = SSHPrivateKeyCredential(privateKeyPEM: configuration.privateKeyPEM)
        let auth = try ResolvedSSHAuth.privateKey(
            username: configuration.username,
            credential: credential,
            identityID: id,
            displayLabel: "ssh-pool-live"
        )
        key = RemuxSSHRootKey(
            target: SessionTarget(
                server: server,
                workspace: SavedWorkspace(serverID: id, sessionName: "pool"),
                sshAuth: auth
            ),
            purpose: .interactive
        )
        let username = configuration.username
        rootConfiguration = RemuxSSHRootConfiguration(
            host: configuration.host,
            port: port,
            authenticationMethod: {
                try SSHAuthenticationMethodFactory.make(username: username, credential: .privateKey(credential))
            },
            hostKeyValidator: store.validator(for: server),
            connectTimeout: .seconds(20)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: trustRoot)
    }

    /// A terminal-like session (`exec cat` on a pty) on the pool's connection, as a tmux session opens one.
    func openEcho(on pool: RemuxSSHRootService) async throws -> SSHPoolLiveEcho {
        let claimed = try await pool.claimRoot(
            for: key,
            configuration: rootConfiguration,
            trace: RemuxTransportStartupTrace(flowID: nil)
        )
        let echo = SSHPoolLiveEcho()
        let connection = try await RemuxSSHExecSession.open(
            using: claimed,
            command: "exec cat",
            pseudoTerminal: true,
            trace: RemuxTransportStartupTrace(flowID: nil),
            onData: { [echo] _, data in echo.receive(data) },
            onFinish: { [echo] _, error in echo.fail(error ?? SSHPoolLiveError("the session closed")) }
        )
        echo.attach(connection, root: claimed)
        _ = try await echo.roundTrip(0x2E)
        return echo
    }
}

struct SSHPoolLiveError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One session's keystroke round trip: a byte written comes back from `cat`.
final class SSHPoolLiveEcho: @unchecked Sendable {
    private let lock = NIOLock()
    private var connection: RemuxSSHExecConnection?
    private var root: RemuxSSHClaimedRoot?
    private var waiter: (byte: UInt8, continuation: CheckedContinuation<Void, Error>)?
    private var failure: Error?

    /// The connection the session ended up on.
    var rootChannel: Channel {
        lock.withLock { root!.sshRoot.rootChannel }
    }

    fileprivate func attach(_ connection: RemuxSSHExecConnection, root: RemuxSSHClaimedRoot) {
        lock.withLock {
            self.connection = connection
            self.root = root
        }
    }

    func roundTrip(_ byte: UInt8, timeout: Duration = .seconds(15)) async throws -> Duration {
        let start = ContinuousClock.now
        let watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.fail(SSHPoolLiveError("no echo within \(timeout)"))
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let (connection, failure) = lock.withLock { () -> (RemuxSSHExecConnection?, Error?) in
                if let failure { return (nil, failure) }
                waiter = (byte, continuation)
                return (self.connection, nil)
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            connection?.write(Data([byte])) { [weak self] error in
                if let error { self?.fail(error) }
            }
        }
        return ContinuousClock.now - start
    }

    func close() async {
        let connection = lock.withLock { self.connection }
        await connection?.close(disposition: .reusable)
    }

    fileprivate func receive(_ data: Data) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let waiter, data.contains(waiter.byte) else { return nil }
            self.waiter = nil
            return waiter.continuation
        }
        continuation?.resume()
    }

    fileprivate func fail(_ error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            failure = failure ?? error
            let continuation = waiter?.continuation
            waiter = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }
}

/// A TCP relay in the test process between the app's SSH code and the server. `stall()` stops it carrying bytes
/// either way, as a dead path or a server that stopped answering does: what the app sends waits in socket buffers
/// and nothing comes back. `resume()` carries them again.
final class SSHPoolLiveRelay: @unchecked Sendable {
    let port: Int
    private let listener: Channel
    private let host: String
    private let targetPort: Int
    private let state = NIOLockedValueBox((stalled: false, channels: [ObjectIdentifier: Channel]()))

    private init(port: Int, listener: Channel, host: String, targetPort: Int) {
        self.port = port
        self.listener = listener
        self.host = host
        self.targetPort = targetPort
    }

    /// Accepts on a free local port and bridges each connection to `host:port` once it is active, as the app's
    /// live-web listener does.
    static func start(host: String, port targetPort: Int) async throws -> SSHPoolLiveRelay {
        let accepted = NIOLockedValueBox<(@Sendable (Channel) -> Void)?>(nil)
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(SSHPoolLiveAcceptHandler { channel in
                    accepted.withLockedValue { $0 }?(channel)
                })
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let relay = SSHPoolLiveRelay(
            port: listener.localAddress?.port ?? 0,
            listener: listener,
            host: host,
            targetPort: targetPort
        )
        accepted.withLockedValue { $0 = { [weak relay] channel in relay?.bridge(channel) } }
        return relay
    }

    private func bridge(_ inbound: Channel) {
        ClientBootstrap(group: inbound.eventLoop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: host, port: targetPort)
            .flatMap { outbound in
                inbound.pipeline.addHandler(SSHPoolLiveRelayHandler(peer: outbound)).flatMap {
                    outbound.pipeline.addHandler(SSHPoolLiveRelayHandler(peer: inbound))
                }.map { outbound }
            }
            .whenComplete { [weak self] result in
                switch result {
                case .success(let outbound):
                    self?.track(inbound)
                    self?.track(outbound)
                case .failure:
                    inbound.close(promise: nil)
                }
            }
    }

    func stall() { setStalled(true) }
    func resume() { setStalled(false) }

    func close() {
        listener.close(promise: nil)
        for channel in state.withLockedValue({ Array($0.channels.values) }) {
            channel.close(promise: nil)
        }
    }

    fileprivate func track(_ channel: Channel) {
        let stalled = state.withLockedValue { state -> Bool in
            state.channels[ObjectIdentifier(channel)] = channel
            return state.stalled
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.state.withLockedValue { _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
        }
        if !stalled {
            channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess { channel.read() }
        }
    }

    private func setStalled(_ stalled: Bool) {
        let channels = state.withLockedValue { state -> [Channel] in
            state.stalled = stalled
            return Array(state.channels.values)
        }
        for channel in channels {
            channel.setOption(ChannelOptions.autoRead, value: !stalled).whenSuccess {
                if !stalled { channel.read() }
            }
        }
    }
}

private final class SSHPoolLiveAcceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let onActive: @Sendable (Channel) -> Void

    init(onActive: @escaping @Sendable (Channel) -> Void) {
        self.onActive = onActive
    }

    func channelActive(context: ChannelHandlerContext) {
        onActive(context.channel)
        context.fireChannelActive()
    }
}

private final class SSHPoolLiveRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.write(Self.unwrapInboundIn(data), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
