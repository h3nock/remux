import Foundation

/// The connection's surface decoder, with the reuse, delta and scroll rules of Herdr's own client
/// decoder.
///
/// Every surface message on a connection passes through it, in order and before presentation drops
/// anything, so its baseline stays in step with the server's. It expands reuse and delta messages into
/// full surfaces and scroll messages into ordinary patches. Any error ends the attachment, as in Herdr's
/// own client.
struct HerdrSurfaceDecoder {
    enum Message: Sendable {
        case full(HerdrPaneSurfaceFrame)
        case patch(HerdrPaneSurfacePatch)
        case reuse(HerdrSurfaceReuse)
        case delta(HerdrSurfaceDelta)
        case scroll(HerdrSurfaceScroll)
    }

    enum Output: Equatable, Sendable {
        case surface(HerdrPaneSurfaceFrame)
        case patch(HerdrPaneSurfacePatch)
    }

    // Herdr's decoder limits.
    private static let maxSpans = 4096
    private static let maxGridDimension: UInt16 = 4096
    private static let maxGridCells = 1_000_000

    private struct PopupBaseline {
        let terminalID: String
        let width: UInt16
        let height: UInt16
        let cells: [HerdrCell]

        init?(_ surface: HerdrPaneSurfaceFrame) {
            guard let popup = surface.popup else { return nil }
            terminalID = popup.terminalID
            width = popup.frame.width
            height = popup.frame.height
            cells = popup.frame.cells
        }
    }

    private struct Baseline {
        var bootID: String
        var projectionRevision: UInt64
        var surfaceRevision: UInt64
        var width: UInt16
        var height: UInt16
        var cells: [HerdrCell]
        var popup: PopupBaseline?

        /// Whether a patch applies to exactly this baseline as its next revision.
        func matches(_ patch: HerdrPaneSurfacePatch) -> Bool {
            patch.bootID == bootID
                && patch.projectionRevision == projectionRevision
                && patch.baseSurfaceRevision == surfaceRevision
                && patch.surfaceRevision == HerdrSurfaceDecoder.next(surfaceRevision)
        }
    }

    private let deltaNegotiated: Bool
    private let scrollNegotiated: Bool
    private var baseline: Baseline?

    init(deltaNegotiated: Bool, scrollNegotiated: Bool) {
        self.deltaNegotiated = deltaNegotiated
        self.scrollNegotiated = scrollNegotiated
    }

    mutating func decode(_ message: Message) throws -> Output {
        switch message {
        case .full(let surface):
            baseline = Baseline(
                bootID: surface.bootID,
                projectionRevision: surface.projectionRevision,
                surfaceRevision: surface.surfaceRevision,
                width: surface.frame.width,
                height: surface.frame.height,
                cells: surface.frame.cells,
                popup: deltaNegotiated ? PopupBaseline(surface) : nil
            )
            return .surface(surface)
        case .patch(let patch):
            try applyPatch(patch)
            return .patch(patch)
        case .reuse(let reuse):
            return .surface(try applyReuse(reuse))
        case .delta(let delta):
            guard deltaNegotiated else { throw Self.invalid("surface delta was not negotiated") }
            return .surface(try applyDelta(delta))
        case .scroll(let scroll):
            guard scrollNegotiated else { throw Self.invalid("surface scroll was not negotiated") }
            return .patch(try applyScroll(scroll))
        }
    }

    /// A patch that doesn't follow the baseline drops it rather than failing, as in Herdr's decoder:
    /// only presentation decides whether to show it, and the next full surface restores a baseline.
    private mutating func applyPatch(_ patch: HerdrPaneSurfacePatch) throws {
        guard var base = baseline else { return }
        guard base.matches(patch) else {
            baseline = nil
            return
        }
        for row in patch.rows {
            let start = Int(row.y) * Int(base.width) + Int(row.x)
            guard row.y < base.height,
                  Int(row.x) + row.cells.count <= Int(base.width),
                  start + row.cells.count <= base.cells.count
            else {
                throw Self.invalid("surface patch exceeds the cell baseline")
            }
            base.cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
        }
        base.surfaceRevision = patch.surfaceRevision
        baseline = base
    }

    private mutating func applyReuse(_ reuse: HerdrSurfaceReuse) throws -> HerdrPaneSurfaceFrame {
        guard var base = baseline else { throw Self.invalid("surface reuse without a baseline") }
        var surface = reuse.surface
        guard base.bootID == surface.bootID,
              base.surfaceRevision == reuse.baseSurfaceRevision,
              surface.surfaceRevision == Self.next(base.surfaceRevision),
              base.width == surface.frame.width,
              base.height == surface.frame.height,
              surface.frame.cells.isEmpty
        else {
            throw Self.invalid("surface reuse does not match its baseline")
        }
        surface.frame.cells = base.cells
        base.projectionRevision = surface.projectionRevision
        base.surfaceRevision = surface.surfaceRevision
        if deltaNegotiated {
            base.popup = PopupBaseline(surface)
        }
        baseline = base
        return surface
    }

    private mutating func applyDelta(_ delta: HerdrSurfaceDelta) throws -> HerdrPaneSurfaceFrame {
        guard var base = baseline else { throw Self.invalid("surface delta without a baseline") }
        var surface = delta.surface
        guard surface.frame.width == base.width, surface.frame.height == base.height else {
            throw Self.invalid("surface dimensions do not match the baseline")
        }
        try Self.validate(delta.rows, width: base.width, height: base.height)
        guard surface.bootID == base.bootID,
              delta.baseProjectionRevision == base.projectionRevision,
              delta.baseSurfaceRevision == base.surfaceRevision,
              surface.surfaceRevision == Self.next(base.surfaceRevision),
              surface.projectionRevision >= base.projectionRevision,
              base.cells.count == Int(base.width) * Int(base.height)
        else {
            throw Self.invalid("surface delta does not match its baseline")
        }
        var cells = base.cells
        Self.apply(delta.rows, to: &cells, width: base.width)
        surface.frame.cells = cells

        switch (surface.popup, delta.popupCells) {
        case (nil, nil):
            break
        case (var popup?, let update?):
            switch update {
            case .replace(let replacement):
                guard replacement.count == (try Self.gridSize(popup.frame.width, popup.frame.height)) else {
                    throw Self.invalid("popup replacement does not match popup dimensions")
                }
                popup.frame.cells = replacement
            case .patch(let rows):
                try Self.validate(rows, width: popup.frame.width, height: popup.frame.height)
                guard let previous = base.popup,
                      previous.terminalID == popup.terminalID,
                      previous.width == popup.frame.width,
                      previous.height == popup.frame.height,
                      previous.cells.count == Int(previous.width) * Int(previous.height)
                else {
                    throw Self.invalid("popup delta does not match its baseline")
                }
                var popupCells = previous.cells
                Self.apply(rows, to: &popupCells, width: previous.width)
                popup.frame.cells = popupCells
            }
            surface.popup = popup
        default:
            throw Self.invalid("popup delta is missing or unexpected")
        }

        for frame in [surface.frame] + (surface.popup.map { [$0.frame] } ?? []) {
            let linkCount = frame.hyperlinks.count
            if frame.cells.contains(where: { cell in cell.hyperlink.map { Int($0) >= linkCount } ?? false }) {
                throw Self.invalid("surface delta has an invalid hyperlink index")
            }
        }

        // The whole update is validated before the baseline moves.
        base.cells = cells
        base.popup = PopupBaseline(surface)
        base.projectionRevision = surface.projectionRevision
        base.surfaceRevision = surface.surfaceRevision
        baseline = base
        return surface
    }

    /// Applies the scrolled regions and the patch to the baseline and returns the ordinary patch a
    /// client without scroll support would have received: the patch rows outside every region, then
    /// every row of each region with its final cells.
    private mutating func applyScroll(_ scroll: HerdrSurfaceScroll) throws -> HerdrPaneSurfacePatch {
        guard var base = baseline else { throw Self.invalid("surface scroll without a baseline") }
        guard base.matches(scroll.patch) else {
            throw Self.invalid("surface scroll does not match its baseline")
        }
        let width = base.width
        let height = base.height
        guard base.cells.count == Int(width) * Int(height) else {
            throw Self.invalid("surface scroll baseline has an invalid grid")
        }
        let regions = scroll.regions
        guard regions.allSatisfy({ Self.fits($0, width: width, height: height) }),
              Self.disjoint(regions),
              scroll.patch.rows.allSatisfy({
                  $0.y < height && Int($0.x) + $0.cells.count <= Int(width)
              })
        else {
            throw Self.invalid("surface scroll exceeds the cell baseline")
        }

        var cells = base.cells
        for region in regions {
            Self.rotate(region, in: &cells, width: width)
        }
        Self.apply(scroll.patch.rows, to: &cells, width: width)

        var rows = scroll.patch.rows.flatMap { Self.outside(regions, row: $0) }
        for region in regions {
            let rect = region.rect
            for y in rect.y..<(rect.y + rect.height) {
                let start = Int(y) * Int(width) + Int(rect.x)
                rows.append(HerdrPatchRow(
                    x: rect.x,
                    y: y,
                    cells: Array(cells[start..<(start + Int(rect.width))])
                ))
            }
        }
        var patch = scroll.patch
        patch.rows = rows
        base.cells = cells
        base.surfaceRevision = patch.surfaceRevision
        baseline = base
        return patch
    }

    // MARK: - Shared rules

    private static func invalid(_ reason: String) -> HerdrWireError {
        .invalidSurfaceUpdate(reason)
    }

    /// Herdr's `saturating_add(1)`.
    private static func next(_ revision: UInt64) -> UInt64 {
        revision == .max ? .max : revision + 1
    }

    private static func gridSize(_ width: UInt16, _ height: UInt16) throws -> Int {
        guard width <= maxGridDimension, height <= maxGridDimension else {
            throw invalid("surface dimensions exceed the limit")
        }
        let cells = Int(width) * Int(height)
        guard cells <= maxGridCells else { throw invalid("surface cell count exceeds the limit") }
        return cells
    }

    /// Delta spans: non-empty, inside their row, sorted, non-overlapping, and within the cell budget.
    private static func validate(_ rows: [HerdrPatchRow], width: UInt16, height: UInt16) throws {
        let budget = try gridSize(width, height)
        guard rows.count <= min(maxSpans, budget) else { throw invalid("too many surface delta spans") }
        let rowWidth = Int(width)
        var previousEnd = 0
        var total = 0
        for row in rows {
            let x = Int(row.x)
            let count = row.cells.count
            guard count > 0, row.y < height, x < rowWidth, count <= rowWidth - x else {
                throw invalid("surface delta span is outside its row")
            }
            let start = Int(row.y) * rowWidth + x
            guard start >= previousEnd else { throw invalid("surface delta spans overlap or are not sorted") }
            total += count
            guard total <= budget else { throw invalid("surface delta cell budget exceeded") }
            previousEnd = start + count
        }
    }

    private static func apply(_ rows: [HerdrPatchRow], to cells: inout [HerdrCell], width: UInt16) {
        for row in rows {
            let start = Int(row.y) * Int(width) + Int(row.x)
            cells.replaceSubrange(start..<(start + row.cells.count), with: row.cells)
        }
    }

    private static func fits(_ region: HerdrSurfaceScroll.Region, width: UInt16, height: UInt16) -> Bool {
        let rect = region.rect
        return rect.width > 0
            && rect.height >= 2
            && region.shift != 0
            && region.shift.magnitude < rect.height
            && Int(rect.x) + Int(rect.width) <= Int(width)
            && Int(rect.y) + Int(rect.height) <= Int(height)
    }

    private static func disjoint(_ regions: [HerdrSurfaceScroll.Region]) -> Bool {
        for (index, region) in regions.enumerated() {
            for other in regions[(index + 1)...] {
                let a = region.rect
                let b = other.rect
                if a.x < b.x + b.width, b.x < a.x + a.width, a.y < b.y + b.height, b.y < a.y + a.height {
                    return false
                }
            }
        }
        return true
    }

    /// A positive shift moves content up: row `y` shows the previous row `y + shift`. Rows that leave
    /// the region rotate into the vacated rows, by the same swaps the server makes.
    private static func rotate(_ region: HerdrSurfaceScroll.Region, in cells: inout [HerdrCell], width: UInt16) {
        let rect = region.rect
        let height = Int(rect.height)
        let distance = Int(region.shift.magnitude)
        func swapRows(_ a: Int, _ b: Int) {
            let first = (Int(rect.y) + a) * Int(width) + Int(rect.x)
            let second = (Int(rect.y) + b) * Int(width) + Int(rect.x)
            for x in 0..<Int(rect.width) {
                cells.swapAt(first + x, second + x)
            }
        }
        if region.shift > 0 {
            for y in 0..<(height - distance) {
                swapRows(y, y + distance)
            }
        } else {
            for y in (distance..<height).reversed() {
                swapRows(y, y - distance)
            }
        }
    }

    /// The parts of a patch row outside every scrolled region.
    private static func outside(_ regions: [HerdrSurfaceScroll.Region], row: HerdrPatchRow) -> [HerdrPatchRow] {
        let start = Int(row.x)
        let end = start + row.cells.count
        var covered: [(left: Int, right: Int)] = []
        for region in regions {
            let rect = region.rect
            if row.y >= rect.y, row.y - rect.y < rect.height {
                covered.append((left: Int(rect.x), right: Int(rect.x) + Int(rect.width)))
            }
        }
        guard !covered.isEmpty else { return [row] }
        covered.sort { $0.left != $1.left ? $0.left < $1.left : $0.right < $1.right }
        var spans = [HerdrPatchRow]()
        var cursor = start
        for (left, right) in covered + [(end, end)] {
            let spanEnd = min(max(left, cursor), end)
            if spanEnd > cursor {
                spans.append(HerdrPatchRow(
                    x: UInt16(cursor),
                    y: row.y,
                    cells: Array(row.cells[(cursor - start)..<(spanEnd - start)])
                ))
            }
            cursor = max(cursor, min(right, end))
        }
        return spans
    }
}
