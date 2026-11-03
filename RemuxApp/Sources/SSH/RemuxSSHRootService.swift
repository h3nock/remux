@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct RemuxSSHRootKey: Hashable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    private let authFingerprint: String

    init(target: SessionTarget) {
        self.serverID = target.server.id
        self.host = target.server.host
        self.port = target.server.port
        self.username = target.sshAuth.username
        self.authFingerprint = target.sshAuth.authFingerprint
    }
}

struct RemuxSSHRootConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable (RemuxSSHLogin) throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let authenticationTimeout: TimeAmount
    let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
    /// A new login asks the user to approve the key on this device, so it starts only when the user asked
    /// for something on the server; an open connection is reused without asking.
    let loginNeedsApproval: Bool

    init(
        host: String,
        port: Int,
        authenticationMethod: @escaping @Sendable (RemuxSSHLogin) throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount,
        authenticationTimeout: TimeAmount? = nil,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil,
        loginNeedsApproval: Bool = false
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.authenticationTimeout = authenticationTimeout ?? connectTimeout
        self.onTailscaleSSHCheck = onTailscaleSSHCheck
        self.loginNeedsApproval = loginNeedsApproval
    }
}

/// The connection a login authenticates, as its authentication method sees it.
struct RemuxSSHLogin: Sendable {
    /// Completes when the connection closes.
    let closeFuture: EventLoopFuture<Void>
    /// Called around a wait for the user to approve the key on this device. The login's timeout stops
    /// meanwhile: the device's prompt has no time limit of its own, and the server's grace period still
    /// ends a login left waiting.
    let approvalStarted: @Sendable () -> Void
    let approvalEnded: @Sendable () -> Void
}

/// Why a login whose key needs the user's approval on this device didn't happen.
enum SSHKeyApprovalError: LocalizedError, Equatable {
    /// Nobody asked for a new login, so the key wasn't offered for approval.
    case required
    /// The connection closed while the device waited for approval.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .required: "Unlock this server's key to connect."
        case .interrupted: "The server closed the connection before the key was unlocked."
        }
    }
}

/// The servers whose next login may ask the user to approve the key, because the user just asked for
/// something on them. Each allowance covers one login and lapses soon, so work that runs by itself later
/// never brings up a prompt.
final class RemuxSSHLoginApprovals: Sendable {
    static let lifetime: Duration = .seconds(30)

    private let deadlines = NIOLockedValueBox<[SavedServer.ID: ContinuousClock.Instant]>([:])

    func allow(serverID: SavedServer.ID) {
        let deadline = ContinuousClock.now + Self.lifetime
        deadlines.withLockedValue { $0[serverID] = deadline }
    }

    func take(serverID: SavedServer.ID) -> Bool {
        deadlines.withLockedValue { deadlines in
            guard let deadline = deadlines.removeValue(forKey: serverID) else { return false }
            return ContinuousClock.now < deadline
        }
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
    }

    /// Roots evicted from the pool that still have live leases
    /// draining (multi-lease invalidation).
    let retiredCount: Int

    fileprivate let entries: [RemuxSSHRootKey: Entry]

    var entryCount: Int {
        entries.count
    }

    func entry(for key: RemuxSSHRootKey) -> Entry? {
        entries[key]
    }
}

final class RemuxSSHRoot: @unchecked Sendable {
    let rootChannel: Channel
    private let childChannelOpener: RemuxSSHChildChannelOpener

    fileprivate init(rootChannel: Channel, childChannelOpener: RemuxSSHChildChannelOpener) {
        self.rootChannel = rootChannel
        self.childChannelOpener = childChannelOpener
    }

    func close() async {
        do {
            try await rootChannel.close()
        } catch {
            NSLog("Remux authenticated SSH root close failed: %@", String(describing: error))
        }
    }

    /// With `readsOnDemand`, the channel delivers data only after `read()`. It is set before the
    /// channel activates, because activation already issues a read when reads are automatic.
    func openSessionChannel(
        trace: RemuxTransportStartupTrace,
        readsOnDemand: Bool = false
    ) async throws -> Channel {
        try await childChannelOpener.openSessionChannel(on: rootChannel, trace: trace, readsOnDemand: readsOnDemand)
    }

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

enum RemuxSSHRootServiceError: LocalizedError, Equatable, CustomStringConvertible {
    case unsupportedInboundChannel
    case closed
    case stalePreparedRoot

    var description: String {
        switch self {
        case .unsupportedInboundChannel:
            return "unsupportedInboundChannel"
        case .closed:
            return "closed"
        case .stalePreparedRoot:
            return "stalePreparedRoot"
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
        }
    }
}

fileprivate final class RemuxSSHRootLease: @unchecked Sendable {
    private let connection: RemuxSSHRoot

    private let pool: RemuxSSHRootService
    private let key: RemuxSSHRootKey
    private let generation: UUID
    private let lock = NIOLock()
    private var isReleased = false
    private var didInvalidateForReuse = false

    init(
        connection: RemuxSSHRoot,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID
    ) {
        self.connection = connection
        self.pool = pool
        self.key = key
        self.generation = generation
    }

    func release(_ disposition: RemuxSSHRootLeaseDisposition) async {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        guard shouldRelease else { return }

        await pool.releaseConnection(
            connection,
            for: key,
            generation: generation,
            disposition: disposition
        )
    }

    func invalidateForReuse() async {
        let shouldInvalidate = lock.withLock {
            guard !isReleased, !didInvalidateForReuse else { return false }
            didInvalidateForReuse = true
            return true
        }
        guard shouldInvalidate else { return }

        await pool.invalidateForReuse(
            for: key,
            generation: generation
        )
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
        attempt: RemuxSSHRootAttempt
    ) -> RemuxSSHPreparedRoot {
        RemuxSSHPreparedRoot(
            trace: trace,
            ownership: .pooled(
                pool: pool,
                key: key,
                generation: generation,
                reservationID: reservationID
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

    /// A root that won't be made, which reports `error` to whoever waits for it.
    fileprivate static func failed(_ error: Error, trace: RemuxTransportStartupTrace) -> RemuxSSHPreparedRoot {
        RemuxSSHPreparedRoot(
            trace: trace,
            ownership: .dedicated,
            cancelAuthenticationOnClose: false,
            attempt: RemuxSSHRootAttempt { throw error }
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

        case .pooled(let pool, let key, let generation, let reservationID):
            let lease = try await trace.stage("sshRoot.pool.lease") {
                try await pool.leaseConnection(
                    sshRoot,
                    for: key,
                    generation: generation,
                    reservationID: reservationID
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
        case .pooled(let pool, let key, let generation, let reservationID):
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
        reservationID: UUID
    )
}

struct RemuxSSHClaimedRoot: Sendable {
    let sshRoot: RemuxSSHRoot
    private let lease: RemuxSSHRootLease?

    fileprivate init(
        sshRoot: RemuxSSHRoot,
        lease: RemuxSSHRootLease?
    ) {
        self.sshRoot = sshRoot
        self.lease = lease
    }

    func releaseAfterFailedStart() async {
        await release(.invalidated)
    }

    func release(_ disposition: RemuxSSHRootLeaseDisposition) async {
        if let lease {
            await lease.release(disposition)
        } else {
            await sshRoot.close()
        }
    }

    func invalidateForReuse() async {
        await lease?.invalidateForReuse()
    }
}

actor RemuxSSHRootService {
    nonisolated let tailscaleSSHCheckChallengeBroker = TailscaleSSHCheckChallengeBroker()
    nonisolated let loginApprovals = RemuxSSHLoginApprovals()

    private struct Entry {
        let generation: UUID
        let attempt: RemuxSSHRootAttempt
        var activeLeaseCount: Int
        var reservationIDs: Set<UUID>
        var idleCloseTask: Task<Void, Never>?
        var readiness: RemuxSSHRootReadiness
        var loginNeedsApproval = false
    }

    /// A root removed from the pool while sessions still lease it: no
    /// new leases, and the underlying connection closes only when the
    /// last lease releases. Closing immediately on invalidation would
    /// let one session's channel-level failure kill healthy sibling
    /// sessions sharing the root; a genuinely dead root drains fast
    /// because every sibling errors out and releases.
    private struct RetiredEntry {
        let task: Task<RemuxSSHRoot, Error>
        var activeLeaseCount: Int
    }

    private struct EntrySnapshot: Sendable {
        let generation: UUID
        let attempt: RemuxSSHRootAttempt
        let didReuse: Bool
        let readiness: RemuxSSHRootReadiness
        let reservationID: UUID?
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

    /// SSH multiplexes child channels over one authenticated connection.
    /// Bounding concurrent consumers keeps the blast radius of a dying
    /// root modest.
    static let maxConcurrentLeases = 4

    private let idleTimeout: Duration
    private var entries: [RemuxSSHRootKey: Entry] = [:]
    private var retiredEntries: [UUID: RetiredEntry] = [:]

    init(idleTimeout: Duration = .seconds(120)) {
        self.idleTimeout = idleTimeout
    }

    func snapshot() -> RemuxSSHRootServiceSnapshot {
        RemuxSSHRootServiceSnapshot(
            retiredCount: retiredEntries.count,
            entries: entries.mapValues { entry in
                RemuxSSHRootServiceSnapshot.Entry(
                    generation: entry.generation,
                    readiness: entry.readiness,
                    activeLeaseCount: entry.activeLeaseCount,
                    reservationCount: entry.reservationIDs.count,
                    isIdleCloseScheduled: entry.idleCloseTask != nil
                )
            }
        )
    }

    func prewarmConnection(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace,
        reason: String
    ) {
        removeEntryIfSpent(for: key)
        if configuration.loginNeedsApproval, entries[key] == nil {
            trace.event(
                "sshRoot.prewarm.skipped",
                fields: poolTraceFields(key: key, reason: "login_needs_approval", readiness: .connecting)
            )
            return
        }
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
        removeEntryIfSpent(for: key)
        if configuration.loginNeedsApproval, entries[key] == nil,
           !loginApprovals.take(serverID: key.serverID) {
            return approvalRequired(for: key, trace: trace)
        }
        guard let snapshot = reserveEntry(
            for: key,
            configuration: configuration,
            trace: trace
        ) else {
            trace.event(
                "sshRoot.pool.busy",
                fields: poolTraceFields(key: key, readiness: entries[key]?.readiness ?? .connecting)
            )
            if configuration.loginNeedsApproval, !loginApprovals.take(serverID: key.serverID) {
                return approvalRequired(for: key, trace: trace)
            }
            return dedicatedPreparedRoot(
                configuration: configuration,
                trace: trace
            )
        }
        trace.event(
            snapshot.didReuse ? "sshRoot.pool.hit" : "sshRoot.pool.miss",
            fields: poolTraceFields(key: key, readiness: snapshot.readiness)
        )
        guard let reservationID = snapshot.reservationID else {
            return dedicatedPreparedRoot(
                configuration: configuration,
                trace: trace
            )
        }

        return RemuxSSHPreparedRoot.pooled(
            trace: trace,
            pool: self,
            key: key,
            generation: snapshot.generation,
            reservationID: reservationID,
            attempt: snapshot.attempt
        )
    }

    private func approvalRequired(
        for key: RemuxSSHRootKey,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHPreparedRoot {
        trace.event(
            "sshRoot.pool.approvalRequired",
            fields: poolTraceFields(key: key, readiness: .connecting)
        )
        return .failed(SSHKeyApprovalError.required, trace: trace)
    }

    fileprivate func leaseConnection(
        _ connection: RemuxSSHRoot,
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
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
            generation: generation
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

    fileprivate func invalidateForReuse(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)

        guard entry.activeLeaseCount > 0 else {
            closeEntryTask(entry.attempt.task, reason: "child_channel_close_failed")
            return
        }
        retiredEntries[generation] = RetiredEntry(
            task: entry.attempt.task,
            activeLeaseCount: entry.activeLeaseCount
        )
    }

    @discardableResult
    private func leaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) -> LeaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            return .stale(closeConnection: retiredEntries[generation] == nil)
        }
        guard entry.reservationIDs.contains(reservationID) else {
            return .busy
        }

        entry.idleCloseTask?.cancel()
        entry.idleCloseTask = nil
        entry.reservationIDs.remove(reservationID)
        entry.activeLeaseCount += 1
        entries[key] = entry
        return .leased
    }

    @discardableResult
    private func releaseEntry(
        for key: RemuxSSHRootKey,
        generation: UUID,
        disposition: RemuxSSHRootLeaseDisposition
    ) -> ReleaseEntryResult {
        guard var entry = entries[key], entry.generation == generation else {
            if var retired = retiredEntries[generation] {
                retired.activeLeaseCount = max(0, retired.activeLeaseCount - 1)
                if retired.activeLeaseCount == 0 {
                    retiredEntries.removeValue(forKey: generation)
                    return .close
                }
                retiredEntries[generation] = retired
                return .retained
            }
            // Unknown to the pool (dedicated or already evicted):
            // the caller owns the close.
            return .close
        }

        switch disposition {
        case .reusable:
            entry.activeLeaseCount = max(0, entry.activeLeaseCount - 1)
            entries[key] = entry
            scheduleIdleCloseIfNeeded(for: key, generation: generation)
            return .retained

        case .invalidated:
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            let remaining = max(0, entry.activeLeaseCount - 1)
            guard remaining > 0 else {
                return .close
            }
            retiredEntries[generation] = RetiredEntry(
                task: entry.attempt.task,
                activeLeaseCount: remaining
            )
            return .retained
        }
    }

    func releaseReservation(
        for key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID
    ) {
        guard var entry = entries[key],
              entry.generation == generation,
              entry.reservationIDs.contains(reservationID) else {
            return
        }

        entry.reservationIDs.remove(reservationID)
        // Nobody waits for a login the user was asked to approve any more: give it up, which takes its
        // prompt away. Other logins finish, for the next caller.
        if entry.loginNeedsApproval, entry.readiness == .connecting,
           entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty {
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            closeEntryTask(entry.attempt.task, reason: "approval_abandoned")
            return
        }
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) {
        let closing = entries
            .filter { key, entry in
                key.serverID == serverID
                    && entry.activeLeaseCount == 0
                    && entry.reservationIDs.isEmpty
            }

        for (key, entry) in closing {
            entry.idleCloseTask?.cancel()
            entries.removeValue(forKey: key)
            closeEntryTask(entry.attempt.task, reason: "server_profile_changed")
        }
    }

    private func entrySnapshot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> EntrySnapshot {
        removeEntryIfSpent(for: key)
        if let existing = entries[key] {
            return EntrySnapshot(
                generation: existing.generation,
                attempt: existing.attempt,
                didReuse: true,
                readiness: existing.readiness,
                reservationID: nil
            )
        }

        let generation = UUID()
        let attempt = makeAuthenticationAttempt(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            attempt: attempt,
            activeLeaseCount: 0,
            reservationIDs: [],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(attempt.task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            attempt: attempt,
            didReuse: false,
            readiness: .connecting,
            reservationID: nil
        )
    }

    private func reserveEntry(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> EntrySnapshot? {
        let reservationID = UUID()
        removeEntryIfSpent(for: key)
        if entries[key] != nil {
            return reserveExistingEntry(
                for: key,
                reservationID: reservationID
            )
        }

        let generation = UUID()
        let attempt = makeAuthenticationAttempt(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            attempt: attempt,
            activeLeaseCount: 0,
            reservationIDs: [reservationID],
            idleCloseTask: nil,
            readiness: .connecting,
            loginNeedsApproval: configuration.loginNeedsApproval
        )

        observeAuthenticationResult(attempt.task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            attempt: attempt,
            didReuse: false,
            readiness: .connecting,
            reservationID: reservationID
        )
    }

    private func reserveExistingEntry(
        for key: RemuxSSHRootKey,
        reservationID: UUID
    ) -> EntrySnapshot? {
        guard var existing = entries[key],
              existing.activeLeaseCount + existing.reservationIDs.count
                  < Self.maxConcurrentLeases
        else {
            return nil
        }

        existing.idleCloseTask?.cancel()
        existing.idleCloseTask = nil
        existing.reservationIDs.insert(reservationID)
        entries[key] = existing
        return EntrySnapshot(
            generation: existing.generation,
            attempt: existing.attempt,
            didReuse: true,
            readiness: existing.readiness,
            reservationID: reservationID
        )
    }

    private func dedicatedPreparedRoot(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHPreparedRoot {
        RemuxSSHPreparedRoot.dedicated(configuration: configuration, trace: trace)
    }

    private nonisolated func makeAuthenticationAttempt(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> RemuxSSHRootAttempt {
        RemuxSSHPreparedRoot.authenticationAttempt(configuration: configuration, trace: trace)
    }

    /// An entry whose attempt failed or whose root has closed is never handed to anyone: it goes before a
    /// lookup, even when the observer that removes it has not run yet. Its leases drain as a retired root.
    private func removeEntryIfSpent(for key: RemuxSSHRootKey) {
        guard let entry = entries[key], entry.attempt.isSpent else { return }
        rootChannelClosed(for: key, generation: entry.generation)
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
        guard var entry = entries[key], entry.generation == generation else { return }
        entry.readiness = .ready
        entries[key] = entry
        scheduleIdleCloseIfNeeded(for: key, generation: generation)
    }

    private func authenticationFailed(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
    }

    private func rootChannelClosed(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)

        guard entry.activeLeaseCount > 0 else { return }
        retiredEntries[generation] = RetiredEntry(
            task: entry.attempt.task,
            activeLeaseCount: entry.activeLeaseCount
        )
    }

    private func scheduleIdleCloseIfNeeded(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
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
        entries[key] = entry
    }

    private func closeIdleEntry(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        guard let entry = entries[key], entry.generation == generation else { return }
        guard entry.activeLeaseCount == 0, entry.reservationIDs.isEmpty else { return }

        entry.idleCloseTask?.cancel()
        entries.removeValue(forKey: key)
        closeEntryTask(entry.attempt.task, reason: "idle_timeout")
    }

#if DEBUG
    func closeAllConnectionsForTesting() {
        let closing = Array(entries.values)
        entries.removeAll()

        for entry in closing {
            entry.idleCloseTask?.cancel()
            closeEntryTask(entry.attempt.task, reason: "testing_cleanup")
        }

        let retired = Array(retiredEntries.values)
        retiredEntries.removeAll()
        for entry in retired {
            closeEntryTask(entry.task, reason: "testing_cleanup")
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
        attempt: RemuxSSHRootAttempt? = nil
    ) -> UUID {
        entries[key]?.idleCloseTask?.cancel()
        entries[key] = Entry(
            generation: generation,
            // By default the entry's attempt stays in progress until the pool cancels it.
            attempt: attempt ?? RemuxSSHRootAttempt {
                try await Task.sleep(for: .seconds(86_400))
                throw CancellationError()
            },
            activeLeaseCount: activeLeaseCount,
            reservationIDs: reservationID.map { [$0] } ?? [],
            idleCloseTask: idleCloseScheduled ? Self.testingIdleCloseTask() : nil,
            readiness: readiness
        )
        return generation
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

    func reserveEntryForTesting(
        for key: RemuxSSHRootKey
    ) -> UUID? {
        reserveExistingEntry(
            for: key,
            reservationID: UUID()
        )?.reservationID
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

    func invalidateForReuseForTesting(
        for key: RemuxSSHRootKey,
        generation: UUID
    ) {
        invalidateForReuse(for: key, generation: generation)
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
            trace.event("bootstrap.configure.begin")
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(configuration.connectTimeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            trace.event("bootstrap.configure.end")

            let connection = try await trace.stage(
                "tcpConnect",
                fields: [
                    "host": configuration.host,
                    "port": "\(configuration.port)",
                ]
            ) {
                try await bootstrap.connect(
                    host: configuration.host,
                    port: configuration.port,
                    channelInitializer: { channel in
                        configureChannel(channel, using: configuration)
                    }
                )
            }
            let channel = connection.channel
            rootChannel = channel

            try await trace.stage("sshAuthentication") {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await connection.authenticated.get()
                } onCancel: {
                    channel.close(promise: nil)
                }
            }

            let sshHandler = try await trace.stage("sshHandler.lookup") {
                try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
            }

            return RemuxSSHRoot(
                rootChannel: channel,
                childChannelOpener: RemuxSSHChildChannelOpener(sshHandler: sshHandler)
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
        using configuration: RemuxSSHRootConfiguration
    ) -> EventLoopFuture<(channel: Channel, authenticated: EventLoopFuture<Void>)> {
        let handshake = RemuxSSHRootHandshakeHandler(
            eventLoop: channel.eventLoop,
            timeout: configuration.authenticationTimeout,
            onTailscaleSSHCheck: configuration.onTailscaleSSHCheck
        )
        let authenticationMethod: SSHAuthenticationMethod
        do {
            authenticationMethod = try configuration.authenticationMethod(RemuxSSHLogin(
                closeFuture: channel.closeFuture,
                approvalStarted: { [weak handshake] in handshake?.approvalStarted() },
                approvalEnded: { [weak handshake] in handshake?.approvalEnded() }
            ))
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }

        var sshConfiguration = SSHClientConfiguration(
            userAuthDelegate: authenticationMethod,
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

final class RemuxSSHRootHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Disconnected: Error {}

    private struct State {
        var isComplete = false
        var challenge: TailscaleSSHCheckChallenge?
        var timeoutTask: Scheduled<Void>?
        var isAwaitingApproval = false
    }

    private enum Completion {
        case success
        case failure(any Error)
        case timeout(TimeAmount)
    }

    private let promise: EventLoopPromise<Void>
    private let state: NIOLockedValueBox<State>
    private let requestID: TailscaleSSHCheckRequest.ID
    private let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
    private let eventLoop: EventLoop
    private let timeout: TimeAmount

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(
        eventLoop: EventLoop,
        timeout: TimeAmount,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil
    ) {
        let promise = eventLoop.makePromise(of: Void.self)
        let state = NIOLockedValueBox(State())
        let requestID = UUID()

        self.promise = promise
        self.state = state
        self.requestID = requestID
        self.onTailscaleSSHCheck = onTailscaleSSHCheck
        self.eventLoop = eventLoop
        self.timeout = timeout

        startTimeout()
        promise.futureResult.whenComplete { _ in
            state.withLockedValue { $0.timeoutTask?.cancel() }
        }
    }

    /// The login's timeout stops while the user approves the key on this device.
    func approvalStarted() {
        state.withLockedValue { state in
            state.timeoutTask?.cancel()
            state.timeoutTask = nil
            state.isAwaitingApproval = true
        }
    }

    /// The server answers the approved key within the login's timeout, counted again from here.
    func approvalEnded() {
        let wasAwaiting = state.withLockedValue { state in
            defer { state.isAwaitingApproval = false }
            return state.isAwaitingApproval && !state.isComplete
        }
        if wasAwaiting { startTimeout() }
    }

    private func startTimeout() {
        let promise = promise
        let state = state
        let requestID = requestID
        let onTailscaleSSHCheck = onTailscaleSSHCheck
        let timeout = timeout
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            Self.complete(
                .timeout(timeout),
                promise: promise,
                state: state,
                requestID: requestID,
                onTailscaleSSHCheck: onTailscaleSSHCheck
            )
        }
        let isComplete = state.withLockedValue { state in
            if !state.isComplete { state.timeoutTask = timeoutTask }
            return state.isComplete
        }
        if isComplete { timeoutTask.cancel() }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success)
        } else if let banner = event as? NIOUserAuthBannerEvent,
                  let challenge = TailscaleSSHCheckChallenge.parse(from: banner.message) {
            let eventLoop = context.eventLoop
            let request = state.withLockedValue { state -> TailscaleSSHCheckRequest? in
                guard !state.isComplete, state.challenge != challenge else { return nil }
                state.challenge = challenge
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
        let wasAwaitingApproval = state.withLockedValue { $0.isAwaitingApproval }
        complete(.failure(wasAwaitingApproval ? SSHKeyApprovalError.interrupted : Disconnected()))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete(.failure(Disconnected()))
    }

    deinit {
        complete(.failure(Disconnected()))
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
        case .timeout(let timeout):
            if hadChallenge {
                promise.fail(TailscaleSSHCheckError.verificationTimedOut)
            } else {
                promise.fail(ChannelError.connectTimeout(timeout))
            }
        }
    }
}
