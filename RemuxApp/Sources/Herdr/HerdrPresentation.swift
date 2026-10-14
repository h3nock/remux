import Foundation

/// What Remux draws from one Herdr connection: the newest snapshot, and the surface rendered against
/// exactly that snapshot, with the rules of Herdr's client.
///
/// It is fed the surface decoder's output, in wire order. Revisions restart with each connection, so
/// each connection gets a new presentation in place of Herdr's connection-generation checks.
///
/// One deliberate difference: a patch applies to the stored surface even while that surface is ahead of
/// the snapshot. Herdr sends the patched copy back through its pending slot and then rejects every
/// later patch until a full surface; Remux keeps that frame current instead.
struct HerdrPresentation {
    enum PatchOutcome: Equatable, Sendable {
        case applied
        /// The current frame stays until the next full surface.
        case rejected
    }

    private(set) var snapshot: HerdrSnapshot?
    /// The newest accepted surface. It can be ahead of the snapshot; then nothing is drawn until that
    /// snapshot arrives.
    private(set) var surface: HerdrPaneSurfaceFrame?
    /// A surface for the next snapshot revision, kept apart until that snapshot arrives so it can't
    /// replace the drawn pair early.
    private var pending: HerdrPaneSurfaceFrame?

    /// The pair to draw, or nil while the surface and snapshot don't match; the last drawn frame then
    /// stays on screen.
    var presented: (snapshot: HerdrSnapshot, surface: HerdrPaneSurfaceFrame)? {
        guard pending == nil,
              let snapshot,
              let surface,
              surface.projectionRevision == snapshot.revision
        else {
            return nil
        }
        return (snapshot, surface)
    }

    mutating func receive(_ snapshot: HerdrSnapshot) {
        if let current = self.snapshot, current.bootID == snapshot.bootID, snapshot.revision < current.revision {
            return
        }
        // A new server boot clears both surfaces, as Herdr's client does. Herdr disconnects every
        // client before a handoff, so the boot doesn't change within one connection.
        if let current = self.snapshot, current.bootID != snapshot.bootID {
            surface = nil
            pending = nil
        }
        self.snapshot = snapshot
        guard let held = pending else { return }
        pending = nil
        guard held.bootID == snapshot.bootID else { return }
        if held.projectionRevision == snapshot.revision {
            install(held, retainingFuture: false)
        } else if held.projectionRevision > snapshot.revision {
            pending = held
        }
    }

    /// Throws for a grid Remux can't index (see `validate`), which ends the attachment.
    mutating func receive(_ surface: HerdrPaneSurfaceFrame) throws {
        try Self.validate(surface)
        guard let snapshot,
              surface.bootID == snapshot.bootID,
              surface.projectionRevision >= snapshot.revision,
              !isOlderThanCurrent(surface)
        else {
            return
        }
        if surface.projectionRevision == Self.next(snapshot.revision) {
            pending = surface
            return
        }
        // A surface that skips revisions replaces the current one but isn't drawn before its snapshot.
        install(surface, retainingFuture: true)
    }

    /// Applies a patch to the current surface with Herdr's checks. Pane metadata the patch doesn't
    /// list stays as it was.
    mutating func receive(_ patch: HerdrPaneSurfacePatch) -> PatchOutcome {
        guard var next = surface,
              patch.bootID == next.bootID,
              patch.projectionRevision == next.projectionRevision,
              patch.baseSurfaceRevision == next.surfaceRevision,
              patch.surfaceRevision == Self.next(next.surfaceRevision),
              next.popup == nil,
              next.graphics.placements.isEmpty,
              next.graphics.retainedAssets.isEmpty
        else {
            return .rejected
        }
        for updated in patch.panes {
            guard let existing = next.panes.first(where: { $0.paneID == updated.paneID }),
                  existing.rect == updated.rect,
                  existing.innerRect == updated.innerRect,
                  existing.focused == updated.focused,
                  existing.pixelWidth == updated.pixelWidth,
                  existing.pixelHeight == updated.pixelHeight
            else {
                return .rejected
            }
        }
        let width = Int(next.frame.width)
        for row in patch.rows {
            guard !row.cells.isEmpty,
                  row.y < next.frame.height,
                  Int(row.x) + row.cells.count <= width,
                  patch.panes.contains(where: { Self.covers($0, row, existing: next.panes) })
            else {
                return .rejected
            }
        }
        for row in patch.rows {
            let start = Int(row.y) * width + Int(row.x)
            next.frame.cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
        }
        for updated in patch.panes {
            if let index = next.panes.firstIndex(where: { $0.paneID == updated.paneID }) {
                next.panes[index] = updated
            }
        }
        next.frame.cursor = patch.cursor
        next.surfaceRevision = patch.surfaceRevision
        surface = next
        return .applied
    }

    private mutating func install(_ candidate: HerdrPaneSurfaceFrame, retainingFuture: Bool) {
        guard let snapshot,
              candidate.bootID == snapshot.bootID,
              candidate.projectionRevision >= snapshot.revision,
              retainingFuture || candidate.projectionRevision == snapshot.revision,
              !isOlderThanCurrent(candidate)
        else {
            return
        }
        surface = candidate
    }

    private func isOlderThanCurrent(_ candidate: HerdrPaneSurfaceFrame) -> Bool {
        guard let current = surface, current.bootID == candidate.bootID else { return false }
        return candidate.projectionRevision < current.projectionRevision
            || (candidate.projectionRevision == current.projectionRevision
                && candidate.surfaceRevision < current.surfaceRevision)
    }

    /// A patch row lies in a listed pane's text area, or is exactly that pane's scrollbar column (the
    /// previous scrollbar counts when the new metadata drops it).
    private static func covers(
        _ pane: HerdrSurfacePane,
        _ row: HerdrPatchRow,
        existing panes: [HerdrSurfacePane]
    ) -> Bool {
        let inner = pane.innerRect
        let end = Int(row.x) + row.cells.count
        if row.x >= inner.x,
           row.y >= inner.y,
           Int(row.y) < Int(inner.y) + Int(inner.height),
           end <= Int(inner.x) + Int(inner.width) {
            return true
        }
        guard let scrollbar = pane.scrollbarRect
            ?? panes.first(where: { $0.paneID == pane.paneID })?.scrollbarRect
        else {
            return false
        }
        return row.x == scrollbar.x
            && row.y >= scrollbar.y
            && Int(row.y) < Int(scrollbar.y) + Int(scrollbar.height)
            && row.cells.count == Int(scrollbar.width)
    }

    /// Cell counts match the sizes, and each pane's text area lies inside the frame: the patch apply
    /// above and the pane painter index cells by both. Herdr's client checks neither for a full surface
    /// (its decoder does for deltas); Herdr builds them this way, so these only catch a corrupt stream.
    /// Link indexes aren't checked: a link that doesn't resolve paints as plain text, as in Herdr's
    /// renderer.
    private static func validate(_ surface: HerdrPaneSurfaceFrame) throws {
        let frames = [surface.frame] + (surface.popup.map { [$0.frame] } ?? [])
        for frame in frames where frame.cells.count != Int(frame.width) * Int(frame.height) {
            throw HerdrWireError.invalidSurfaceUpdate("surface cells do not match its size")
        }
        for pane in surface.panes {
            let area = pane.innerRect
            guard Int(area.x) + Int(area.width) <= Int(surface.frame.width),
                  Int(area.y) + Int(area.height) <= Int(surface.frame.height)
            else {
                throw HerdrWireError.invalidSurfaceUpdate("surface pane lies outside the frame")
            }
        }
    }

    /// Herdr's `saturating_add(1)`.
    private static func next(_ revision: UInt64) -> UInt64 {
        revision == .max ? .max : revision + 1
    }
}
