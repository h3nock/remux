import Foundation
import NIOCore
import Synchronization
import XCTest
@testable import Remux

final class RemuxSFTPUploadWindowTests: XCTestCase {
    func testKeepsTheWindowFullUntilTheLastWriteAndWritesEveryByteOnce() async throws {
        let contents = Data((0..<40).map { UInt8($0) })
        let file = try makeLocalFile(contents)
        let writes = GatedWrites()
        let window = RemuxSFTPUploadWindow(
            maxInFlight: 3,
            writeLength: 4,
            noProgressTimeout: .seconds(30)
        )

        let upload = Task {
            try await window.upload(
                file,
                activity: RemuxLastActivity(),
                onTimeout: {},
                progress: { _ in },
                write: { data, offset in try await writes.write(data, at: offset) }
            )
        }
        try await waitUntil { writes.pendingOffsets == [0, 4, 8] }

        // Each acknowledgement sends the next write at once, with the others still on the way.
        writes.acknowledge(0)
        try await waitUntil { writes.pendingOffsets == [4, 8, 12] }
        writes.acknowledge(8)
        try await waitUntil { writes.pendingOffsets == [4, 12, 16] }
        let deadline = ContinuousClock.now + .seconds(5)
        while writes.issuedCount < 10 || !writes.pendingOffsets.isEmpty, ContinuousClock.now < deadline {
            if let next = writes.pendingOffsets.first {
                writes.acknowledge(next)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await upload.value

        XCTAssertEqual(writes.maximumInFlight, 3)
        XCTAssertEqual(writes.writtenBytes, contents)
        XCTAssertTrue(writes.lengths.allSatisfy { $0 <= 4 })
    }

    func testReportsAcknowledgedBytesAndAlwaysTheLast() async throws {
        let contents = Data(repeating: 7, count: 10)
        let everyAcknowledgement = ProgressLog()
        try await RemuxSFTPUploadWindow(
            maxInFlight: 1,
            writeLength: 4,
            noProgressTimeout: .seconds(30),
            progressInterval: .zero
        ).upload(
            try makeLocalFile(contents),
            activity: RemuxLastActivity(),
            onTimeout: {},
            progress: { everyAcknowledgement.append($0) },
            write: { _, _ in }
        )
        XCTAssertEqual(everyAcknowledgement.values, [4, 8, 10])

        let throttled = ProgressLog()
        try await RemuxSFTPUploadWindow(
            maxInFlight: 1,
            writeLength: 4,
            noProgressTimeout: .seconds(30),
            progressInterval: .seconds(3600)
        ).upload(
            try makeLocalFile(contents),
            activity: RemuxLastActivity(),
            onTimeout: {},
            progress: { throttled.append($0) },
            write: { _, _ in }
        )
        XCTAssertEqual(throttled.values, [10])
    }

    func testFailsAfterTheTimeoutWhenNoWriteIsAcknowledged() async throws {
        let timeouts = Counter()
        let start = ContinuousClock.now

        do {
            try await RemuxSFTPUploadWindow(maxInFlight: 2, writeLength: 4, noProgressTimeout: .milliseconds(200))
                .upload(
                    try makeLocalFile(Data(repeating: 1, count: 16)),
                    activity: RemuxLastActivity(),
                    onTimeout: { timeouts.increment() },
                    progress: { _ in },
                    write: { _, _ in try await Task.sleep(for: .seconds(30)) }
                )
            XCTFail("Expected the upload to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(timeouts.value, 1)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        XCTAssertLessThan(elapsed, .seconds(5), "it returns without waiting for the stuck writes")
    }

    func testSlowButSteadyAcknowledgementsNeverTimeOut() async throws {
        let progress = ProgressLog()

        // Eight writes, one at a time, each acknowledged within the timeout: the whole upload takes about three
        // timeouts.
        try await RemuxSFTPUploadWindow(maxInFlight: 1, writeLength: 4, noProgressTimeout: .milliseconds(150))
            .upload(
                try makeLocalFile(Data(repeating: 2, count: 32)),
                activity: RemuxLastActivity(),
                onTimeout: { XCTFail("The upload made progress") },
                progress: { progress.append($0) },
                write: { _, _ in try await Task.sleep(for: .milliseconds(60)) }
            )

        XCTAssertEqual(progress.values.last, 32)
    }

    func testCancellationReturnsAtOnceAndSendsNoMoreWrites() async throws {
        let writes = GatedWrites()
        let timeouts = Counter()
        let localFile = try makeLocalFile(Data(repeating: 4, count: 16))
        let uploading = Task {
            try await RemuxSFTPUploadWindow(maxInFlight: 2, writeLength: 4, noProgressTimeout: .seconds(30))
                .upload(
                    localFile,
                    activity: RemuxLastActivity(),
                    onTimeout: { timeouts.increment() },
                    progress: { _ in },
                    write: { data, offset in try await writes.write(data, at: offset) }
                )
        }
        try await waitUntil { writes.pendingOffsets.count == 2 }

        let start = ContinuousClock.now
        uploading.cancel()
        do {
            try await uploading.value
            XCTFail("Expected the upload to stop")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "it returns without waiting for the sent writes")

        // The writes already sent finish on their own; nothing more goes out.
        for offset in writes.pendingOffsets {
            writes.acknowledge(offset)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes.issuedCount, 2)
        XCTAssertEqual(timeouts.value, 0)
    }

    func testWriteFailureFailsTheUpload() async throws {
        do {
            try await RemuxSFTPUploadWindow(maxInFlight: 4, writeLength: 4, noProgressTimeout: .seconds(30))
                .upload(
                    try makeLocalFile(Data(repeating: 3, count: 32)),
                    activity: RemuxLastActivity(),
                    onTimeout: {},
                    progress: { _ in },
                    write: { _, offset in
                        if offset == 8 { throw WriteFailure() }
                    }
                )
            XCTFail("Expected the upload to fail")
        } catch is WriteFailure {
        }
    }

    func testAFailedWriteWithAnotherStuckEndsOnTheSessionsSilence() async throws {
        // A failure ends the upload only once the other writes are answered, and a sent write can't be cancelled;
        // when one is never answered and nothing else is, the session's silence ends the upload instead.
        let writes = GatedWrites()
        let timeouts = Counter()
        let failures = Counter()
        // Should the upload wait for the stuck write, this frees it so the test fails rather than hangs.
        let release = Task {
            try await Task.sleep(for: .seconds(5))
            writes.acknowledge(0)
        }
        let start = ContinuousClock.now

        do {
            try await RemuxSFTPUploadWindow(maxInFlight: 2, writeLength: 4, noProgressTimeout: .milliseconds(200))
                .upload(
                    try makeLocalFile(Data(repeating: 6, count: 8)),
                    activity: RemuxLastActivity(),
                    onTimeout: { timeouts.increment() },
                    progress: { _ in },
                    write: { data, offset in
                        if offset == 4 {
                            failures.increment()
                            throw WriteFailure()
                        }
                        try await writes.write(data, at: offset)
                    }
                )
            XCTFail("Expected the upload to time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        }

        XCTAssertEqual(failures.value, 1)
        XCTAssertEqual(timeouts.value, 1)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4), "it returns without waiting for the stuck write")
        release.cancel()
        try await waitUntil { writes.pendingOffsets == [0] }
        writes.acknowledge(0)
    }

    func testAFailedWriteStillCountsAsTheSessionAnswering() async throws {
        // The session is shared: a preview waiting on it must not time out while the server is answering, even
        // when the answers are this upload's write failures.
        let activity = RemuxLastActivity()
        let start = NIODeadline.now()

        do {
            try await RemuxSFTPUploadWindow(maxInFlight: 1, writeLength: 4, noProgressTimeout: .seconds(30))
                .upload(
                    try makeLocalFile(Data(repeating: 5, count: 4)),
                    activity: activity,
                    onTimeout: {},
                    progress: { _ in },
                    write: { _, _ in throw WriteFailure() }
                )
            XCTFail("Expected the upload to fail")
        } catch is WriteFailure {
        }

        XCTAssertTrue(activity.hasRecorded(since: start))
    }

    func testEmptyFileWritesNothing() async throws {
        let writes = Counter()

        try await RemuxSFTPUploadWindow(noProgressTimeout: .seconds(30)).upload(
            try makeLocalFile(Data()),
            activity: RemuxLastActivity(),
            onTimeout: {},
            progress: { _ in },
            write: { _, _ in writes.increment() }
        )

        XCTAssertEqual(writes.value, 0)
    }

    private func makeLocalFile(_ contents: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-upload-window-\(UUID().uuidString)")
        try contents.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return try FileHandle(forReadingFrom: url)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }
}

private struct WriteFailure: Error {}

/// Writes that wait until the test acknowledges them.
private final class GatedWrites: Sendable {
    private struct State {
        var pending: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var written: [UInt64: Data] = [:]
        var lengths: [Int] = []
        var maximumInFlight = 0
    }

    private let state = Mutex(State())

    var pendingOffsets: [UInt64] {
        state.withLock { $0.pending.keys.sorted() }
    }

    var maximumInFlight: Int {
        state.withLock { $0.maximumInFlight }
    }

    var lengths: [Int] {
        state.withLock { $0.lengths }
    }

    var issuedCount: Int {
        state.withLock { $0.lengths.count }
    }

    var writtenBytes: Data {
        state.withLock { state in
            state.written.keys.sorted().reduce(into: Data()) { $0.append(state.written[$1]!) }
        }
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.pending[offset] = continuation
                state.written[offset] = data
                state.lengths.append(data.count)
                state.maximumInFlight = max(state.maximumInFlight, state.pending.count)
            }
        }
    }

    func acknowledge(_ offset: UInt64) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: offset) }
        continuation?.resume()
    }
}

private final class ProgressLog: Sendable {
    private let entries = Mutex<[Int64]>([])

    var values: [Int64] {
        entries.withLock { $0 }
    }

    func append(_ value: Int64) {
        entries.withLock { $0.append(value) }
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
