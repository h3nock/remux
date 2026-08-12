import Foundation
import XCTest

@testable import Remux

@MainActor
final class TerminalPreviewSessionTests: XCTestCase {
    func testReplacementIgnoresLateCompletionFromCancelledRequest() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let client = filePreviewClient { path in
            if path.hasSuffix("first.txt") {
                try? await Task.sleep(for: .milliseconds(120))
            }
            return try Self.makeResource(path: path, in: tempRoot)
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in true }
        )

        open(path: "/tmp/first.txt", in: session)
        try await Task.sleep(for: .milliseconds(10))
        open(path: "/tmp/second.txt", in: session)

        try await waitUntil("replacement did not become ready") {
            guard case .ready(let candidate, _) = session.state else { return false }
            return candidate.remotePath == "/tmp/second.txt"
        }
        try await Task.sleep(for: .milliseconds(150))
        guard case .ready(let finalCandidate, _) = session.state else {
            return XCTFail("expected ready replacement")
        }
        XCTAssertEqual(finalCandidate.remotePath, "/tmp/second.txt")
    }

    func testCloseCancelsPresentationAndLateCompletionCannotReopenIt() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let client = filePreviewClient { path in
            try? await Task.sleep(for: .milliseconds(80))
            return try Self.makeResource(path: path, in: tempRoot)
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in true }
        )

        open(path: "/tmp/slow.txt", in: session)
        session.close()
        try await Task.sleep(for: .milliseconds(120))

        if case .idle = session.state {
            XCTAssertFalse(session.isPresented)
        } else {
            XCTFail("a closed preview must remain idle")
        }
    }

    func testCloseWhileResolvingDoesNotStartFileLoad() async throws {
        let resolutions = PreviewAttemptCounter()
        let loads = PreviewAttemptCounter()
        let client = filePreviewClient { _ in
            _ = await loads.next()
            throw PreviewTestError.failed
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in true }
        )

        session.open(
            request(path: "README.md"),
            resolvingPathWith: {
                _ = await resolutions.next()
                try? await Task.sleep(for: .seconds(1))
                return "/tmp/README.md"
            }
        )
        for _ in 0..<100 {
            if await resolutions.value() != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolutionCount = await resolutions.value()
        XCTAssertEqual(resolutionCount, 1)

        session.close()
        try await Task.sleep(for: .milliseconds(50))

        let loadCount = await loads.value()
        XCTAssertEqual(loadCount, 0)
        if case .idle = session.state {
            XCTAssertFalse(session.isPresented)
        } else {
            XCTFail("a closed preview must remain idle")
        }
    }

    func testRetryReusesFailedRequest() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let attempts = PreviewAttemptCounter()
        let client = filePreviewClient { path in
            if await attempts.next() == 1 {
                throw PreviewTestError.failed
            }
            return try Self.makeResource(path: path, in: tempRoot)
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in true }
        )

        open(path: "/tmp/retry.txt", in: session)
        try await waitUntil("request did not fail") {
            if case .failed = session.state { return true }
            return false
        }
        session.restart()
        try await waitUntil("retry did not become ready") {
            if case .ready = session.state { return true }
            return false
        }

        guard case .ready(let candidate, _) = session.state else {
            return XCTFail("expected ready retry")
        }
        XCTAssertEqual(candidate.remotePath, "/tmp/retry.txt")
        let attemptCount = await attempts.value()
        XCTAssertEqual(attemptCount, 2)
    }

    func testRetryReusesResolvedPathWithoutResolvingAgain() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let resolutions = PreviewAttemptCounter()
        let attempts = PreviewAttemptCounter()
        let client = filePreviewClient { path in
            if await attempts.next() == 1 {
                throw PreviewTestError.failed
            }
            return try Self.makeResource(path: path, in: tempRoot)
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in true }
        )

        session.open(
            request(path: "/tmp/retry.txt"),
            resolvingPathWith: {
                _ = await resolutions.next()
                return "/tmp/retry-origin.txt"
            }
        )
        try await waitUntil("request did not fail") {
            if case .failed = session.state { return true }
            return false
        }
        session.restart()
        try await waitUntil("retry did not become ready") {
            if case .ready = session.state { return true }
            return false
        }

        let resolutionCount = await resolutions.value()
        XCTAssertEqual(resolutionCount, 1)
    }

    func testUnsupportedLocalArtifactProducesTruthfulFailure() async throws {
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let client = filePreviewClient { path in
            try Self.makeResource(path: path, in: tempRoot)
        }
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server",
            canPreview: { _ in false }
        )

        open(path: "/tmp/unknown.bin", in: session)
        try await waitUntil("unsupported result did not fail") {
            if case .failed = session.state { return true }
            return false
        }

        guard case .failed(let candidate, let message) = session.state else {
            return XCTFail("expected unsupported failure")
        }
        XCTAssertEqual(candidate.remotePath, "/tmp/unknown.bin")
        XCTAssertEqual(message, TerminalPreviewFileError.unsupported.localizedDescription)
    }

    private func request(path: String) -> TerminalPreviewCandidate {
        TerminalPreviewCandidate(selection: path)!
    }

    private func filePreviewClient(
        load: @escaping @Sendable (String) async throws -> TerminalPreviewFileResource
    ) -> TerminalPreviewClient {
        TerminalPreviewClient(
            loadFile: load,
            openStaticHTML: { _ in throw PreviewTestError.failed }
        )
    }

    private func open(path: String, in session: TerminalPreviewSession) {
        let candidate = request(path: path)
        session.open(candidate, resolvingPathWith: { path })
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalPreviewSessionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    nonisolated private static func makeResource(
        path: String,
        in root: URL
    ) throws -> TerminalPreviewFileResource {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(
            URL(fileURLWithPath: path).lastPathComponent
        )
        try Data("preview".utf8).write(to: url)
        return TerminalPreviewFileResource(url: url, directoryURL: directory)
    }
}

private enum PreviewTestError: Error {
    case failed
}

private actor PreviewAttemptCounter {
    private var attempts = 0

    func next() -> Int {
        attempts += 1
        return attempts
    }

    func value() -> Int {
        attempts
    }
}

@MainActor
private func waitUntil(
    _ message: String,
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline {
            XCTFail(message)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
