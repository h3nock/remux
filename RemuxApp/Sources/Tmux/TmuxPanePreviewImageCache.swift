import CoreGraphics
import Foundation

/// Byte-bounded last-captured pane thumbnails for selector-sheet previews.
/// The cache is a Remux presentation concern; canonical terminal and renderer
/// state remain owned by the tmux session.
struct TmuxPanePreviewImageCache {
    struct Entry {
        let preview: GhosttyPanePreviewSession.RenderedPreview
        let byteCost: Int
        var lastAccess: UInt64
    }

    let byteLimit: Int
    private(set) var entries: [TmuxPaneID: Entry] = [:]
    private(set) var totalByteCost = 0
    private var accessSequence: UInt64 = 0

    init(byteLimit: Int) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    mutating func preview(for paneID: TmuxPaneID) -> GhosttyPanePreviewSession.RenderedPreview? {
        guard var entry = entries[paneID] else { return nil }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[paneID] = entry
        return entry.preview
    }

    @discardableResult
    mutating func store(
        _ preview: GhosttyPanePreviewSession.RenderedPreview,
        for paneID: TmuxPaneID
    ) -> [TmuxPaneID] {
        let image = preview.image
        let (byteCost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, byteCost > 0, byteCost <= byteLimit else { return [] }

        if let replaced = entries.removeValue(forKey: paneID) {
            totalByteCost -= replaced.byteCost
        }
        accessSequence &+= 1
        entries[paneID] = Entry(
            preview: preview,
            byteCost: byteCost,
            lastAccess: accessSequence
        )
        totalByteCost += byteCost

        var evictedPaneIDs: [TmuxPaneID] = []
        while totalByteCost > byteLimit,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries.removeValue(forKey: oldest.key)
            totalByteCost -= oldest.value.byteCost
            evictedPaneIDs.append(oldest.key)
        }
        return evictedPaneIDs
    }

    @discardableResult
    mutating func retainOnly(_ paneIDs: Set<TmuxPaneID>) -> [TmuxPaneID] {
        let removedPaneIDs = entries.keys.filter { !paneIDs.contains($0) }
        for paneID in removedPaneIDs {
            if let removed = entries.removeValue(forKey: paneID) {
                totalByteCost -= removed.byteCost
            }
        }
        return removedPaneIDs
    }

    mutating func remove(_ paneID: TmuxPaneID) {
        guard let removed = entries.removeValue(forKey: paneID) else { return }
        totalByteCost -= removed.byteCost
    }

    mutating func removeAll() {
        entries.removeAll()
        totalByteCost = 0
        accessSequence = 0
    }
}
