import CryptoKit
import Foundation
import XCTest
@testable import Remux

final class HerdrSurfaceDecoderTests: XCTestCase {
    // MARK: - Recorded streams

    /// Every surface message of every recording, in order, expands to the grid the reference decoder
    /// produced (`Fixtures/HerdrWire`, `decoded`).
    func testExpandsEveryRecordedSurfaceMessageAsTheReferenceDecoderDoes() throws {
        var checked = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated else { continue }
            var decoder = HerdrSurfaceDecoder(
                deltaNegotiated: negotiated.delta,
                scrollNegotiated: negotiated.scroll
            )
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)
            for entry in fixture.golden.server {
                let context = "\(fixture.name) @\(entry.offset)"
                let payload = try XCTUnwrap(try splitter.nextPayload(), context)
                guard let message = try Self.surfaceMessage(try HerdrServerMessage.decode(payload)) else {
                    XCTAssertNil(entry.decoded, context)
                    continue
                }
                let expected = try XCTUnwrap(entry.decoded, context)
                switch try decoder.decode(message) {
                case .surface(let surface):
                    XCTAssertEqual(expected.kind, "surface", context)
                    XCTAssertEqual(surface.projectionRevision, expected.projection_revision, context)
                    XCTAssertEqual(surface.surfaceRevision, expected.surface_revision, context)
                    XCTAssertEqual(Self.digest(surface.frame.cells), expected.cells, context)
                    XCTAssertEqual(surface.popup.map { Self.digest($0.frame.cells) }, expected.popup_cells, context)
                case .patch(let patch):
                    XCTAssertEqual(expected.kind, "patch", context)
                    XCTAssertEqual(patch.surfaceRevision, expected.surface_revision, context)
                    XCTAssertEqual(Self.digest(patch.rows), expected.rows, context)
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 71)
    }

    // MARK: - Baseline rules

    func testReuseNeedsABaseline() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        let reuse = HerdrSurfaceReuse(baseSurfaceRevision: 1, surface: try Self.surface(revision: 2, rows: []))
        XCTAssertThrowsError(try decoder.decode(.reuse(reuse))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface reuse without a baseline"))
        }
    }

    func testDeltaAndScrollMustBeNegotiated() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: false, scrollNegotiated: false)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["ab"])))
        let delta = HerdrSurfaceDelta(
            baseProjectionRevision: 1,
            baseSurfaceRevision: 1,
            surface: try Self.surface(revision: 2, rows: [], width: 2, height: 1),
            rows: [],
            popupCells: nil
        )
        XCTAssertThrowsError(try decoder.decode(.delta(delta))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface delta was not negotiated"))
        }
        let scroll = HerdrSurfaceScroll(regions: [], patch: try Self.patch(base: 1, rows: []))
        XCTAssertThrowsError(try decoder.decode(.scroll(scroll))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface scroll was not negotiated"))
        }
    }

    func testAFollowingPatchAdvancesTheBaseline() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["ab"])))
        _ = try decoder.decode(.patch(try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("x"))])))
        let reuse = HerdrSurfaceReuse(baseSurfaceRevision: 2, surface: try Self.surface(revision: 3, rows: [], width: 2, height: 1))
        guard case .surface(let surface) = try decoder.decode(.reuse(reuse)) else { return XCTFail("no surface") }
        XCTAssertEqual(surface.frame.cells.map(\.symbol), ["x", "b"])
    }

    /// A patch that doesn't follow the baseline passes through and drops the baseline, without failing.
    func testAPatchThatDoesNotFollowDropsTheBaseline() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["ab"])))
        let stray = try Self.patch(base: 7, rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("x"))])
        XCTAssertEqual(try decoder.decode(.patch(stray)), .patch(stray))
        let reuse = HerdrSurfaceReuse(baseSurfaceRevision: 1, surface: try Self.surface(revision: 2, rows: [], width: 2, height: 1))
        XCTAssertThrowsError(try decoder.decode(.reuse(reuse))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface reuse without a baseline"))
        }
    }

    // MARK: - Delta

    func testDeltaRejectsOverlappingSpansAndKeepsItsBaseline() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["abc"])))
        let metadata = try Self.surface(revision: 2, rows: [], width: 3, height: 1)
        let overlapping = HerdrSurfaceDelta(
            baseProjectionRevision: 1,
            baseSurfaceRevision: 1,
            surface: metadata,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("xy")), HerdrPatchRow(x: 1, y: 0, cells: Self.cells("z"))],
            popupCells: nil
        )
        XCTAssertThrowsError(try decoder.decode(.delta(overlapping))) { error in
            XCTAssertEqual(
                error as? HerdrWireError,
                .invalidSurfaceUpdate("surface delta spans overlap or are not sorted")
            )
        }
        let valid = HerdrSurfaceDelta(
            baseProjectionRevision: 1,
            baseSurfaceRevision: 1,
            surface: metadata,
            rows: [HerdrPatchRow(x: 2, y: 0, cells: Self.cells("z"))],
            popupCells: nil
        )
        guard case .surface(let surface) = try decoder.decode(.delta(valid)) else { return XCTFail("no surface") }
        XCTAssertEqual(surface.frame.cells.map(\.symbol), ["a", "b", "z"])
    }

    func testDeltaRejectsAnInvalidHyperlinkIndex() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["ab"])))
        let linked = HerdrCell(symbol: "l", fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: 0)
        let delta = HerdrSurfaceDelta(
            baseProjectionRevision: 1,
            baseSurfaceRevision: 1,
            surface: try Self.surface(revision: 2, rows: [], width: 2, height: 1),
            rows: [HerdrPatchRow(x: 0, y: 0, cells: [linked])],
            popupCells: nil
        )
        XCTAssertThrowsError(try decoder.decode(.delta(delta))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface delta has an invalid hyperlink index"))
        }
    }

    // MARK: - Scroll

    /// Region columns 0-1 of a 3×4 grid move up one row, then the patch writes row 3. The expanded
    /// patch carries the part of row 3 outside the region, then every row of the region.
    func testScrollRotatesTheRegionAndExpandsToAnOrdinaryPatch() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["abc", "def", "ghi", "jkl"])))
        let scroll = HerdrSurfaceScroll(
            regions: [.init(rect: HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 4), shift: 1)],
            patch: try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 3, cells: Self.cells("nop"))])
        )
        guard case .patch(let patch) = try decoder.decode(.scroll(scroll)) else { return XCTFail("no patch") }
        XCTAssertEqual(patch.rows.map { "\($0.x),\($0.y):" + $0.cells.map(\.symbol).joined() }, [
            "2,3:p", "0,0:de", "0,1:gh", "0,2:jk", "0,3:no",
        ])
        let reuse = HerdrSurfaceReuse(baseSurfaceRevision: 2, surface: try Self.surface(revision: 3, rows: [], width: 3, height: 4))
        guard case .surface(let surface) = try decoder.decode(.reuse(reuse)) else { return XCTFail("no surface") }
        XCTAssertEqual(surface.frame.cells.map(\.symbol).joined(), "decghfjkinop")
    }

    func testScrollRejectsOverlappingRegions() throws {
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: true, scrollNegotiated: true)
        _ = try decoder.decode(.full(try Self.surface(revision: 1, rows: ["abc", "def", "ghi"])))
        let scroll = HerdrSurfaceScroll(
            regions: [
                .init(rect: HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 3), shift: 1),
                .init(rect: HerdrSurfaceRect(x: 1, y: 0, width: 2, height: 3), shift: 1),
            ],
            patch: try Self.patch(base: 1, rows: [])
        )
        XCTAssertThrowsError(try decoder.decode(.scroll(scroll))) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate("surface scroll exceeds the cell baseline"))
        }
    }
}

// MARK: - Helpers

extension HerdrSurfaceDecoderTests {
    static func surfaceMessage(_ message: HerdrServerMessage) throws -> HerdrSurfaceDecoder.Message? {
        switch message {
        case .paneSurface(let surface):
            return .full(surface)
        case .paneSurfacePatch(let patch):
            return .patch(patch)
        case .control(let kind, let data):
            switch try HerdrEndpointControl.parse(kind: kind, data: data) {
            case .surfaceReuse(let reuse): return .reuse(reuse)
            case .surfaceDelta(let delta): return .delta(delta)
            case .surfaceScroll(let scroll): return .scroll(scroll)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The digest the golden generator computes: per cell its symbol, 0x1F,
    /// "fg,bg,modifier,skip,hyperlink" (-1 for none), 0x1E.
    static func digest(_ cells: [HerdrCell]) -> String {
        var hasher = SHA256()
        update(&hasher, cells)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Per row "x,y:", its cells as above, then 0x1D.
    static func digest(_ rows: [HerdrPatchRow]) -> String {
        var hasher = SHA256()
        for row in rows {
            hasher.update(data: Data("\(row.x),\(row.y):".utf8))
            update(&hasher, row.cells)
            hasher.update(data: Data([0x1D]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, _ cells: [HerdrCell]) {
        for cell in cells {
            hasher.update(data: Data(cell.symbol.utf8))
            hasher.update(data: Data([0x1F]))
            let fields = "\(cell.fg.raw),\(cell.bg.raw),\(cell.modifier),\(cell.skip ? 1 : 0),\(cell.hyperlink.map(Int64.init) ?? -1)"
            hasher.update(data: Data(fields.utf8))
            hasher.update(data: Data([0x1E]))
        }
    }

    static func cells(_ symbols: String) -> [HerdrCell] {
        symbols.map {
            HerdrCell(symbol: String($0), fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: nil)
        }
    }

    /// A surface whose rows of single-character cells come from `rows`; with no rows, an empty cell list
    /// of the given size (reuse and delta metadata).
    static func surface(revision: UInt64, rows: [String], width: Int? = nil, height: Int? = nil) throws -> HerdrPaneSurfaceFrame {
        let cells = rows.flatMap { row in row.map { #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"# } }
        let json = """
        {"boot_id":"boot","projection_revision":1,"surface_revision":\(revision),
         "frame":{"cells":[\(cells.joined(separator: ","))],"width":\(width ?? rows.first?.count ?? 0),
                  "height":\(height ?? rows.count),"cursor":null,"hyperlinks":[],"graphics":[]},
         "panes":[],"splits":[],"popup":null,
         "graphics":{"assets":[],"placements":[],"retained_assets":[]}}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    static func patch(base: UInt64, rows: [HerdrPatchRow]) throws -> HerdrPaneSurfacePatch {
        let json = """
        {"boot_id":"boot","projection_revision":1,"base_surface_revision":\(base),
         "surface_revision":\(base + 1),"rows":[],"panes":[],"cursor":null}
        """
        var patch = try JSONDecoder().decode(HerdrPaneSurfacePatch.self, from: Data(json.utf8))
        patch.rows = rows
        return patch
    }
}
