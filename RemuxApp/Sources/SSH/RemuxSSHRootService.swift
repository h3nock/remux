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

    init(target: TmuxConnectionTarget) {
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
    let authenticationMethod: @Sendable () throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let authenticationTimeout: TimeAmount
    let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckChallenge) -> Void)?

    init(
        host: String,
        port: Int,
        authenticationMethod: @escaping @Sendable () throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount,
        authenticationTimeout: TimeAmount? = nil,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckChallenge) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.authenticationTimeout = authenticationTimeout ?? connectTimeout
        self.onTailscaleSSHCheck = onTailscaleSSHCheck
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

    func openSessionChannel(trace: RemuxTransportStartupTrace) async throws -> Channel {
        try await childChannelOpener.openSessionChannel(on: rootChannel, trace: trace)
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
        trace: RemuxTransportStartupTrace
    ) async throws -> Channel {
        try await openChildChannel(
            on: rootChannel,
            type: .session,
            trace: trace,
            traceStage: "sessionChannel.open",
            channelInitializer: { channel in
                channel.eventLoop.makeSucceededFuture(())
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

struct RemuxSSHPreparedRoot {
    let trace: RemuxTransportStartupTrace
    private let ownership: RemuxSSHPreparedRootOwnership
    private let cancelAuthenticationOnClose: Bool
    private let task: Task<RemuxSSHRoot, Error>

    fileprivate static func pooled(
        trace: RemuxTransportStartupTrace,
        pool: RemuxSSHRootService,
        key: RemuxSSHRootKey,
        generation: UUID,
        reservationID: UUID,
        task: Task<RemuxSSHRoot, Error>
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
            task: task
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
            task: authenticationTask(configuration: configuration, trace: trace)
        )
    }

    func sshRoot() async throws -> RemuxSSHRoot {
        try await task.value
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

        task.cancel()
        do {
            let sshRoot = try await task.value
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

    private struct Entry {
        let generation: UUID
        let task: Task<RemuxSSHRoot, Error>
        var activeLeaseCount: Int
        var reservationIDs: Set<UUID>
        var idleCloseTask: Task<Void, Never>?
        var readiness: RemuxSSHRootReadiness
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
        let task: Task<RemuxSSHRoot, Error>
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
        /// Lease returned; the connection stays pooled.
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
                _ = try await snapshot.task.value
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
        guard let snapshot = reserveEntry(
            for: key,
            configuration: configuration,
            trace: trace
        ) else {
            trace.event(
                "sshRoot.pool.busy",
                fields: poolTraceFields(key: key, readiness: entries[key]?.readiness ?? .connecting)
            )
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
            task: snapshot.task
        )
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
            closeEntryTask(entry.task, reason: "child_channel_close_failed")
            return
        }
        retiredEntries[generation] = RetiredEntry(
            task: entry.task,
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
            // A retired root: drain, close with the last lease.
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
                task: entry.task,
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
            closeEntryTask(entry.task, reason: "server_profile_changed")
        }
    }

    private func entrySnapshot(
        for key: RemuxSSHRootKey,
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> EntrySnapshot {
        if let existing = entries[key] {
            return EntrySnapshot(
                generation: existing.generation,
                task: existing.task,
                didReuse: true,
                readiness: existing.readiness,
                reservationID: nil
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
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
        if entries[key] != nil {
            return reserveExistingEntry(
                for: key,
                reservationID: reservationID
            )
        }

        let generation = UUID()
        let task = makeAuthenticationTask(configuration: configuration, trace: trace)
        entries[key] = Entry(
            generation: generation,
            task: task,
            activeLeaseCount: 0,
            reservationIDs: [reservationID],
            idleCloseTask: nil,
            readiness: .connecting
        )

        observeAuthenticationResult(task, for: key, generation: generation)

        return EntrySnapshot(
            generation: generation,
            task: task,
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
            task: existing.task,
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

    private nonisolated func makeAuthenticationTask(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> Task<RemuxSSHRoot, Error> {
        RemuxSSHPreparedRoot.authenticationTask(configuration: configuration, trace: trace)
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
            task: entry.task,
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
        closeEntryTask(entry.task, reason: "idle_timeout")
    }

#if DEBUG
    func closeAllConnectionsForTesting() {
        let closing = Array(entries.values)
        entries.removeAll()

        for entry in closing {
            entry.idleCloseTask?.cancel()
            closeEntryTask(entry.task, reason: "testing_cleanup")
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
        idleCloseScheduled: Bool = false
    ) -> UUID {
        entries[key]?.idleCloseTask?.cancel()
        entries[key] = Entry(
            generation: generation,
            task: Task<RemuxSSHRoot, Error> {
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
    static func authenticationTask(
        configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) -> Task<RemuxSSHRoot, Error> {
        Task.detached(priority: .userInitiated) {
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

private enum RemuxSSHRootBootstrap {
    static func authenticate(
        using configuration: RemuxSSHRootConfiguration,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHRoot {
        var rootChannel: Channel?

        do {
            trace.event("bootstrap.configure.begin")
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    let handshake = RemuxSSHRootHandshakeHandler(
                        eventLoop: channel.eventLoop,
                        timeout: configuration.authenticationTimeout,
                        onTailscaleSSHCheck: configuration.onTailscaleSSHCheck
                    )
                    let authenticationMethod: SSHAuthenticationMethod
                    do {
                        authenticationMethod = try configuration.authenticationMethod()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }

                    let sshConfiguration = SSHClientConfiguration(
                        userAuthDelegate: authenticationMethod,
                        serverAuthDelegate: configuration.hostKeyValidator
                    )
                    let sshHandler = NIOSSHHandler(
                        role: .client(sshConfiguration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { channel, _ in
                            channel.eventLoop.makeFailedFuture(
                                RemuxSSHRootServiceError.unsupportedInboundChannel
                            )
                        }
                    )

                    return channel.pipeline.addHandler(sshHandler).flatMap {
                        channel.pipeline.addHandler(handshake)
                    }
                }
                .connectTimeout(configuration.connectTimeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            trace.event("bootstrap.configure.end")

            let channel = try await trace.stage(
                "tcpConnect",
                fields: [
                    "host": configuration.host,
                    "port": "\(configuration.port)",
                ]
            ) {
                try await bootstrap.connect(
                    host: configuration.host,
                    port: configuration.port
                ).get()
            }
            rootChannel = channel

            let handshake = try await trace.stage("handshakeHandler.lookup") {
                try await channel.pipeline.handler(type: RemuxSSHRootHandshakeHandler.self).get()
            }
            try await trace.stage("sshAuthentication") {
                try await handshake.authenticated.get()
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
}

final class RemuxSSHRootHandshakeHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private struct Disconnected: Error {}

    private let promise: EventLoopPromise<Void>
    private let tailscaleCheckChallenge = NIOLockedValueBox<TailscaleSSHCheckChallenge?>(nil)
    private let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckChallenge) -> Void)?

    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(
        eventLoop: EventLoop,
        timeout: TimeAmount,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckChallenge) -> Void)? = nil
    ) {
        self.promise = eventLoop.makePromise(of: Void.self)
        self.onTailscaleSSHCheck = onTailscaleSSHCheck

        eventLoop.scheduleTask(in: timeout) { [promise, tailscaleCheckChallenge] in
            if tailscaleCheckChallenge.withLockedValue({ $0 }) != nil {
                promise.fail(TailscaleSSHCheckError.verificationTimedOut)
            } else {
                promise.fail(ChannelError.connectTimeout(timeout))
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        } else if let banner = event as? NIOUserAuthBannerEvent,
                  let challenge = TailscaleSSHCheckChallenge.parse(from: banner.message) {
            let shouldPresent = tailscaleCheckChallenge.withLockedValue { current in
                guard current != challenge else { return false }
                current = challenge
                return true
            }
            if shouldPresent, let onTailscaleSSHCheck {
                onTailscaleSSHCheck(challenge)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    deinit {
        promise.fail(Disconnected())
    }
}
