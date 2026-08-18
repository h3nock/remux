import CoreGraphics
import XCTest

@testable import Remux

@MainActor
final class GhosttyPanePreviewSessionTests: XCTestCase {
    func testCapturesRunSequentiallyAndKeepsResultsInSession() async throws {
        let first = UUID()
        let second = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [first, second],
            pixelBudget: .init(width: 640, height: 480),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        XCTAssertEqual(harness.requests.map(\.paneID), [first])

        let firstPreview = try preview(marker: 1)
        harness.resolve(paneID: first, with: firstPreview)
        try await waitUntil { harness.requests.count == 2 }
        XCTAssertEqual(harness.requests.map(\.paneID), [first, second])

        let secondPreview = try preview(marker: 2)
        harness.resolve(paneID: second, with: secondPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[second] { return true }
            return false
        }

        assertReady(session.imagesByPaneID[first], image: firstPreview)
        assertReady(session.imagesByPaneID[second], image: secondPreview)

        XCTAssertEqual(
            harness.requests.map(\.budget),
            Array(repeating: .init(width: 640, height: 480), count: 2)
        )
    }

    func testReconcileCapturesOnlyAddedPaneAndPreservesReadyImage() async throws {
        let paneID = UUID()
        let addedPaneID = UUID()
        let firstPreview = try preview(marker: 1)
        let addedPreview = try preview(marker: 2)
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            pixelBudget: .init(width: 320, height: 240),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }
        harness.resolve(paneID: paneID, with: firstPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[paneID] { return true }
            return false
        }

        session.reconcile(leafIDs: [paneID, addedPaneID])
        try await waitUntil { harness.requests.count == 2 }

        XCTAssertEqual(harness.requests.map(\.paneID), [paneID, addedPaneID])
        assertReady(session.imagesByPaneID[paneID], image: firstPreview)
        harness.resolve(paneID: addedPaneID, with: addedPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[addedPaneID] { return true }
            return false
        }
        assertReady(session.imagesByPaneID[paneID], image: firstPreview)
        assertReady(session.imagesByPaneID[addedPaneID], image: addedPreview)
    }

    func testReconcileDoesNotReplaceRetainedActiveCapture() async throws {
        let active = UUID()
        let removed = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [active, removed],
            pixelBudget: .init(width: 320, height: 240),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                },
                cancelCapture: { harness.cancel(paneID: $0) }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.map(\.paneID) == [active] }
        session.reconcile(leafIDs: [active])

        XCTAssertEqual(harness.requests.map(\.paneID), [active])
        XCTAssertTrue(harness.cancelledPaneIDs.isEmpty)

        let preview = try preview(marker: 1)
        harness.resolve(paneID: active, with: preview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[active] { return true }
            return false
        }
        assertReady(session.imagesByPaneID[active], image: preview)
    }

    func testColdFailurePublishesFailedState() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            pixelBudget: .init(width: 320, height: 240),
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
            pixelBudget: .init(width: 320, height: 240),
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
        let late = try preview(marker: 2)
        harness.resolve(paneID: paneID, with: late)
        try await waitUntil { harness.completedPaneIDs == [paneID] }

        assertPending(session.imagesByPaneID[paneID])
    }

    func testReconcileCancelsRemovedCaptureAndStartsCurrentPane() async throws {
        let removed = UUID()
        let current = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [removed],
            pixelBudget: .init(width: 320, height: 240),
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

        XCTAssertEqual(harness.cancelledPaneIDs, [removed])
        XCTAssertEqual(harness.requests.map(\.paneID), [removed])
        XCTAssertNil(session.imagesByPaneID[removed])

        harness.resolve(paneID: removed, with: try preview(marker: 1))
        try await waitUntil { harness.requests.map(\.paneID) == [removed, current] }
        assertPending(session.imagesByPaneID[current])

        let currentPreview = try preview(marker: 2)
        harness.resolve(paneID: current, with: currentPreview)
        try await waitUntil {
            if case .ready? = session.imagesByPaneID[current] { return true }
            return false
        }

        XCTAssertNil(session.imagesByPaneID[removed])
        assertReady(session.imagesByPaneID[current], image: currentPreview)
    }

    func testDuplicatePaneIDsProduceOneCapture() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID, paneID, paneID],
            pixelBudget: .init(width: 320, height: 240),
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
        try await waitUntil {
            if case .failed? = session.imagesByPaneID[paneID] { return true }
            return false
        }
    }

    func testCaptureUsesTheProvidedWindowPreviewPixelBudget() async throws {
        let paneID = UUID()
        let harness = CaptureHarness()
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            pixelBudget: .init(width: 304, height: 228),
            client: .init(
                capture: {
                    await harness.capture(paneID: $0, budget: $1)
                }
            )
        )

        session.startRefreshing()
        try await waitUntil { harness.requests.count == 1 }

        XCTAssertEqual(
            harness.requests.first?.budget,
            .init(width: 304, height: 228)
        )
        harness.resolve(paneID: paneID, with: nil)
        try await waitUntil {
            if case .failed? = session.imagesByPaneID[paneID] { return true }
            return false
        }
    }

    private func preview(marker: UInt32) throws -> CGImage {
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
        context.setFillColor(
            red: CGFloat(marker % 255) / 255,
            green: 0,
            blue: 0,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
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
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .ready(let renderedImage)? = state else {
            return XCTFail("expected ready preview", file: file, line: line)
        }
        XCTAssertTrue(renderedImage === image, file: file, line: line)
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
    private(set) var completedPaneIDs: [UUID] = []
    private var continuations: [
        UUID: CheckedContinuation<CGImage?, Never>
    ] = [:]

    func capture(
        paneID: UUID,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> CGImage? {
        requests.append(.init(paneID: paneID, budget: budget))
        let result = await withCheckedContinuation { continuations[paneID] = $0 }
        completedPaneIDs.append(paneID)
        return result
    }

    func cancel(paneID: UUID) {
        cancelledPaneIDs.append(paneID)
    }

    func resolve(
        paneID: UUID,
        with result: CGImage?
    ) {
        continuations.removeValue(forKey: paneID)?.resume(returning: result)
    }
}

private enum TestError: Error {
    case timedOut
}
