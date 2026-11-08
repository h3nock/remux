import Foundation
import Synchronization
import XCTest
@testable import Remux

final class TerminalPreviewRemoteFileReaderTests: XCTestCase {
    private static let length = TerminalPreviewRemoteFileReader.readLength
    private var length: Int { Self.length }

    func testKnownSizeReadsEightAtATimeAndHandsDataOnInOrder() async throws {
        let contents = Self.patternedData(count: 20 * length + 1_000)
        // Within each window the earlier reads answer last.
        let client = WindowReadClient(contents: contents, delay: { offset in
            .milliseconds(8 - Int(offset / UInt64(Self.length)) % 8)
        })
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
        let requests = client.requests
        let size = UInt64(contents.count)
        let chunkOffsets = stride(from: UInt64(0), to: size, by: length).map { $0 }
        XCTAssertEqual(Set(requests.map(\.offset)), Set(chunkOffsets + [size]))
        // The end came back before the reads ahead of it (they answer last here), so one more read confirmed it.
        XCTAssertEqual(requests.filter { $0.offset == size }.count, 2)
        XCTAssertEqual(requests.count, chunkOffsets.count + 2)
        for request in requests where request.offset < size {
            XCTAssertEqual(UInt64(request.length), min(UInt64(length), size - request.offset))
        }
        XCTAssertEqual(client.maximumInFlight, TerminalPreviewRemoteFileReader.readWindow)
    }

    /// Answers in the order the reads went out, as OpenSSH's server gives them: the end comes back last and is not
    /// read again.
    func testEndThatComesBackLastIsNotReadAgain() async throws {
        let contents = Self.patternedData(count: 3 * length + 1_000)
        // Later offsets answer later; the end, past the last chunk's start, answers after every chunk.
        let client = WindowReadClient(contents: contents, delay: { offset in
            .milliseconds(1 + Int((offset + UInt64(Self.length) - 1) / UInt64(Self.length)) * 10)
        })
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
        XCTAssertEqual(client.requests.filter { $0.offset == UInt64(contents.count) }.count, 1)
        XCTAssertEqual(client.requests.count, 5)
    }

    func testShortReadReadsTheRestOneAtATime() async throws {
        let cap = 100 * 1024
        let contents = Self.patternedData(count: 3 * length)
        let client = WindowReadClient(contents: contents, maximumReplyLength: cap)
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
        // The window's reads (three chunks and the read at the end) went out together; after the first came back
        // short, the rest of the file was read in order, one read at a time.
        let afterWindow = Array(client.requests.dropFirst(4))
        let size = UInt64(contents.count)
        XCTAssertEqual(afterWindow.map(\.offset), stride(from: UInt64(cap), to: size, by: cap).map { $0 } + [size])
        XCTAssertTrue(afterWindow.allSatisfy { $0.inFlight == 1 })
    }

    func testFileThatGrewIsReadToItsEndWithoutAWaitForTheEnd() async throws {
        let declared = 1_000
        let contents = Self.patternedData(count: declared + 2 * length + 5)
        let probeRequested = AsyncFlag()
        let client = WindowReadClient(
            contents: contents,
            declaredSize: .bytes(UInt64(declared)),
            maximumReplyLength: length,
            beforeReply: { offset in
                if offset == UInt64(declared) {
                    await probeRequested.set()
                } else if offset == 0 {
                    // The read at the known size goes out with the file's first bytes.
                    await probeRequested.wait()
                }
            }
        )
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
    }

    /// The read at the known size finds the end first, then the file grows before the window's first read is back:
    /// that end is out of date, and the bytes written meanwhile are still read.
    func testFileThatGrowsAfterItsEndCameBackEarlyIsReadToItsNewEnd() async throws {
        let original = Self.patternedData(count: 1_000)
        let appended = Data("written while the preview read".utf8)
        let endAnswered = AsyncFlag()
        let client = WindowReadClientBox()
        client.value = WindowReadClient(
            contents: original,
            beforeReply: { offset in
                if offset == 0 {
                    await endAnswered.wait()
                    client.value?.append(appended)
                }
            }
        )
        let reading = Task { [client] in
            let received = ReceivedData()
            _ = try await streamFile(client.value!, maximumByteCount: 64 * 1024 * 1024, into: received)
            return received.data
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.value!.requests.contains(where: { $0.offset == UInt64(original.count) }) == false,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        // Give the end's empty answer time to come back before the first read's.
        try await Task.sleep(for: .milliseconds(50))
        await endAnswered.set()

        let received = try await reading.value
        XCTAssertEqual(received, original + appended)
    }

    func testFileThatGrewPastTheMaximumIsTooLarge() async throws {
        let client = WindowReadClient(contents: Self.patternedData(count: 2_500), declaredSize: .bytes(1_500))

        do {
            _ = try await streamFile(client, maximumByteCount: 2_000, into: ReceivedData())
            XCTFail("Expected the read to fail")
        } catch let error as TerminalPreviewFileError {
            XCTAssertEqual(error, .tooLarge(maximumByteCount: 2_000))
        }
        let readAtEnd = client.requests.first { $0.offset == 1_500 }
        XCTAssertEqual(readAtEnd?.length, 501, "one byte past the maximum shows the file is over it")
    }

    func testFileThatShrankEndsAtItsLastByte() async throws {
        let contents = Self.patternedData(count: length + 10)
        let client = WindowReadClient(contents: contents, declaredSize: .bytes(UInt64(3 * length)))
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
    }

    func testUnknownSizeReadsOneAtATimeToTheEnd() async throws {
        let contents = Self.patternedData(count: 2 * length + length / 2)
        let client = WindowReadClient(contents: contents, declaredSize: .unknown, maximumReplyLength: length)
        let received = ReceivedData()

        _ = try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: received)

        XCTAssertEqual(received.data, contents)
        XCTAssertEqual(client.requests.map(\.offset), [0, UInt64(length), UInt64(2 * length), UInt64(contents.count)])
        XCTAssertEqual(client.maximumInFlight, 1)
    }

    func testCancellationCancelsTheOutstandingReads() async throws {
        let client = WindowReadClient(contents: Self.patternedData(count: 20 * length), delay: { _ in .seconds(30) })
        let reading = Task {
            try await streamFile(client, maximumByteCount: 64 * 1024 * 1024, into: ReceivedData())
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.requests.count < TerminalPreviewRemoteFileReader.readWindow, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let start = ContinuousClock.now
        reading.cancel()

        do {
            _ = try await reading.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(client.requests.count, TerminalPreviewRemoteFileReader.readWindow)
        XCTAssertEqual(client.cancelledReads, TerminalPreviewRemoteFileReader.readWindow)
    }

    private static func patternedData(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
    }
}

private func streamFile(
    _ client: WindowReadClient,
    maximumByteCount: UInt64,
    into received: ReceivedData
) async throws -> RemuxSFTPFileMetadata {
    try await TerminalPreviewRemoteFileReader.stream(
        client: client,
        remotePath: "/srv/file.bin",
        maximumByteCount: maximumByteCount
    ) { data in
        received.append(data)
    }
}

/// A remote file whose reads can answer late or short, recording each read as it goes out.
private final class WindowReadClient: RemuxSFTPReadOnlyClient {
    enum DeclaredSize {
        case actual
        case unknown
        case bytes(UInt64)
    }

    struct Request: Equatable, Sendable {
        let offset: UInt64
        let length: Int
        /// Reads outstanding when this one went out, itself included.
        let inFlight: Int
    }

    private struct State {
        var contents: Data
        var requests: [Request] = []
        var inFlight = 0
        var maximumInFlight = 0
        var cancelledReads = 0
    }

    private let declaredSize: UInt64?
    private let maximumReplyLength: Int?
    private let delay: @Sendable (UInt64) -> Duration?
    private let beforeReply: @Sendable (UInt64) async -> Void
    private let state: Mutex<State>

    init(
        contents: Data,
        declaredSize: DeclaredSize = .actual,
        maximumReplyLength: Int? = nil,
        beforeReply: @escaping @Sendable (UInt64) async -> Void = { _ in },
        delay: @escaping @Sendable (UInt64) -> Duration? = { _ in nil }
    ) {
        self.state = Mutex(State(contents: contents))
        switch declaredSize {
        case .actual: self.declaredSize = UInt64(contents.count)
        case .unknown: self.declaredSize = nil
        case .bytes(let size): self.declaredSize = size
        }
        self.maximumReplyLength = maximumReplyLength
        self.beforeReply = beforeReply
        self.delay = delay
    }

    var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// The file grows, as a log being written does.
    func append(_ data: Data) {
        state.withLock { $0.contents.append(data) }
    }

    var maximumInFlight: Int {
        state.withLock { $0.maximumInFlight }
    }

    var cancelledReads: Int {
        state.withLock { $0.cancelledReads }
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        RemuxSFTPFileMetadata(size: declaredSize, permissions: nil, modificationDate: nil)
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        knownMetadata: RemuxSFTPFileMetadata?,
        _ operation: @Sendable (RemuxSFTPReadableFile, RemuxSFTPFileMetadata) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let metadata = try await metadata(atPath: path)
        return try await operation(RemuxSFTPReadableFile { offset, length in
            try await self.read(offset: offset, length: Int(length))
        }, knownMetadata ?? metadata)
    }

    private func read(offset: UInt64, length: Int) async throws -> Data {
        state.withLock { state in
            state.inFlight += 1
            state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
            state.requests.append(Request(offset: offset, length: length, inFlight: state.inFlight))
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        await beforeReply(offset)
        if let delay = delay(offset) {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.cancelledReads += 1 }
                throw error
            }
        }
        let contents = state.withLock { $0.contents }
        let start = min(Int(offset), contents.count)
        let end = min(start + min(length, maximumReplyLength ?? length), contents.count)
        return contents.subdata(in: start..<end)
    }
}

private final class ReceivedData: Sendable {
    private let received = Mutex(Data())

    var data: Data {
        received.withLock { $0 }
    }

    func append(_ data: Data) {
        received.withLock { $0.append(data) }
    }
}

private actor AsyncFlag {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSet else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Lets a client's reply hook reach the client it belongs to.
private final class WindowReadClientBox: @unchecked Sendable {
    var value: WindowReadClient?
}
