import Foundation

/// One SFTP session per server connection, kept for every preview and attachment on that server to share: opening a
/// session costs three round trips and closing it one more, which each operation paid when it had its own. SFTP
/// matches each reply to its request by id, so users' operations run on the session side by side.
///
/// A session closes once it has had no users for `idleTimeout`. One that an operation gave up on, or whose channel
/// closed, is never handed out again; the next user opens another.
///
/// Uploads also take turns here, one at a time per key in the order they began.
actor RemuxSFTPSessionKeeper<Key: Hashable & Sendable, Client: Sendable> {
    struct Session: Sendable {
        let client: Client
        /// False once an operation gave up on the session or its channel closed.
        let isUsable: @Sendable () async -> Bool
        let close: @Sendable () async -> Void
    }

    private struct Entry {
        let id = UUID()
        let opening: Task<Session, Error>
        var users: Set<UUID> = []
        var idleClose: Task<Void, Never>?
    }

    private struct UploadTurn {
        var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    }

    private let idleTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var entries: [Key: Entry] = [:]
    /// Keys with an upload running, and the uploads waiting behind it.
    private var uploadTurns: [Key: UploadTurn] = [:]

    init<C: Clock>(
        idleTimeout: Duration = .seconds(60),
        clock: C = ContinuousClock()
    ) where C.Instant == ContinuousClock.Instant {
        self.idleTimeout = idleTimeout
        now = { clock.now }
        sleep = { try await clock.sleep(until: $0, tolerance: nil) }
    }

    /// A place on the key's session, opened with `open` when the key has none that works. Closing the lease gives
    /// the place back; the session stays open for the next user.
    func lease(
        for key: Key,
        open: @escaping @Sendable () async throws -> Session
    ) async throws -> RemuxSFTPClientLease<Client> {
        var (entryID, userID, session) = try await join(key, open: open)
        if await !session.isUsable() {
            drop(key, entryID: entryID)
            (entryID, userID, session) = try await join(key, open: open)
        }
        return RemuxSFTPClientLease(client: session.client) { [entryID, userID] in
            await self.leave(key, entryID: entryID, userID: userID)
        }
    }

    /// Runs `upload` once every upload that began before it on `key` has finished.
    func withUploadTurn<ReturnValue: Sendable>(
        for key: Key,
        _ upload: @Sendable () async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await takeUploadTurn(key)
        defer { passUploadTurn(key) }
        return try await upload()
    }

    /// Closes the matching sessions that have no users, returning once they have closed.
    func closeIdleSessions(where matches: @Sendable (Key) -> Bool) async {
        let closing = entries.filter { key, entry in matches(key) && entry.users.isEmpty }
        for (key, entry) in closing {
            entry.idleClose?.cancel()
            entries.removeValue(forKey: key)
        }
        for entry in closing.values {
            if let session = try? await entry.opening.value {
                await session.close()
            }
        }
    }

#if DEBUG
    var sessionCountForTesting: Int {
        entries.count
    }
#endif

    /// Joins the key's session as a user, opening one when the key has none.
    private func join(
        _ key: Key,
        open: @escaping @Sendable () async throws -> Session
    ) async throws -> (entryID: UUID, userID: UUID, session: Session) {
        var entry = entries[key] ?? Entry(opening: Task { try await open() })
        let userID = UUID()
        entry.users.insert(userID)
        entry.idleClose?.cancel()
        entry.idleClose = nil
        entries[key] = entry
        do {
            return (entry.id, userID, try await entry.opening.value)
        } catch {
            // A failed open isn't kept: the next user tries again.
            drop(key, entryID: entry.id)
            throw error
        }
    }

    private func leave(_ key: Key, entryID: UUID, userID: UUID) {
        guard var entry = entries[key], entry.id == entryID, entry.users.remove(userID) != nil else { return }
        if entry.users.isEmpty {
            let deadline = now() + idleTimeout
            entry.idleClose = Task { [sleep] in
                do {
                    try await sleep(deadline)
                } catch {
                    return
                }
                self.closeIfIdle(key, entryID: entryID)
            }
        }
        entries[key] = entry
    }

    private func closeIfIdle(_ key: Key, entryID: UUID) {
        guard let entry = entries[key], entry.id == entryID, entry.users.isEmpty else { return }
        drop(key, entryID: entryID)
    }

    /// Takes the session out of use. Its remaining users' leases still close normally.
    private func drop(_ key: Key, entryID: UUID) {
        guard let entry = entries[key], entry.id == entryID else { return }
        entries.removeValue(forKey: key)
        entry.idleClose?.cancel()
        Task {
            if let session = try? await entry.opening.value {
                await session.close()
            }
        }
    }

    private func takeUploadTurn(_ key: Key) async throws {
        guard uploadTurns[key] != nil else {
            uploadTurns[key] = UploadTurn()
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                uploadTurns[key, default: UploadTurn()].waiting.append((waiterID, continuation))
            }
        } onCancel: {
            Task { await self.stopWaitingForUploadTurn(key, waiterID: waiterID) }
        }
    }

    private func passUploadTurn(_ key: Key) {
        guard var turn = uploadTurns[key], !turn.waiting.isEmpty else {
            uploadTurns.removeValue(forKey: key)
            return
        }
        let next = turn.waiting.removeFirst()
        uploadTurns[key] = turn
        next.continuation.resume()
    }

    private func stopWaitingForUploadTurn(_ key: Key, waiterID: UUID) {
        guard let index = uploadTurns[key]?.waiting.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = uploadTurns[key]?.waiting.remove(at: index)
        waiter?.continuation.resume(throwing: CancellationError())
    }
}
