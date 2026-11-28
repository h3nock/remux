@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

/// What a server connection carries. Terminal work and bulk transfers use separate connections: SSH sends every
/// channel down one TCP stream in order, so an upload's queued megabytes would sit ahead of each keystroke, and a
/// preview's download ahead of each screen update.
enum RemuxSSHConnectionPurpose: String, Hashable, Sendable {
    /// tmux control, Herdr bridges and popups, discovery, access checks.
    case interactive
    /// Attachment uploads, file and page previews, live-web forwards.
    case transfer
}

struct RemuxSSHRootKey: Hashable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    let purpose: RemuxSSHConnectionPurpose
    private let authFingerprint: String

    init(target: SessionTarget, purpose: RemuxSSHConnectionPurpose) {
        self.serverID = target.server.id
        self.host = target.server.host
        self.port = target.server.port
        self.username = target.sshAuth.username
        self.purpose = purpose
        self.authFingerprint = target.sshAuth.authFingerprint
    }
}

struct RemuxSSHRootConfiguration: Sendable {
    let host: String
    let port: Int
    /// Reads and decodes the credentials, once per connection attempt and before it starts.
    let prepareAuthentication: @Sendable () throws -> SSHPreparedAuthentication
    let hostKeyValidator: SSHHostKeyValidator
    /// For the TCP connect, and then for SSH to get through key exchange and sign-in.
    let connectTimeout: TimeAmount
    /// For a Tailscale check once it's shown, which waits on the user in a browser. Nil when none can come.
    let verificationTimeout: TimeAmount?
    private(set) var onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?

    init(
        host: String,
        port: Int,
        prepareAuthentication: @escaping @Sendable () throws -> SSHPreparedAuthentication,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount,
        verificationTimeout: TimeAmount? = nil,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.prepareAuthentication = prepareAuthentication
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.verificationTimeout = verificationTimeout
        self.onTailscaleSSHCheck = onTailscaleSSHCheck
    }

    /// The same sign-in, asking no one anything: a Tailscale SSH check is given up the moment the server presents
    /// it, instead of being shown. For a connection signed in on a guess (`RemuxSSHRootService.checkConnections`),
    /// which must never bring up a prompt. Nothing else in a sign-in asks: keys sign without interaction and host
    /// keys are checked against the ones already trusted.
    var askingNoOne: RemuxSSHRootConfiguration {
        var quiet = self
        quiet.onTailscaleSSHCheck = { event in
            if case .presented(let request) = event { request.cancel() }
        }
        return quiet
    }
}

struct RemuxSSHDirectTCPIPTarget: Equatable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) throws {
        guard !host.isEmpty else {
            throw RemuxSSHDirectTCPIPTargetError.invalidHost
        }
        guard (1...Int(UInt16.max)).contains(port) else {
            throw RemuxSSHDirectTCPIPTargetError.invalidPort(port)
        }

        self.host = host
        self.port = port
    }

    func channelType(originatorAddress: SocketAddress) -> SSHChannelType {
        .directTCPIP(.init(
            targetHost: host,
            targetPort: port,
            originatorAddress: originatorAddress
        ))
    }
}

enum RemuxSSHDirectTCPIPTargetError: Error, Equatable, Sendable {
    case invalidHost
    case invalidPort(Int)
}

enum RemuxSSHRootReadiness: Equatable, Sendable {
    case connecting
    case ready

    var traceValue: String {
        switch self {
        case .connecting:
            "connecting"
        case .ready:
            "ready"
        }
    }
}

struct RemuxSSHRootServiceSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let generation: UUID
        let readiness: RemuxSSHRootReadiness
        let activeLeaseCount: Int
        let reservationCount: Int
        let isIdleCloseScheduled: Bool
        let isRefusingSessions: Bool
        let isSuspect: Bool
        let isSpare: Bool
    }

    /// Roots evicted from the pool that still have live leases
    /// draining (multi-lease invalidation).
    let retiredCount: Int

    fileprivate let entries: [RemuxSSHRootKey: [Entry]]

    var entryCount: Int {
        entries.values.reduce(0) { $0 + $1.count }
    }

    /// The key's first connection, the one new consumers try first.
    func entry(for key: RemuxSSHRootKey) -> Entry? {
        entries[key]?.first
    }

    /// The key's connections, in the order new consumers try them.
    func entries(for key: RemuxSSHRootKey) -> [Entry] {
        entries[key] ?? []
    }
}

final class RemuxSSHRoot: @unchecked Sendable {
    /// How long a session open may wait while nothing at all arrives from the server before the connection counts
    /// as dead; the same window Herdr's client gives an unanswered ping. An open can wait longer on a connection
    /// that is busy (behind a slow link's queued upload, say), but bytes keep arriving there, so it isn't cut off.
    static let channelOpenDeadline: TimeAmount = .seconds(10)

    let rootChannel: Channel
    private let childChannelOpener: RemuxSSHChildChannelOpener
    /// When bytes last arrived from the server on this connection, whatever channel they were for.
    private let inboundActivity: RemuxLastActivity

    fileprivate init(
        rootChannel: Channel,
        childChannelOpener: RemuxSSHChildChannelOpener,
        inboundActivity: RemuxLastActivity
    ) {
        self.rootChannel = rootChannel
        self.childChannelOpener = childChannelOpener
        self.inboundActivity = inboundActivity
    }

    func close() async {
        do {
            try await rootChannel.close()
        } catch {
            NSLog("Remux authenticated SSH root close failed: %@", String(describing: error))
        }
    }

    /// Whether anything has arrived from the server since `moment`, on any of this connection's channels.
    func hasHeard(since moment: NIODeadline) -> Bool {
        inboundActivity.hasRecorded(since: moment)
    }

    /// With `readsOnDemand`, the channel delivers data only after `read()`. It is set before the
    /// channel activates, because activation already issues a read when reads are automatic.
    func openSessionChannel(
        trace: RemuxTransportStartupTrace,
        readsOnDemand: Bool = false
    ) async throws -> Channel {
        try await withOpenDeadline(
            { [childChannelOpener, rootChannel] in
                try await childChannelOpener.openSessionChannel(
                    on: rootChannel,
                    trace: trace,
                    readsOnDemand: readsOnDemand
                )
            },
            cleanupLateSuccess: { channel in channel.close(promise: nil) }
        )
    }

    /// No deadline here: the server confirms a forward only once it has reached the forward's target, so a slow
    /// target is no sign of a dead connection.
    func openDirectTCPIPChannel(
        to target: RemuxSSHDirectTCPIPTarget,
        originatorAddress: SocketAddress,
        trace: RemuxTransportStartupTrace,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        try await childChannelOpener.openDirectTCPIPChannel(
            on: rootChannel,
            target: target,
            originatorAddress: originatorAddress,
            trace: trace,
            channelInitializer: channelInitializer
        )
    }

    /// Runs `open` (a session channel open, or a protocol started on one, such as SFTP) under
    /// `channelOpenDeadline`. A connection that gets nothing from the server for that long is closed, so every
    /// session on it fails now and reconnects instead of waiting minutes for TCP to give up; what `open` produces
    /// after that goes to `cleanupLateSuccess`.
    func withOpenDeadline<Value: Sendable>(
        _ open: @escaping @Sendable () async throws -> Value,
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void
    ) async throws -> Value {
        do {
            return try await RemuxOperationTimeout.run(
                timeout: Self.channelOpenDeadline,
                timeoutError: RemuxSSHRootServiceError.channelOpenTimedOut,
                extendWhile: { [inboundActivity] windowStart in inboundActivity.hasRecorded(since: windowStart) },
                operation: open,
                cleanupLateSuccess: cleanupLateSuccess
            )
        } catch let error as RemuxSSHRootServiceError where error == .channelOpenTimedOut {
            GhosttyRuntimeTrace.latency("sshRoot.open.unanswered closing")
            await close()
            throw error
        }
    }

    /// Whether the connection still answers: opens and closes a session channel. Any answer proves it alive,
    /// including a refusal (the server is at its session limit); an unanswered open closes the connection.
    func checkAlive(reason: String) async {
        guard rootChannel.isActive else { return }
        do {
            let channel = try await openSessionChannel(trace: RemuxTransportStartupTrace(flowID: nil))
            channel.close(promise: nil)
        } catch let error as RemuxSSHRootServiceError where error == .channelOpenTimedOut {
            GhosttyRuntimeTrace.latency("sshRoot.check dead reason=\(reason)")
        } catch {
            // A refusal is an answer, and any other failure means the connection is already going away.
        }
    }
}

/// First in a connection's pipeline, so it sees every read from the socket.
private final class RemuxSSHInboundActivityHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let activity: RemuxLastActivity

    init(activity: RemuxLastActivity) {
        self.activity = activity
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        activity.record()
        context.fireChannelRead(data)
    }
}

private final class RemuxSSHChildChannelOpener: @unchecked Sendable {
    private let sshHandler: NIOSSHHandler

    init(sshHandler: NIOSSHHandler) {
        self.sshHandler = sshHandler
    }

    func openSessionChannel(
        on rootChannel: Channel,
        trace: RemuxTransportStartupTrace,
        readsOnDemand: Bool
    ) async throws -> Channel {
        try await openChildChannel(
            on: rootChannel,
            type: .session,
            trace: trace,
            traceStage: "sessionChannel.open",
            channelInitializer: { channel in
                readsOnDemand
                    ? channel.setOption(ChannelOptions.autoRead, value: false)
                    : channel.eventLoop.makeSucceededFuture(())
            }
        )
    }

    func openDirectTCPIPChannel(
        on rootChannel: Channel,
        target: RemuxSSHDirectTCPIPTarget,
        originatorAddress: SocketAddress,
        trace: RemuxTransportStartupTrace,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        try await openChildChannel(
            on: rootChannel,
            type: target.channelType(originatorAddress: originatorAddress),
            trace: trace,
            traceStage: "directTCPIPChannel.open",
            channelInitializer: channelInitializer
        )
    }

    private func openChildChannel(
        on rootChannel: Channel,
        type requestedType: SSHChannelType,
        trace: RemuxTransportStartupTrace,
        traceStage: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        try await trace.stage(traceStage) {
            try await rootChannel.eventLoop.flatSubmit { [self, eventLoop = rootChannel.eventLoop] in
                let promise = eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(
                    promise,
                    channelType: requestedType
                ) { channel, openedType in
                    guard openedType == requestedType else {
                        return channel.eventLoop.makeFailedFuture(
                            RemuxSSHRootServiceError.unsupportedInboundChannel
                        )
                    }

                    return channelInitializer(channel)
                }
                return promise.futureResult.always { _ in
                    // Recorded on the event loop the instant the open
                    // completes: the gap to the trace stage ending is
                    // Swift-concurrency resume lag, not wire time.
                    trace.event("\(traceStage).wireComplete")
                }
            }.get()
        }
    }
}

enum RemuxSSHRootLeaseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

/// A saved server whose settings can't make a connection, found before any network work. The editor checks them, but
/// a server saved another way (an older build, a restored backup) can still hold one.
enum RemuxSSHConfigurationError: LocalizedError, Equatable {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            TmuxConnectionDraftValidator.portRangeMessage
        }
    }
}

/// A connection that failed before signing in. The bootstrap is the one place that knows a failure happened while
/// connecting, so it says so here instead of leaving callers to infer it from the transport's error types.
enum RemuxSSHConnectError: LocalizedError {
    /// The TCP connection couldn't be opened: the name didn't resolve, no route, refused, timed out, and the like.
    case unreachable(underlying: any Error)
    /// The TCP connection opened, but the server didn't finish signing in before the connect allowance ran out.
    case noSSHResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "Remux couldn't connect to the server."
        case .noSSHResponse:
            "The server accepted the connection but didn't finish signing in in time."
        }
    }

    /// What the system reported, in its own words, for the details line.
    var reason: String? {
        switch self {
        case .unreachable(let underlying):
            Self.systemReason(underlying)
        case .noSSHResponse:
            errorDescription
        }
    }

    private static func systemReason(_ error: any Error) -> String? {
        if let error = error as? IOError {
            return String(cString: strerror(error.errnoCode))
        }
        if let error = error as? NIOConnectionError {
            if let attempt = error.connectionErrors.last {
                return systemReason(attempt.error)
            }
            guard let lookupError = error.dnsAError ?? error.dnsAAAAError else { return nil }
            guard let resolverReason = (lookupError as? SocketAddressError.UnknownHost)?.errorDescription,
                  let first = resolverReason.first else {
                return "The server's address couldn't be looked up."
            }
            return first.uppercased() + resolverReason.dropFirst()
        }
        if case .connectTimeout? = error as? ChannelError {
            return "The connection timed out."
        }
        return nil
    }
}

enum RemuxSSHRootServiceError: LocalizedError, Equatable, CustomStringConvertible {
    case unsupportedInboundChannel
    case closed
    case stalePreparedRoot
    case channelOpenTimedOut

    var description: String {
        switch self {
        case .unsupportedInboundChannel:
            return "unsupportedInboundChannel"
        case .closed:
            return "closed"
        case .stalePreparedRoot:
            return "stalePreparedRoot"
        case .channelOpenTimedOut:
            return "channelOpenTimedOut"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .closed:
            return "The SSH root has already been closed."
        case .stalePreparedRoot:
            return "The prepared SSH root reservation is no longer valid."
        case .channelOpenTimedOut:
            return "The server didn't answer in time."
        }
    }
}

/// Why a session couldn't open on a connection, when another of the pool's connections to the same server may still
/// take it. Nothing has run on the server in either case, so opening again elsewhere is safe.
private enum RemuxSSHSessionOpenFailure {
    /// The server refused the session on this connection; OpenSSH does this at MaxSessions (10 by default) sessions
    /// per connection. The connection itself is fine.
    case refused
    /// The connection went away during the open: it didn't answer and was closed as dead, or it closed for another
    /// reason (a connection check found it dead) while the open waited.
    case connectionLost

    init?(_ error: Error, on root: RemuxSSHRoot) {
        if error is CancellationError {
            // The consumer stopped wanting the session; it goes nowhere else.
            return nil
        } else if let error = error as? NIOSSHError, error.type == .channelSetupRejected {
            self = .refused
        } else if !root.rootChannel.isActive {
            self = .connectionLost
        } else {
            return nil
        }
    }
}

fileprivate final class RemuxSSHRootLease: @unchecked Sendable {
    private let connection: RemuxSSHRoot

    private let pool: RemuxSSHRootService
    private let key: RemuxSSHRootKey
    private let generation: UUID
    private let configuration: RemuxSSHRootConfiguration
    private let lock = NIOLock()
    private var isReleased = false

    init(
        connection: RemuxSSHRoot,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        configuration: RemuxSSHRootConfiguration
    ) {
        self.connection = connection
        self.pool = pool
        self.key = key
        self.generation = generation
        self.configuration = configuration
    }

    func release(_ disposition: RemuxSSHRootLeaseDisposition) async {
        guard markReleased() else { return }

        await pool.releaseConnection(
            connection,
            for: key,
            generation: generation,
            disposition: disposition
        )
    }

    /// Gives the lease back after the server refused a session on this connection: the connection stays in the
    /// pool, but new consumers go elsewhere until one of its other leases is given back. Returns whether other
    /// leases remain on it, that is, whether the refusal was about the sessions it already carries.
    func releaseAfterRefusal() async -> Bool {
        guard markReleased() else { return false }

        return await pool.releaseConnectionAfterRefusal(
            connection,
            for: key,
            generation: generation
        )
    }

    /// A place on another of the pool's connections to the same server, signing one in when none can take it.
    func claimAnother(trace: RemuxTransportStartupTrace) async throws -> RemuxSSHClaimedRoot {
        try await pool.claimRoot(for: key, configuration: configuration, trace: trace)
    }

    private func markReleased() -> Bool {
        lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
    }
}

/// One authentication of an SSH root. The attempt records its own outcome as it finishes, so whoever holds it
/// can tell at once whether its result is in, before the pool's observer of the same attempt has run.
struct RemuxSSHRootAttempt: Sendable {
    private enum Outcome: Sendable {
        case pending
        case authenticated(RemuxSSHRoot)
        case failed
    }

    let task: Task<RemuxSSHRoot, Error>
    private let outcome: NIOLockedValueBox<Outcome>

    init(authenticate: @escaping @Sendable () async throws -> RemuxSSHRoot) {
        let outcome = NIOLockedValueBox(Outcome.pending)
        self.outcome = outcome
        task = Task.detached(priority: .userInitiated) {
            do {
                let root = try await authenticate()
                outcome.withLockedValue { $0 = .authenticated(root) }
                return root
            } catch {
                outcome.withLockedValue { $0 = .failed }
                throw error
            }
        }
    }

    var isFinished: Bool {
        outcome.withLockedValue { outcome in
            if case .pending = outcome { return false }
            return true
        }
    }

    /// The root it signed in, once it has.
    var root: RemuxSSHRoot? {
        outcome.withLockedValue { outcome in
            if case .authenticated(let root) = outcome { return root }
            return nil
        }
    }

    /// Whether the attempt can no longer serve anyone: it failed, or the root it made has closed since.
    var isSpent: Bool {
        outcome.withLockedValue { outcome in
            switch outcome {
            case .pending:
                return false
            case .failed:
                return true
            case .authenticated(let root):
                return !root.rootChannel.isActive
            }
        }
    }
}

struct RemuxSSHPreparedRoot {
    let trace: RemuxTransportStartupTrace
    private let ownership: RemuxSSHPreparedRootOwnership
    private let cancelAuthenticationOnClose: Bool
    private let attempt: RemuxSSHRootAttempt

    fileprivate static func pooled(
        trace: RemuxTransportStartupTrace,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID,
        configuration: RemuxSSHRootConfiguration,
        attempt: RemuxSSHRootAttempt
    ) -> RemuxSSHPreparedRoot {
        RemuxSSHPreparedRoot(
            trace: trace,
            ownership: .pooled(
                pool: pool,
                key: key,
                generation: generation,
                reservationID: reservationID,
                configuration: configuration
            ),
            cancelAuthenticationOnClose: false,
            attempt: attempt
        )
    }

    static func dedicated(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHPreparedRoot {
        RemuxSSHPreparedRoot(
            trace: trace,
            ownership: .dedicated,
            cancelAuthenticationOnClose: true,
            attempt: authenticationAttempt(configuration: configuration, trace: trace)
        )
    }

    /// Whether the root's authentication had its result when this was read.
    var isFinished: Bool {
        attempt.isFinished
    }

    func sshRoot() async throws -> RemuxSSHRoot {
        try await attempt.task.value
    }

    func claim(
        _ sshRoot: RemuxSSHRoot,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHClaimedRoot {
        switch ownership {
        case .dedicated:
            return RemuxSSHClaimedRoot(
                sshRoot: sshRoot,
                lease: nil
            )

        case .pooled(let pool, let key, let generation, let reservationID, let configuration):
            let lease = try await trace.stage("sshRoot.pool.lease") {
                try await pool.leaseConnection(
                    sshRoot,
                    for: key,
                    generation: generation,
                    reservationID: reservationID,
                    configuration: configuration
                )
            }
            return RemuxSSHClaimedRoot(
                sshRoot: sshRoot,
                lease: lease
            )
        }
    }

    func cancelAndCleanup() async {
        switch ownership {
        case .pooled(let pool, let key, let generation, let reservationID, _):
            await pool.releaseReservation(
                for: key,
                generation: generation,
                reservationID: reservationID
            )
            return

        case .dedicated:
            break
        }

        guard cancelAuthenticationOnClose else { return }

        attempt.task.cancel()
        do {
            let sshRoot = try await attempt.task.value
            await sshRoot.close()
        } catch is CancellationError {
            GhosttyRuntimeTrace.latency("transport.prepare.cleanup cancelled")
        } catch {
            NSLog("Remux prepared SSH connection cleanup failed: %@", String(describing: error))
        }
    }
}

private enum RemuxSSHPreparedRootOwnership {
    case dedicated
    case pooled(
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID,
        configuration: RemuxSSHRootConfiguration
    )
}

/// A consumer's place on a server connection. Opening a session can move it, once, to another of the pool's
/// connections to the same server (see `openSession`), so `sshRoot` is whichever connection it holds now.
final class RemuxSSHClaimedRoot: @unchecked Sendable {
    private let lock = NIOLock()
    private var root: RemuxSSHRoot
    private var lease: RemuxSSHRootLease?
    private var isReleased = false

    fileprivate init(
        sshRoot: RemuxSSHRoot,
        lease: RemuxSSHRootLease?
    ) {
        self.root = sshRoot
        self.lease = lease
    }

    var sshRoot: RemuxSSHRoot {
        lock.withLock { root }
    }

    func releaseAfterFailedStart() async {
        await release(.invalidated)
    }

    func release(_ disposition: RemuxSSHRootLeaseDisposition) async {
        let (root, lease) = lock.withLock { () -> (RemuxSSHRoot, RemuxSSHRootLease?) in
            isReleased = true
            return (self.root, self.lease)
        }
        if let lease {
            await lease.release(disposition)
        } else {
            await root.close()
        }
    }

    /// With `readsOnDemand`, the channel delivers data only after `read()` (see `RemuxSSHRoot.openSessionChannel`).
    func openSessionChannel(
        trace: RemuxTransportStartupTrace,
        readsOnDemand: Bool = false
    ) async throws -> Channel {
        try await openSession(trace: trace) { root in
            try await root.openSessionChannel(trace: trace, readsOnDemand: readsOnDemand)
        }
    }

    /// Moves after refusals within one open: enough for a burst of consumers to spread over the connections they
    /// need, while a server that keeps refusing can't make the app sign in again and again.
    private static let maximumMovesAfterRefusal = 4

    /// Runs `open`, which starts something that takes one of the server's sessions on this connection (an exec
    /// channel, a subsystem such as SFTP). When a connection that holds other sessions refuses it, the place moves to
    /// another pooled connection to the same server and `open` runs there; when the connection goes away during the
    /// open, the place moves once to a fresh one. A refused place always goes back as refused, so the full connection
    /// stays in the pool with its sessions, whatever the consumer does with the error. A refusal on a connection with
    /// nothing else on it means the server refuses sessions outright, and a dedicated connection has nowhere to move:
    /// their failures stand.
    func openSession<Value: Sendable>(
        trace: RemuxTransportStartupTrace,
        _ open: @escaping @Sendable (RemuxSSHRoot) async throws -> Value
    ) async throws -> Value {
        var movesAfterRefusal = 0
        var movedAfterLoss = false
        while true {
            let root = sshRoot
            do {
                return try await open(root)
            } catch {
                switch RemuxSSHSessionOpenFailure(error, on: root) {
                case .refused?:
                    let mayMove = movesAfterRefusal < Self.maximumMovesAfterRefusal
                    guard try await moveAfterRefusal(mayMove: mayMove, trace: trace) else { throw error }
                    movesAfterRefusal += 1
                case .connectionLost?:
                    guard !movedAfterLoss, try await moveAfterLoss(trace: trace) else { throw error }
                    movedAfterLoss = true
                case nil:
                    throw error
                }
            }
        }
    }

    private func moveAfterRefusal(mayMove: Bool, trace: RemuxTransportStartupTrace) async throws -> Bool {
        guard let lease = currentLease() else { return false }
        let othersOnConnection = await lease.releaseAfterRefusal()
        guard mayMove, othersOnConnection else { return false }
        return try await move(from: lease, reason: "refused", trace: trace)
    }

    private func moveAfterLoss(trace: RemuxTransportStartupTrace) async throws -> Bool {
        guard let lease = currentLease() else { return false }
        await lease.release(.invalidated)
        return try await move(from: lease, reason: "connectionLost", trace: trace)
    }

    /// The lease to move from, unless this place has none (a dedicated connection) or was given back.
    private func currentLease() -> RemuxSSHRootLease? {
        lock.withLock { isReleased ? nil : lease }
    }

    private func move(
        from lease: RemuxSSHRootLease,
        reason: String,
        trace: RemuxTransportStartupTrace
    ) async throws -> Bool {
        trace.event("sshRoot.pool.move", fields: ["reason": reason])
        let next = try await lease.claimAnother(trace: trace)
        let (nextRoot, nextLease) = next.handOver()
        let stillWanted = lock.withLock { () -> Bool in
            guard !isReleased else { return false }
            root = nextRoot
            self.lease = nextLease
            return true
        }
        guard stillWanted else {
            // Released while moving: the new place is given straight back.
            await next.release(.reusable)
            throw CancellationError()
        }
        return true
    }

    /// The connection and lease, for another claimed root to take over; this one is not used afterwards.
    private func handOver() -> (RemuxSSHRoot, RemuxSSHRootLease?) {
        lock.withLock { (root, lease) }
    }
}

actor RemuxSSHRootService {
    nonisolated let tailscaleSSHCheckChallengeBroker = TailscaleSSHCheckChallengeBroker()

    /// One pooled connection. A server usually has one per purpose; another is signed in only when the server
    /// refuses a session on every connection it has (see `isRefusingSessions`), or beside one a check suspects
    /// (see `checkConnections`).
    private struct Entry {
        let key: RemuxSSHRootKey
        let generation: UUID
        let attempt: RemuxSSHRootAttempt
        var activeLeaseCount: Int
        var reservationIDs: Set<UUID>
        var idleCloseTask: Task<Void, Never>?
        var readiness: RemuxSSHRootReadiness
        /// The server refused a session on this connection while it held its current leases (OpenSSH limits the
        /// sessions per connection). New consumers go to another connection until one of these leases is given back.
        var isRefusingSessions = false
        /// What the connection signed in with, so the pool can sign in another like it (`checkConnections`).
        let configuration: RemuxSSHRootConfiguration?
        /// When the probe of a check that then heard nothing for `suspicionDelay` began.
        var silentSince: NIODeadline?
        /// Signed in beside a suspect connection, asking no one anything. It takes consumers only once signed in, so
        /// a sign-in that needed the user (a Tailscale SSH check) fails the spare alone, never a consumer's open.
        var isSpare = false
        /// Given back as broken by one of its users while others still use it, or closed with sessions on it. It
        /// takes no new consumers and closes when its last lease goes. Closing it at once would let one session's
        /// channel failure kill healthy sessions beside it; a dead one drains fast, as each session fails and leaves.
        var isRetired = false

        /// Silent since a check's probe began: new consumers go to another connection, and the pool closes it once
        /// another connection to the server hears from it in that time. Any byte on it ends this.
        var isSuspect: Bool {
            guard let silentSince else { return false }
            return attempt.root?.hasHeard(since: silentSince) != true
        }
    }

    private struct EntrySnapshot: Sendable {
        let generation: UUID
        let attempt: RemuxSSHRootAttempt
        let didReuse: Bool
        let readiness: RemuxSSHRootReadiness
    }

    private enum LeaseEntryResult: Equatable {
        case leased
        case busy
        case stale(closeConnection: Bool)
    }

    private enum ReleaseEntryResult {
        /// Lease returned; the connection stays open.
        case retained
        /// Caller owns closing the connection (last lease of a retired
        /// root, or a root the pool no longer tracks).
        case close
    }

    private let idleTimeout: Duration
    /// Pooled connections by generation, and each key's generations in the order consumers try them: SSH
    /// multiplexes every consumer's channels over one connection, so a key gets another only when the server
    /// refuses sessions on the ones it has.
    private var entries: [UUID: Entry] = [:]
    private var generationsByKey: [RemuxSSHRootKey: [UUID]] = [:]

    init(idleTimeout: Duration = .seconds(120)) {
        self.idleTimeout = idleTimeout
    }

    func snapshot() -> RemuxSSHRootServiceSnapshot {
        RemuxSSHRootServiceSnapshot(
            retiredCount: entries.values.filter(\.isRetired).count,
            entries: generationsByKey.mapValues { generations in
                generations.compactMap { entries[$0] }.filter { !$0.isRetired }.map { entry in
                    RemuxSSHRootServiceSnapshot.Entry(
                        generation: entry.generation,
                        readiness: entry.readiness,
                        activeLeaseCount: entry.activeLeaseCount,
                        reservationCount: entry.reservationIDs.count,
                        isIdleCloseScheduled: entry.idleCloseTask != nil,
                        isRefusingSessions: entry.isRefusingSessions,
                        isSuspect: entry.isSuspect,
                        isSpare: entry.isSpare
                    )
                }
            }
        )
    }

    /// How long a check may hear nothing from a connection before the pool stops trusting it. A live answer takes one
    /// round trip plus the radio waking after the background: well under this on cellular, about half of it on a
    /// weak link with a late packet.
    static let suspicionDelay: Duration = .milliseconds(1500)

    /// Checks that each connection still answers (`RemuxSSHRoot.checkAlive`), all at once; run when the app comes
    /// back to the foreground and when the network path changes, the moments a connection most often dies without
    /// a word. A dead one is closed, so its sessions fail and reconnect now.
    ///
    /// The check's own deadline (`RemuxSSHRoot.channelOpenDeadline`) is long, because closing a connection that is
    /// only slow costs every session on it a reconnect. So a connection that hears nothing for `suspicionDelay`
    /// becomes suspect instead (`Entry.isSuspect`): new consumers go elsewhere, and unless another connection to the
    /// server is already signing in, a spare signs in beside it, asking no one anything. Once another connection to
    /// the server has heard from it since the suspect's probe began (the spare's sign-in, a consumer's, or one already
    /// open), the suspect is dead: the server is reachable over the network as it is now, just not over this
    /// connection. It is closed, and its sessions reconnect onto the one that heard. A connection that is alive but
    /// silent that long (its own resends backed off, say) is closed too, and its sessions pay that reconnect. Any byte
    /// on the suspect before then keeps it, and an unused spare closes when idle. A spare whose sign-in fails, for
    /// instance because the server wants a Tailscale SSH check, leaves the suspect to the next sign-in, the next
    /// check, or the deadline.
    func checkConnections(reason: String) {
        let ready = entries.values.filter { $0.readiness == .ready }
        let retired = ready.filter(\.isRetired).count
        GhosttyRuntimeTrace.latency("sshRoot.pool.check reason=\(reason) roots=\(ready.count) retired=\(retired)")
        // Retired connections too: they take no new consumers, but their sessions wait on them like any others.
        for entry in ready {
            let (key, generation, task) = (entry.key, entry.generation, entry.attempt.task)
            Task.detached(priority: .userInitiated) {
                guard let root = try? await task.value else { return }
                await self.check(root, key: key, generation: generation, reason: reason)
            }
        }
    }

    private nonisolated func check(
        _ root: RemuxSSHRoot,
        key: RemuxSSHRootKey,
        generation: UUID,
        reason: String
    ) async {
        let start = NIODeadline.now()
        Task { await root.checkAlive(reason: reason) }
        try? await Task.sleep(for: Self.suspicionDelay)
        if !root.hasHeard(since: start), root.rootChannel.isActive {
            await suspect(key: key, generation: generation, silentSince: start, reason: reason)
        }
    }

    /// Marks the connection suspect, closes it at once if another connection to the server has already heard from
    /// it in the silence, and otherwise makes sure a sign-in to the server is under way: another one signing in (a
    /// spare or a consumer's), or a new spare. A suspect already marked keeps its earlier start, and a later check
    /// starts a new spare once the last one has failed.
    private func suspect(key: RemuxSSHRootKey, generation: UUID, silentSince start: NIODeadline, reason: String) {
        // A sign-in that already failed is still listed until its observer runs; it would count as under way.
        removeSpentEntries(for: key)
        guard var entry = entries[generation] else { return }
        if !entry.isSuspect {
            entry.silentSince = start
            entries[generation] = entry
            GhosttyRuntimeTrace.latency("sshRoot.pool.suspect reason=\(reason)")
        }
        closeSuspectsAnotherConnectionHeardOver(for: key)
        guard entries[generation]?.isSuspect == true,
              !orderedEntries(for: key).contains(where: { $0.readiness == .connecting }),
              let configuration = entry.configuration else {
            return
        }
        GhosttyRuntimeTrace.latency("sshRoot.pool.spare reason=\(reason)")
        var spare = addEntry(
            for: key,
            configuration: configuration.askingNoOne,
            trace: RemuxTransportStartupTrace(flowID: nil),
            reservationID: nil
        )
        spare.isSpare = true
        entries[spare.generation] = spare
    }

    /// Closes each suspect connection of `key` that another of its connections has heard from the server over since
    /// the suspect went silent. Run at suspicion and whenever a connection to the server signs in.
    private func closeSuspectsAnotherConnectionHeardOver(for key: RemuxSSHRootKey) {
        let connections = orderedEntries(for: key).compactMap { entry in entry.attempt.root.map { (entry, $0) } }
        for (entry, root) in connections {
            guard entry.isSuspect, let silentSince = entry.silentSince else { continue }
            let heardOverAnother = connections.contains { other, otherRoot in
                other.generation != entry.generation && !other.isSuspect && otherRoot.rootChannel.isActive
                    && otherRoot.hasHeard(since: silentSince)
            }
            guard heardOverAnother else { continue }
            GhosttyRuntimeTrace.latency("sshRoot.pool.cutover")
            root.rootChannel.close(promise: nil)
            // Out of the pool now, not when the close lands: no new consumer or spare is made for it meanwhile.
            rootChannelClosed(for: key, generation: entry.generation)
        }
    }

    private static func takesConsumers(_ entry: Entry) -> Bool {
        !entry.isRetired && !entry.isRefusingSessions && !entry.isSuspect
            && (!entry.isSpare || entry.readiness == .ready)
    }

    func prewarmConnection(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace,
        reason: String
    ) {
        let snapshot = entrySnapshot(
            for: key,
            configuration: configuration,
            trace: trace
        )
        let eventPrefix = snapshot.didReuse ? "sshRoot.prewarm.hit" : "sshRoot.prewarm.miss"
        trace.event(
            eventPrefix,
            fields: poolTraceFields(key: key, reason: reason, readiness: snapshot.readiness)
        )

        guard snapshot.readiness == .connecting else { return }

        Task {
            do {
                _ = try await snapshot.attempt.task.value
                trace.event(
                    "sshRoot.prewarm.ready",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .ready)
                )
            } catch is CancellationError {
                trace.event(
                    "sshRoot.prewarm.cancelled",
                    fields: poolTraceFields(key: key, reason: reason, readiness: .connecting)
                )
            } catch {
                var fields = poolTraceFields(key: key, reason: reason, readiness: .connecting)
                fields["error"] = String(describing: error)
                trace.event("sshRoot.prewarm.failed", fields: fields)
                NSLog(
                    "Remux SSH root prewarm failed for %@@%@:%d (%@): %@",
                    key.username,
                    key.host,
                    key.port,
                    reason,
                    String(describing: error)
                )
            }
        }
    }

    func preparedRoot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHPreparedRoot {
        let (snapshot, reservationID) = reserveEntry(
            for: key,
            configuration: configuration,
            trace: trace
        )
        trace.event(
            snapshot.didReuse ? "sshRoot.pool.hit" : "sshRoot.pool.miss",
            fields: poolTraceFields(key: key, readiness: snapshot.readiness)
        )

        return RemuxSSHPreparedRoot.pooled(
            trace: trace,
            pool: self,
            key: key,
            generation: snapshot.generation,
            reservationID: reservationID,
            configuration: configuration,
            attempt: snapshot.attempt
        )
    }

    /// Claims a place on a pooled connection for `key`, authenticating one first when the pool has none that can
    /// take it. A claim that fails gives back what it reserved.
    nonisolated func claimRoot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHClaimedRoot {
        let preparedRoot = await preparedRoot(for: key, configuration: configuration, trace: trace)
        do {
            let sshRoot = try await trace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
            return try await preparedRoot.claim(sshRoot, trace: trace)
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }
    }

    fileprivate func leaseConnection(
        _ connection: RemuxSSHRoot,
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID,
        configuration: RemuxSSHRootConfiguration
    ) async throws -> RemuxSSHRootLease {
        switch leaseEntry(for: key, generation: generation, reservationID: reservationID) {
        case .leased:
            break
        case .stale(let closeConnection):
            if closeConnection {
                await connection.close()
            }
            throw RemuxSSHRootServiceError.stalePreparedRoot
        case .busy:
            throw RemuxSSHRootServiceError.closed
        }

        return RemuxSSHRootLease(
            connection: connection,
            pool: self,
            key: key,
            generation: generation,
            configuration: configuration
        )
    }

    fileprivate func releaseConnection(
        _ connection: RemuxSSHRoot,
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: RemuxSSHRootLeaseDisposition
    ) async {
        switch releaseEntry(for: key, generation: generation, disposition: disposition) {
        case .retained:
            break
        case .close:
            await connection.close()
        }
    }

    fileprivate func releaseConnectionAfterRefusal(
        _ connection: RemuxSSHRoot,
        for key: RemuxSSHRootKey,
        generation: UUID
    ) async -> Bool {
        let (result, othersRemain) = releaseEntryAfterRefusal(for: key, generation: generation)
        if result == .close {
            await connection.close()
        }
        return othersRemain
    }

    @discardableResult
    private func leaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) -> LeaseEntryResult {
        guard var entry = entries[generation] else {
            return .stale(closeConnection: true)
        }
        guard !entry.isRetired else {
            return .stale(closeConnection: false)
        }
        guard entry.reservationIDs.contains(reservationID) else {
            return .busy
        }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = nil
        entry.reservationIDs.remove(reservationID)
        entry.activeLeaseCount += 1
        entries[generation] = entry
        return .leased
    }

    @discardableResult
    private func releaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: RemuxSSHRootLeaseDisposition
    ) -> ReleaseEntryResult {
        guard var entry = entries[generation] else {
            return .close
        }
        if entry.isRetired {
            return releaseRetiredLease(entry)
        }

        switch disposition {
        case .reusable:
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            // A session given back frees a place the server refused before.
            entry.isRefusingSessions = false
            entries[generation] = entry
            scheduleIdleCloseIfNeeded(for: key, generation: generation)
            return .retained

        case .invalidated:
            entry.idleCloseTask?.cancel()
            entry.idleCloseTask = nil
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            guard entry.activeLeaseCount > 0 else {
                removeEntry(generation)
                return .close
            }
            entry.isRetired = true
            entries[generation] = entry
            return .retained
        }
    }

    /// The refused consumer's lease goes back, and the connection takes no new consumers while the leases that
    /// filled it remain. Also says whether any remain.
    private func releaseEntryAfterRefusal(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) -> (ReleaseEntryResult, othersRemain: Bool) {
        guard var entry = entries[generation] else {
            return (.close, false)
        }
        if entry.isRetired {
            return (releaseRetiredLease(entry), entry.activeLeaseCount > 1)
        }

        entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
        entry.isRefusingSessions = entry.activeLeaseCount > 0
        entries[generation] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
        return (.retained, entry.activeLeaseCount > 0)
    }

    /// A lease on a retired connection goes back: the connection closes with its last one.
    private func releaseRetiredLease(_ entry: Entry) -> ReleaseEntryResult {
        var entry = entry
        entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
        guard entry.activeLeaseCount > 0 else {
            removeEntry(entry.generation)
            return .close
        }
        entries[entry.generation] = entry
        return .retained
    }

    func releaseReservation(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) {
        guard var entry = entries[generation],
              entry.reservationIDs.contains(reservationID) else {
            return
        }

        entry.reservationIDs.remove(reservationID)
        entries[generation] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) {
        let closing = entries.values.filter { entry in
            entry.key.serverID == serverID
                && entry.activeLeaseCount == 0
                && entry.reservationIDs.isEmpty
        }

        for entry in closing {
            entry.idleCloseTask?.cancel()
            removeEntry(entry.generation)
            closeEntryTask(entry.attempt.task, reason: "server_profile_changed")
        }
    }

    /// The key's connection for a prewarm: the first that isn't suspect, or a new one signing in.
    private func entrySnapshot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> EntrySnapshot {
        removeSpentEntries(for: key)
        if let existing = orderedEntries(for: key).first(where: { !$0.isSuspect && !$0.isRetired }) {
            return EntrySnapshot(
                generation: existing.generation,
                attempt: existing.attempt,
                didReuse: true,
                readiness: existing.readiness
            )
        }

        let entry = addEntry(for: key, configuration: configuration, trace: trace, reservationID: nil)
        return EntrySnapshot(
            generation: entry.generation,
            attempt: entry.attempt,
            didReuse: false,
            readiness: .connecting
        )
    }

    /// A place on the key's first connection that takes new consumers, or on a new one signing in when none does.
    private func reserveEntry(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> (EntrySnapshot, UUID) {
        let reservationID = UUID()
        removeSpentEntries(for: key)
        if let snapshot = reserveExistingEntry(for: key, reservationID: reservationID) {
            return (snapshot, reservationID)
        }

        let entry = addEntry(for: key, configuration: configuration, trace: trace, reservationID: reservationID)
        return (
            EntrySnapshot(
                generation: entry.generation,
                attempt: entry.attempt,
                didReuse: false,
                readiness: .connecting
            ),
            reservationID
        )
    }

    private func reserveExistingEntry(
        for key: RemuxSSHRootKey,
        reservationID: UUID
    ) -> EntrySnapshot? {
        guard var existing = orderedEntries(for: key).first(where: { Self.takesConsumers($0) }) else {
            return nil
        }

        existing.idleCloseTask?.cancel()
        existing.idleCloseTask = nil
        existing.reservationIDs.insert(reservationID)
        entries[existing.generation] = existing
        return EntrySnapshot(
            generation: existing.generation,
            attempt: existing.attempt,
            didReuse: true,
            readiness: existing.readiness
        )
    }

    private func addEntry(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace,
        reservationID: UUID?
    ) -> Entry {
        let entry = Entry(
            key: key,
            generation: UUID(),
            attempt: makeAuthenticationAttempt(configuration: configuration, trace: trace),
            activeLeaseCount: 0,
            reservationIDs: reservationID.map { [$0] } ?? [],
            idleCloseTask: nil,
            readiness: .connecting,
            configuration: configuration
        )
        insertEntry(entry)
        observeAuthenticationResult(entry.attempt.task, for: key, generation: entry.generation)
        return entry
    }

    private func insertEntry(_ entry: Entry) {
        entries[entry.generation] = entry
        generationsByKey[entry.key, default: []].append(entry.generation)
    }

    private func removeEntry(_ generation: UUID) {
        guard let entry = entries.removeValue(forKey: generation) else { return }
        generationsByKey[entry.key]?.removeAll { $0 == generation }
        if generationsByKey[entry.key]?.isEmpty == true {
            generationsByKey.removeValue(forKey: entry.key)
        }
    }

    private func orderedEntries(for key: RemuxSSHRootKey) -> [Entry] {
        (generationsByKey[key] ?? []).compactMap { entries[$0] }
    }

    private nonisolated func makeAuthenticationAttempt(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHRootAttempt {
        RemuxSSHPreparedRoot.authenticationAttempt(configuration: configuration, trace: trace)
    }

    /// An entry whose attempt failed or whose root has closed is never handed to anyone: it goes before a
    /// lookup, even when the observer that removes it has not run yet. Its leases drain as a retired root.
    private func removeSpentEntries(for key: RemuxSSHRootKey) {
        for entry in orderedEntries(for: key) where entry.attempt.isSpent {
            rootChannelClosed(for: key, generation: entry.generation)
        }
    }

    private func observeAuthenticationResult(
        _ task: Task<RemuxSSHRoot, Error>,
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        Task {
            do {
                let root = try await task.value
                self.authenticationSucceeded(for: key, generation: generation)
                root.rootChannel.closeFuture.whenComplete { _ in
                    Task {
                        await self.rootChannelClosed(for: key, generation: generation)
                    }
                }
            } catch {
                self.authenticationFailed(for: key, generation: generation)
            }
        }
    }

    private func authenticationSucceeded(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[generation] else { return }
        entry.readiness = .ready
        entries[generation] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
        closeSuspectsAnotherConnectionHeardOver(for: key)
    }

    private func authenticationFailed(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[generation] else { return }
        entry.idleCloseTask?.cancel()
        removeEntry(generation)
    }

    private func rootChannelClosed(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[generation] else { return }
        entry.idleCloseTask?.cancel()
        guard entry.activeLeaseCount > 0 else {
            removeEntry(generation)
            return
        }
        // Its sessions still hold it until they fail and leave; closed, it is no longer anyone's suspect.
        entry.idleCloseTask = nil
        entry.isRetired = true
        entry.silentSince = nil
        entries[generation] = entry
    }

    private func scheduleIdleCloseIfNeeded(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[generation] else { return }
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = Task {
            do {
                try await Task.sleep(for: idleTimeout)
                self.closeIdleEntry(for: key, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Remux SSH root idle close timer failed: %@", String(describing: error))
            }
        }
        entries[generation] = entry
    }

    private func closeIdleEntry(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[generation] else { return }
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        removeEntry(generation)
        closeEntryTask(entry.attempt.task, reason: "idle_timeout")
    }

#if DEBUG
    func closeAllConnectionsForTesting() {
        let closing = Array(entries.values)
        entries.removeAll()
        generationsByKey.removeAll()

        for entry in closing {
            entry.idleCloseTask?.cancel()
            closeEntryTask(entry.attempt.task, reason: "testing_cleanup")
        }
    }

    @discardableResult
    func insertEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID = UUID(),
        readiness: RemuxSSHRootReadiness = .ready,
        activeLeaseCount: Int = 0,
        reservationID: UUID? = nil,
        idleCloseScheduled: Bool = false,
        isRefusingSessions: Bool = false,
        isSpare: Bool = false,
        alongsideExisting: Bool = false,
        attempt: RemuxSSHRootAttempt? = nil,
        configuration: RemuxSSHRootConfiguration? = nil
    ) -> UUID {
        if !alongsideExisting {
            for existing in orderedEntries(for: key) {
                existing.idleCloseTask?.cancel()
                removeEntry(existing.generation)
            }
        }
        var entry = Entry(
            key: key,
            generation: generation,
            // By default the entry's attempt stays in progress until the pool cancels it.
            attempt: attempt ?? RemuxSSHRootAttempt {
                try await Task.sleep(for: .seconds(86_400))
                throw CancellationError()
            },
            activeLeaseCount: activeLeaseCount,
            reservationIDs: reservationID.map { [$0] } ?? [],
            idleCloseTask: idleCloseScheduled ? Self.testingIdleCloseTask() : nil,
            readiness: readiness,
            configuration: configuration
        )
        entry.isRefusingSessions = isRefusingSessions
        entry.isSpare = isSpare
        insertEntry(entry)
        return generation
    }

    /// Whether other leases remain on the connection after the refused one goes back.
    func releaseEntryAfterRefusalForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) -> Bool {
        releaseEntryAfterRefusal(for: key, generation: generation).othersRemain
    }

    /// The connection `preparedRoot` picks (an existing one taking consumers, or a new one signing in), and the
    /// key's connections at that moment, before a new one's sign-in can finish either way.
    func preparedGenerationForTesting(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration
    ) -> (prepared: UUID, generations: [UUID]) {
        let (snapshot, _) = reserveEntry(
            for: key,
            configuration: configuration,
            trace: RemuxTransportStartupTrace(flowID: nil)
        )
        return (snapshot.generation, orderedEntries(for: key).map(\.generation))
    }

    func leaseEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) throws {
        guard leaseEntry(for: key, generation: generation, reservationID: reservationID) == .leased else {
            throw RemuxSSHRootServiceError.closed
        }
    }

    func staleLeaseShouldCloseConnectionForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) -> Bool? {
        guard case .stale(let closeConnection) = leaseEntry(
            for: key,
            generation: generation,
            reservationID: reservationID
        ) else {
            return nil
        }
        return closeConnection
    }

    /// The connection a new consumer would get a place on, and the place, or nil when every connection is refusing.
    func reserveEntryForTesting(
        for key: RemuxSSHRootKey
    ) -> (generation: UUID, reservationID: UUID)? {
        let reservationID = UUID()
        return reserveExistingEntry(for: key, reservationID: reservationID).map { ($0.generation, reservationID) }
    }

    func releaseReservationForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) {
        releaseReservation(
            for: key,
            generation: generation,
            reservationID: reservationID
        )
    }

    func releaseEntryForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: RemuxSSHRootLeaseDisposition
    ) {
        releaseEntry(
            for: key,
            generation: generation,
            disposition: disposition
        )
    }

    func markAuthenticationSucceededForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        authenticationSucceeded(for: key, generation: generation)
    }

    func markAuthenticationFailedForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        authenticationFailed(for: key, generation: generation)
    }

    /// Makes the connection suspect, as a check that heard nothing for `suspicionDelay` does, without the spare.
    func markSuspectForTesting(generation: UUID) {
        guard var entry = entries[generation] else { return }
        entry.silentSince = .now()
        entries[generation] = entry
    }

    /// Makes the connection suspect as a check does; returns whether that started a spare.
    func suspectForTesting(for key: RemuxSSHRootKey, generation: UUID) -> Bool {
        let spares = orderedEntries(for: key).filter(\.isSpare).count
        suspect(key: key, generation: generation, silentSince: .now(), reason: "test")
        return orderedEntries(for: key).filter(\.isSpare).count > spares
    }

    /// The connection a prewarm would use: an existing one, or a new one signing in.
    func prewarmGenerationForTesting(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration
    ) -> UUID {
        entrySnapshot(for: key, configuration: configuration, trace: RemuxTransportStartupTrace(flowID: nil)).generation
    }

    func markRootChannelClosedForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        rootChannelClosed(for: key, generation: generation)
    }

    private static func testingIdleCloseTask() -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }
#endif

    private nonisolated func closeEntryTask(
        _ task: Task<RemuxSSHRoot, Error>,
        reason: String
    ) {
        task.cancel()
        Task {
            do {
                let connection = try await task.value
                GhosttyRuntimeTrace.latency("sshRoot.pool.close reason=\(reason)")
                await connection.close()
            } catch is CancellationError {
                GhosttyRuntimeTrace.latency("sshRoot.pool.close cancelled reason=\(reason)")
            } catch {
                NSLog("Remux SSH root pool close failed (%@): %@", reason, String(describing: error))
            }
        }
    }

    private func poolTraceFields(
        key: RemuxSSHRootKey,
        reason: String? = nil,
        readiness: RemuxSSHRootReadiness
    ) -> [String: String] {
        var fields = [
            "host": "\(key.host):\(key.port)",
            "readiness": readiness.traceValue,
            "serverID": key.serverID.uuidString,
            "username": key.username,
        ]
        if let reason {
            fields["reason"] = reason
        }
        return fields
    }
}

private extension RemuxSSHPreparedRoot {
    static func authenticationAttempt(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHRootAttempt {
        RemuxSSHRootAttempt {
            try await RemuxSSHRootBootstrap.authenticate(
                using: configuration,
                trace: trace
            )
        }
    }
}

/// Registers the legacy `ssh-rsa` host-key algorithm (RSA with SHA-1
/// signatures) process-wide. This is enabled only after explicit user
/// opt-in for servers that offer no supported modern host-key algorithm.
/// Remux's normal trusted-host verification still applies.
enum RemuxSSHAlgorithmRegistration {
    private static let registerOnce: Void = {
        NIOSSHAlgorithms.register(
            publicKey: Insecure.RSA.PublicKey.self,
            signature: Insecure.RSA.Signature.self
        )
    }()

    static func ensureRegistered() {
        _ = registerOnce
    }
}

/// A server saved as a private IPv4 address (10/8, 172.16/12, 192.168/16) or one in the shared range VPNs and
/// carriers use (100.64/10) is connected to as that address, so a LAN or VPN route reaches it. Looked up, iOS on an
/// IPv6-only network returns only the address translated into the network's NAT64 prefix, and the connection goes to
/// the network's gateway even when a VPN routes the original. This gives up NAT64 for servers in these ranges that
/// only translation reaches. Other addresses and names keep the lookup, which IPv6-only networks need for public hosts.
enum RemuxSSHHostAddress {
    static func localIPv4(_ host: String, port: Int) -> SocketAddress? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        let octets = withUnsafeBytes(of: address.s_addr) { Array($0) }
        let (first, second) = (octets[0], octets[1])
        let isInRange = first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 100 && (64...127).contains(second))
        // The bootstrap turns an out-of-range port down first; SocketAddress would trap on one.
        guard isInRange, TmuxConnectionDraftValidator.validPorts.contains(port) else { return nil }
        return try? SocketAddress(ipAddress: host, port: port)
    }
}

enum RemuxSSHRootBootstrap {
    /// OpenSSH's channel packet size. swift-nio-ssh sizes each channel's receive window at 64
    /// packets, so this gives every channel the 2 MiB window OpenSSH (and so Herdr's own client)
    /// uses, which also bounds what a channel that stops reading can queue on the phone.
    static let channelMaximumPacketSize = 32768

    static func authenticate(
        using configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHRoot {
        var rootChannel: Channel?

        do {
            guard TmuxConnectionDraftValidator.validPorts.contains(configuration.port) else {
                throw RemuxSSHConfigurationError.invalidPort(configuration.port)
            }
            // Before any network work: a key that can't be used is reported as itself, not as a connection that
            // failed, which it would be if it failed inside the channel initializer.
            let authentication = try configuration.prepareAuthentication()

            trace.event("bootstrap.configure.begin")
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(configuration.connectTimeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            trace.event("bootstrap.configure.end")

            let inboundActivity = RemuxLastActivity()
            let directAddress = RemuxSSHHostAddress.localIPv4(configuration.host, port: configuration.port)
            let connection: (channel: Channel, authenticated: EventLoopFuture<Void>)
            do {
                connection = try await trace.stage(
                    "tcpConnect",
                    fields: [
                        "host": configuration.host,
                        "port": "\(configuration.port)",
                        "route": directAddress == nil ? "lookup" : "address",
                    ]
                ) {
                    let initializer: @Sendable (Channel) -> EventLoopFuture<
                        (channel: Channel, authenticated: EventLoopFuture<Void>)
                    > = { channel in
                        channel.pipeline.addHandler(
                            RemuxSSHInboundActivityHandler(activity: inboundActivity),
                            position: .first
                        ).flatMap {
                            configureChannel(channel, using: configuration, authentication: authentication)
                        }
                    }
                    if let directAddress {
                        return try await bootstrap.connect(to: directAddress, channelInitializer: initializer)
                    }
                    return try await bootstrap.connect(
                        host: configuration.host,
                        port: configuration.port,
                        channelInitializer: initializer
                    )
                }
            } catch {
                // Credentials are prepared above, so all that runs here is network work.
                throw RemuxSSHConnectError.unreachable(underlying: error)
            }
            let channel = connection.channel
            rootChannel = channel

            try await trace.stage("sshAuthentication") {
                try await connection.authenticated.get()
            }

            let sshHandler = try await trace.stage("sshHandler.lookup") {
                try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            }

            return RemuxSSHRoot(
                rootChannel: channel,
                childChannelOpener: RemuxSSHChildChannelOpener(sshHandler: sshHandler),
                inboundActivity: inboundActivity
            )
        } catch {
            if let rootChannel {
                try? await rootChannel.close()
            }
            throw error
        }
    }

    /// Retain each attempt's authentication result before the channel can close and remove its handlers.
    /// Authentication is awaited after connect: waiting here would prevent socket registration.
    static func configureChannel(
        _ channel: Channel,
        using configuration: RemuxSSHRootConfiguration,
        authentication: SSHPreparedAuthentication
    ) -> EventLoopFuture<(channel: Channel, authenticated: EventLoopFuture<Void>)> {
        let handshake = RemuxSSHRootHandshakeHandler(
            eventLoop: channel.eventLoop,
            timeout: configuration.connectTimeout,
            verificationTimeout: configuration.verificationTimeout,
            onTailscaleSSHCheck: configuration.onTailscaleSSHCheck
        )
        var sshConfiguration = SSHClientConfiguration(
            userAuthDelegate: authentication.makeMethod(),
            serverAuthDelegate: configuration.hostKeyValidator
        )
        sshConfiguration.maximumPacketSize = channelMaximumPacketSize
        let sshHandler = NIOSSHHandler(
            role: .client(sshConfiguration),
            allocator: channel.allocator,
            inboundChildChannelInitializer: { channel, _ in
                channel.eventLoop.makeFailedFuture(
                    RemuxSSHRootServiceError.unsupportedInboundChannel
                )
            }
        )

        let authenticated = handshake.authenticated
        return channel.pipeline.addHandler(sshHandler).flatMap {
            channel.pipeline.addHandler(handshake)
        }.map {
            (channel: channel, authenticated: authenticated)
        }
    }
}

/// Waits for sign-in. A server gets `timeout` to get through SSH, as OpenSSH's ConnectTimeout covers the banner and
/// key exchange; a Tailscale check, once shown, gets `verificationTimeout` from then on instead, since it waits on the
/// user in a browser. A port that accepts TCP and never answers fails in the first allowance, not the second.
final class RemuxSSHRootHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Disconnected: Error {}

    private struct State {
        var isComplete = false
        var challenge: TailscaleSSHCheckChallenge?
        /// The allowance running now.
        var timeoutTask: Scheduled<Void>?
    }

    private enum Completion {
        case success
        case failure(any Error)
        /// The connect allowance ran out: SSH didn't get through sign-in in time.
        case connectAllowanceExpired
        /// A shown check's allowance ran out.
        case verificationExpired
    }

    private let promise: EventLoopPromise<Void>
    private let state: NIOLockedValueBox<State>
    private let requestID: TailscaleSSHCheckRequest.ID
    private let eventLoop: EventLoop
    private let verificationTimeout: TimeAmount?
    private let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(
        eventLoop: EventLoop,
        timeout: TimeAmount,
        verificationTimeout: TimeAmount? = nil,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil
    ) {
        let promise = eventLoop.makePromise(of: Void.self)
        let state = NIOLockedValueBox(State())

        self.promise = promise
        self.state = state
        self.requestID = UUID()
        self.eventLoop = eventLoop
        self.verificationTimeout = verificationTimeout
        self.onTailscaleSSHCheck = onTailscaleSSHCheck

        let timeoutTask = scheduleTimeout(timeout, expiring: .connectAllowanceExpired)
        state.withLockedValue { $0.timeoutTask = timeoutTask }
        promise.futureResult.whenComplete { _ in
            state.withLockedValue { $0.timeoutTask }?.cancel()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success)
        } else if let banner = event as? NIOUserAuthBannerEvent,
                  let challenge = TailscaleSSHCheckChallenge.parse(from: banner.message) {
            let eventLoop = context.eventLoop
            let request = state.withLockedValue { state -> TailscaleSSHCheckRequest? in
                guard !state.isComplete, state.challenge != challenge else { return nil }
                // Only the first check starts its allowance; a later or changed banner doesn't extend it.
                let isFirstCheck = state.challenge == nil
                state.challenge = challenge
                if let verificationTimeout, isFirstCheck {
                    state.timeoutTask?.cancel()
                    state.timeoutTask = scheduleTimeout(verificationTimeout, expiring: .verificationExpired)
                }
                return TailscaleSSHCheckRequest(
                    id: requestID,
                    challenge: challenge,
                    cancel: { [weak self] in
                        eventLoop.execute {
                            self?.complete(.failure(CancellationError()))
                        }
                    }
                )
            }
            if let request, let onTailscaleSSHCheck {
                onTailscaleSSHCheck(.presented(request))
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.fireErrorCaught(error)
        // NIOSSH reports a failed key exchange here and leaves the connection open, so channel
        // messages held for that exchange would wait forever unless the connection closes.
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(Disconnected()))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete(.failure(Disconnected()))
    }

    deinit {
        complete(.failure(Disconnected()))
    }

    private func scheduleTimeout(_ timeout: TimeAmount, expiring completion: Completion) -> Scheduled<Void> {
        let (promise, state, requestID, onTailscaleSSHCheck) = (promise, state, requestID, onTailscaleSSHCheck)
        return eventLoop.scheduleTask(in: timeout) {
            Self.complete(
                completion,
                promise: promise,
                state: state,
                requestID: requestID,
                onTailscaleSSHCheck: onTailscaleSSHCheck
            )
        }
    }

    private func complete(_ completion: Completion) {
        Self.complete(
            completion,
            promise: promise,
            state: state,
            requestID: requestID,
            onTailscaleSSHCheck: onTailscaleSSHCheck
        )
    }

    private static func complete(
        _ completion: Completion,
        promise: EventLoopPromise<Void>,
        state: NIOLockedValueBox<State>,
        requestID: TailscaleSSHCheckRequest.ID,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
    ) {
        let hadChallenge = state.withLockedValue { state -> Bool? in
            guard !state.isComplete else { return nil }
            state.isComplete = true
            let hadChallenge = state.challenge != nil
            state.challenge = nil
            return hadChallenge
        }
        guard let hadChallenge else { return }

        if hadChallenge {
            onTailscaleSSHCheck?(.finished(requestID))
        }

        switch completion {
        case .success:
            promise.succeed(())
        case .failure(let error):
            promise.fail(error)
        case .connectAllowanceExpired:
            // Even with a check recorded: without a verification allowance, none was shown or waited on.
            promise.fail(RemuxSSHConnectError.noSSHResponse)
        case .verificationExpired:
            promise.fail(TailscaleSSHCheckError.verificationTimedOut)
        }
    }
}
