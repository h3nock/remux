import Foundation
import NIOCore

/// An upload's writes: up to `maxInFlight` writes outstanding at once over the whole file, each next one read from the
/// local file as an earlier one is acknowledged, so the link stays busy until the last byte. Progress is the bytes
/// acknowledged. The upload fails with `RemuxSFTPClientError.operationTimedOut`, after `onTimeout`, once its session
/// has gone without an answer for `noProgressTimeout` (`activity` records each one): a slow link still makes
/// progress, a dead one doesn't.
struct RemuxSFTPUploadWindow: Sendable {
    /// 64 writes keep about 2 MB on the way, enough to fill a far link.
    static let defaultMaxInFlight = 64
    /// The most one write carries: Citadel sends anything longer as several writes, one after another.
    static let defaultWriteLength = 32_000

    var maxInFlight = Self.defaultMaxInFlight
    var writeLength = Self.defaultWriteLength
    var noProgressTimeout: TimeAmount
    /// Reports go to the screen, so they come at most this often, besides the last.
    var progressInterval: Duration = .milliseconds(100)

    /// Uploads `localFile` through `write`, and closes it when done. After a timeout or cancellation this returns at
    /// once; writes already sent finish on their own.
    func upload(
        _ localFile: FileHandle,
        activity: RemuxLastActivity,
        onTimeout: @escaping @Sendable () async -> Void,
        progress: @escaping RemuxSFTPFileUploadProgressHandler,
        write: @escaping @Sendable (Data, UInt64) async throws -> Void
    ) async throws {
        try await RemuxSFTPTimeout.run(
            timeout: noProgressTimeout,
            extendWhile: { windowStart in activity.hasRecorded(since: windowStart) },
            operation: { [self] in
                defer { try? localFile.close() }
                try await writeAll(localFile, activity: activity, progress: progress, write: write)
            },
            onTimeout: onTimeout
        )
    }

    private func writeAll(
        _ localFile: FileHandle,
        activity: RemuxLastActivity,
        progress: RemuxSFTPFileUploadProgressHandler,
        write: @escaping @Sendable (Data, UInt64) async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        var lastReport = clock.now
        var acknowledged: Int64 = 0
        var reported: Int64 = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextOffset: UInt64 = 0
            var inFlight = 0
            var readAll = false
            while true {
                while !readAll, inFlight < maxInFlight {
                    try Task.checkCancellation()
                    guard let data = try localFile.read(upToCount: writeLength), !data.isEmpty else {
                        readAll = true
                        break
                    }
                    let offset = nextOffset
                    nextOffset += UInt64(data.count)
                    inFlight += 1
                    group.addTask {
                        // A failed write is an answer too, and the session is shared.
                        defer { activity.record() }
                        try await write(data, offset)
                        return data.count
                    }
                }
                guard let written = try await group.next() else { break }
                inFlight -= 1
                acknowledged += Int64(written)
                if clock.now - lastReport >= progressInterval {
                    lastReport = clock.now
                    reported = acknowledged
                    try Task.checkCancellation()
                    await progress(acknowledged)
                }
            }
        }
        if acknowledged > reported {
            try Task.checkCancellation()
            await progress(acknowledged)
        }
    }
}
