import CoreGraphics
import XCTest

@testable import Remux

@MainActor
final class GhosttyPanePreviewSessionTests: XCTestCase {
    func testCachedPreviewIsAvailableBeforeRefreshStarts() async throws {
        let paneID = UUID()
        let cached = try preview(paneID: paneID, marker: 1)
        var captureCount = 0
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: { _, _ in
                    captureCount += 1
                    return nil
                },
                cachedPreview: { leafID in leafID == paneID ? cached : nil },
                shouldRefreshCachedImage: { _ in false }
            )
        )

        assertReady(session.imagesByPaneID[paneID], image: cached.image, source: cached.source)
        session.startRefreshing()
        await settle()

        XCTAssertEqual(captureCount, 0)
        assertReady(session.imagesByPaneID[paneID], image: cached.image, source: cached.source)
    }

    func testColdCapturesRunSequentiallyAndCacheTheirResults() async throws {
        let first = UUID()
        let second = UUID()
        let harness = CaptureHarness()
        var cachedPaneIDs: [UUID] = []
        let session = GhosttyPanePreviewSession(
            leafIDs: [first, second],
            scale: 2,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) },
                cacheRenderedPreview: { paneID, _ in cachedPaneIDs.append(paneID) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        XCTAssertEqual(harness.requests.map(\.paneID), [first])

        let firstPreview = try preview(paneID: first, marker: 1)
        harness.resolve(paneID: first, with: firstPreview)
        try await waitUntil { harness.requests.count == 2 }
        XCTAssertEqual(harness.requests.map(\.paneID), [first, second])

        let secondPreview = try preview(paneID: second, marker: 2)
        harness.resolve(paneID: second, with: secondPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[second] { return true }
            return false
        }

        assertReady(
            session.imagesByPaneID[first],
            image: firstPreview.image,
            source: firstPreview.source
        )
        assertReady(
            session.imagesByPaneID[second],
            image: secondPreview.image,
            source: secondPreview.source
        )
        XCTAssertEqual(cachedPaneIDs, [first, second])

        let expected = PanePreviewLayout.windowPhysicalPixelBudget(
            availableWidth: 320,
            scale: 2
        )
        XCTAssertEqual(
            harness.requests.map(\.budget),
            Array(repeating: .init(width: expected.width, height: expected.height), count: 2)
        )
    }

    func testFailedRefreshPreservesExistingCachedPreview() async throws {
        let paneID = UUID()
        let cached = try preview(paneID: paneID, marker: 1)
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) },
                cachedPreview: { leafID in leafID == paneID ? cached : nil },
                shouldRefreshCachedImage: { _ in true }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        assertReady(session.imagesByPaneID[paneID], image: cached.image, source: cached.source)

        harness.resolve(paneID: paneID, with: nil)
        await settle()

        assertReady(session.imagesByPaneID[paneID], image: cached.image, source: cached.source)
    }

    func testColdFailurePublishesFailedState() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        harness.resolve(paneID: paneID, with: nil)
        try await waitUntil {
            if case .failed? = session.imagesByPaneID[paneID] { return true }
            return false
        }
    }

    func testCancelAllCancelsActiveCaptureAndIgnoresLateResult() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        session.cancelAll()

        XCTAssertEqual(harness.cancelledPaneIDs, [paneID])
        let late = try preview(paneID: paneID, marker: 2)
        harness.resolve(paneID: paneID, with: late)
        await settle()

        assertPending(session.imagesByPaneID[paneID])
    }

    func testReconcileCancelsRemovedCaptureAndStartsCurrentPane() async throws {
        let removed = UUID()
        let current = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [removed],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.map(\.paneID) == [removed] }
        session.reconcile(leafIDs: [current])
        try await waitUntil { harness.requests.map(\.paneID) == [removed, current] }

        XCTAssertEqual(harness.cancelledPaneIDs, [removed])
        XCTAssertNil(session.imagesByPaneID[removed])
        assertPending(session.imagesByPaneID[current])

        harness.resolve(paneID: removed, with: try preview(paneID: removed, marker: 1))
        let currentPreview = try preview(paneID: current, marker: 2)
        harness.resolve(paneID: current, with: currentPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[current] { return true }
            return false
        }

        XCTAssertNil(session.imagesByPaneID[removed])
        assertReady(
            session.imagesByPaneID[current],
            image: currentPreview.image,
            source: currentPreview.source
        )
    }

    func testDuplicatePaneIDsProduceOneCapture() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID, paneID, paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        XCTAssertEqual(harness.requests.map(\.paneID), [paneID])
        harness.resolve(paneID: paneID, with: nil)
    }

    func testWindowGridUsesWindowPreviewPixelBudget() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewSizing: .windowGrid(availableWidth: 320),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }

        let expected = PanePreviewLayout.windowPhysicalPixelBudget(
            availableWidth: 320,
            scale: 1
        )
        XCTAssertEqual(
            harness.requests.first?.budget,
            .init(width: expected.width, height: expected.height)
        )
        harness.resolve(paneID: paneID, with: nil)
    }

    private func preview(
        paneID: UUID,
        marker: UInt32
    ) throws -> GhosttyPanePreviewSession.RenderedPreview {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        return .init(
            image: image,
            source: .fullViewport(.init(
                surfaceID: paneID,
                pixelWidth: marker,
                pixelHeight: marker
            ))
        )
    }

    private func assertPending(
        _ state: GhosttyPanePreviewSession.PreviewState?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .pending? = state else {
            return XCTFail("expected pending preview", file: file, line: line)
        }
    }

    private func assertReady(
        _ state: GhosttyPanePreviewSession.PreviewState?,
        image: CGImage,
        source: GhosttyPanePreviewSession.PreviewSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .ready(let rendered)? = state else {
            return XCTFail("expected ready preview", file: file, line: line)
        }
        XCTAssertTrue(rendered.image === image, file: file, line: line)
        XCTAssertEqual(rendered.source, source, file: file, line: line)
    }

    private func settle() async {
        for _ in 0 ..< 8 { await Task.yield() }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw TestError.timedOut }
            await Task.yield()
        }
    }
}

@MainActor
private final class CaptureHarness {
    struct Request: Equatable {
        let paneID: UUID
        let budget: GhosttyPanePreviewSession.PixelBudget
    }

    private(set) var requests: [Request] = []
    private(set) var cancelledPaneIDs: [UUID] = []
    private var continuations: [
        UUID: CheckedContinuation<GhosttyPanePreviewSession.RenderedPreview?, Never>
    ] = [:]

    func capture(
        paneID: UUID,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> GhosttyPanePreviewSession.RenderedPreview? {
        requests.append(.init(paneID: paneID, budget: budget))
        return await withCheckedContinuation { continuations[paneID] = $0 }
    }

    func cancel(paneID: UUID) {
        cancelledPaneIDs.append(paneID)
    }

    func resolve(
        paneID: UUID,
        with result: GhosttyPanePreviewSession.RenderedPreview?
    ) {
        continuations.removeValue(forKey: paneID)?.resume(returning: result)
    }
}

private enum TestError: Error {
    case timedOut
}
