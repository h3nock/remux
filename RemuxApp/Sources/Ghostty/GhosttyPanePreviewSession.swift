import UIKit

/// Picker-scoped window previews, keyed by each window's focused pane, and one
/// sequential capture task. Native renderers and terminals stay owned by the
/// session behind PreviewClient.
@MainActor
final class GhosttyPanePreviewSession: ObservableObject {
    /// The size a preview is drawn at, in device pixels.
    struct PixelBudget: Equatable, Sendable {
        let width: UInt32
        let height: UInt32
    }

    /// A window's preview, in points: its panes' pixels, each image with the scale it is drawn at,
    /// where the window has them, and the lines between panes.
    struct Preview: Sendable {
        struct Pane: Sendable {
            let image: UIImage
            let origin: CGPoint
        }

        struct Line: Sendable {
            let start: CGPoint
            let end: CGPoint
        }

        let size: CGSize
        let panes: [Pane]
        let separators: [Line]
    }

    struct PreviewClient {
        /// The preview, for the budget, of the window a pane is the focused one of.
        let capture: @MainActor (UUID, PixelBudget) async -> Preview?
        let cancelCapture: @MainActor (UUID) -> Void

        init(
            capture: @escaping @MainActor (UUID, PixelBudget) async -> Preview?,
            cancelCapture: @escaping @MainActor (UUID) -> Void = { _ in }
        ) {
            self.capture = capture
            self.cancelCapture = cancelCapture
        }
    }

    enum PreviewState {
        case pending
        case ready(Preview)
        case failed
    }

    let id = UUID()
    @Published private(set) var imagesByPaneID: [UUID: PreviewState] = [:]

    private let client: PreviewClient
    private var trackedLeafIDs: [UUID]
    /// Nil until the picker says what size it draws previews at.
    private var pixelBudget: PixelBudget?
    private var refreshTask: Task<Void, Never>?
    private var cancelled = false
    private var activeCaptureLeafID: UUID?
    private var activeCaptureIsValid = false

    init(
        leafIDs: [UUID],
        client: PreviewClient
    ) {
        self.client = client
        trackedLeafIDs = Self.unique(leafIDs)
    }

    /// Captures the previews for the size the picker draws them at. Another size, as after a rotation,
    /// captures them again: a preview covers exactly the area it was captured for.
    func present(pixelBudget: PixelBudget) {
        guard !cancelled, pixelBudget != self.pixelBudget else { return }
        self.pixelBudget = pixelBudget
        cancelActiveCapture()
        imagesByPaneID.removeAll()
        startRefreshIfNeeded()
    }

    func reconcile(leafIDs: [UUID]) {
        let next = Self.unique(leafIDs)
        guard next != trackedLeafIDs else { return }
        let nextSet = Set(next)
        for removed in imagesByPaneID.keys where !nextSet.contains(removed) {
            imagesByPaneID.removeValue(forKey: removed)
        }
        trackedLeafIDs = next
        guard pixelBudget != nil, !cancelled else { return }
        if let activeCaptureLeafID, !nextSet.contains(activeCaptureLeafID) {
            cancelActiveCapture()
        }
        startRefreshIfNeeded()
    }

    func cancelAll() {
        guard !cancelled else { return }
        cancelled = true
        cancelActiveCapture()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func startRefreshIfNeeded() {
        guard refreshTask == nil, !cancelled, nextCaptureLeafID != nil else { return }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            while let pixelBudget, let leafID = nextCaptureLeafID {
                guard !Task.isCancelled, !cancelled else { return }
                imagesByPaneID[leafID] = .pending
                activeCaptureLeafID = leafID
                activeCaptureIsValid = true
                let preview = await client.capture(leafID, pixelBudget)
                let captureIsValid = activeCaptureLeafID == leafID
                    && activeCaptureIsValid
                if activeCaptureLeafID == leafID {
                    activeCaptureLeafID = nil
                    activeCaptureIsValid = false
                }
                guard !Task.isCancelled, !cancelled else { return }
                guard captureIsValid, trackedLeafIDs.contains(leafID) else {
                    continue
                }
                if let preview {
                    imagesByPaneID[leafID] = .ready(preview)
                } else {
                    imagesByPaneID[leafID] = .failed
                }
            }
        }
    }

    private func cancelActiveCapture() {
        guard let leafID = activeCaptureLeafID else { return }
        activeCaptureIsValid = false
        client.cancelCapture(leafID)
    }

    private var nextCaptureLeafID: UUID? {
        guard pixelBudget != nil else { return nil }
        return trackedLeafIDs.first { imagesByPaneID[$0] == nil }
    }

    private static func unique(_ leafIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return leafIDs.filter { seen.insert($0).inserted }
    }
}
