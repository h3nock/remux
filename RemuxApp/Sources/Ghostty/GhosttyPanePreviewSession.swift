import CoreGraphics
import Foundation

/// Picker-scoped cached image state plus one sequential asynchronous capture
/// task. Native renderer and terminal lifetime remain owned by the tmux
/// session; this type owns no handles, callbacks, retries, or render queue.
@MainActor
final class GhosttyPanePreviewSession: ObservableObject {
    struct FullViewportProvenance: Equatable {
        let surfaceID: UUID
        let pixelWidth: UInt32
        let pixelHeight: UInt32
    }

    struct PaneGeometryProvenance: Equatable {
        let surfaceID: UUID
        let columns: UInt32
        let rows: UInt32
    }

    enum PreviewSource: Equatable {
        case paneGeometry(PaneGeometryProvenance)
        case fullViewport(FullViewportProvenance)
    }

    struct RenderedPreview {
        let image: CGImage
        let source: PreviewSource
    }

    struct PixelBudget: Equatable, Sendable {
        let width: UInt32
        let height: UInt32
    }

    struct PreviewClient {
        let capture: @MainActor (UUID, PixelBudget) async -> RenderedPreview?
        let cancelCapture: @MainActor (UUID) -> Void
        let cachedPreview: @MainActor (UUID) -> RenderedPreview?
        let shouldRefreshCachedImage: @MainActor (UUID) -> Bool
        let cacheRenderedPreview: @MainActor (UUID, RenderedPreview) -> Void

        init(
            capture: @escaping @MainActor (UUID, PixelBudget) async -> RenderedPreview?,
            cancelCapture: @escaping @MainActor (UUID) -> Void = { _ in },
            cachedPreview: @escaping @MainActor (UUID) -> RenderedPreview? = { _ in nil },
            shouldRefreshCachedImage: @escaping @MainActor (UUID) -> Bool = { _ in true },
            cacheRenderedPreview: @escaping @MainActor (UUID, RenderedPreview) -> Void = { _, _ in }
        ) {
            self.capture = capture
            self.cancelCapture = cancelCapture
            self.cachedPreview = cachedPreview
            self.shouldRefreshCachedImage = shouldRefreshCachedImage
            self.cacheRenderedPreview = cacheRenderedPreview
        }
    }

    enum PreviewSizing: Equatable {
        case paneMap(availableWidth: CGFloat, maximumHeight: CGFloat)
        case windowGrid(availableWidth: CGFloat)

        @MainActor
        static var paneMapForCurrentScreen: PreviewSizing {
            .paneMap(
                availableWidth: PanePreviewLayout.currentSheetContentWidth(),
                maximumHeight: PanePreviewLayout.currentPaneMapMaximumHeight()
            )
        }

        @MainActor
        static var windowGridForCurrentScreen: PreviewSizing {
            .windowGrid(availableWidth: PanePreviewLayout.currentSheetContentWidth())
        }
    }

    enum PreviewState {
        case pending
        case ready(RenderedPreview)
        case failed
    }

    let id = UUID()
    @Published private(set) var imagesByPaneID: [UUID: PreviewState] = [:]

    private let displayScale: CGFloat
    private let previewSizing: PreviewSizing
    private let client: PreviewClient
    private var trackedLeafIDs: [UUID]
    private var refreshTask: Task<Void, Never>?
    private var didStartRefreshing = false
    private var cancelled = false
    private var generation: UInt64 = 0
    private var activeCaptureLeafID: UUID?

    init(
        leafIDs: [UUID],
        scale: CGFloat = PanePreviewLayout.currentScale(),
        previewSizing: PreviewSizing,
        client: PreviewClient
    ) {
        displayScale = scale
        self.previewSizing = previewSizing
        self.client = client
        trackedLeafIDs = Self.unique(leafIDs)
        seedCachedImages(for: trackedLeafIDs)
    }

    func startRefreshing() {
        guard !didStartRefreshing, !cancelled else { return }
        didStartRefreshing = true
        restartRefresh()
    }

    func reconcile(leafIDs: [UUID]) {
        let next = Self.unique(leafIDs)
        guard next != trackedLeafIDs else { return }
        let nextSet = Set(next)
        for removed in imagesByPaneID.keys where !nextSet.contains(removed) {
            imagesByPaneID.removeValue(forKey: removed)
        }
        trackedLeafIDs = next
        seedCachedImages(for: next)
        guard didStartRefreshing, !cancelled else { return }
        restartRefresh()
    }

    func cancelAll() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        cancelActiveCapture()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func restartRefresh() {
        generation &+= 1
        let currentGeneration = generation
        let leafIDs = trackedLeafIDs
        let budget = pixelBudget()
        cancelActiveCapture()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for leafID in leafIDs {
                guard !Task.isCancelled,
                      !cancelled,
                      generation == currentGeneration,
                      trackedLeafIDs.contains(leafID)
                else { return }

                let cached = client.cachedPreview(leafID)
                if let cached { imagesByPaneID[leafID] = .ready(cached) }
                guard cached == nil || client.shouldRefreshCachedImage(leafID) else { continue }
                if cached == nil { imagesByPaneID[leafID] = .pending }

                activeCaptureLeafID = leafID
                let preview = await client.capture(leafID, budget)
                if activeCaptureLeafID == leafID { activeCaptureLeafID = nil }
                guard !Task.isCancelled,
                      !cancelled,
                      generation == currentGeneration,
                      trackedLeafIDs.contains(leafID)
                else { return }
                if let preview {
                    client.cacheRenderedPreview(leafID, preview)
                    imagesByPaneID[leafID] = .ready(preview)
                } else if cached == nil {
                    imagesByPaneID[leafID] = .failed
                }
            }
        }
    }

    private func cancelActiveCapture() {
        guard let leafID = activeCaptureLeafID else { return }
        activeCaptureLeafID = nil
        client.cancelCapture(leafID)
    }

    private func seedCachedImages(for leafIDs: [UUID]) {
        for leafID in leafIDs where imagesByPaneID[leafID] == nil {
            if let cached = client.cachedPreview(leafID) {
                imagesByPaneID[leafID] = .ready(cached)
            }
        }
    }

    private func pixelBudget() -> PixelBudget {
        let dimensions: (width: UInt32, height: UInt32) = switch previewSizing {
        case .paneMap(let availableWidth, let maximumHeight):
            PanePreviewLayout.paneMapPhysicalPixelBudget(
                availableWidth: availableWidth,
                maximumHeight: maximumHeight,
                scale: displayScale
            )
        case .windowGrid(let availableWidth):
            PanePreviewLayout.windowPhysicalPixelBudget(
                availableWidth: availableWidth,
                scale: displayScale
            )
        }
        return PixelBudget(width: dimensions.width, height: dimensions.height)
    }

    private static func unique(_ leafIDs: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return leafIDs.filter { seen.insert($0).inserted }
    }
}
