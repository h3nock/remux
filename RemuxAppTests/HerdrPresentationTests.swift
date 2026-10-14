import Foundation
import XCTest
@testable import Remux

final class HerdrPresentationTests: XCTestCase {
    // MARK: - Recorded streams

    /// Each recording, through the decoder and the presentation, ends on the reference's committed
    /// surface with no rejected patch.
    func testRecordedStreamsEndOnTheReferenceSurfaceWithNoRejectedPatch() throws {
        var checked = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated, let expected = fixture.golden.final else { continue }
            var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
            var presentation = HerdrPresentation()
            var rejected = 0
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)
            while let payload = try splitter.nextPayload() {
                let message = try HerdrServerMessage.decode(payload)
                if case .control(let kind, let data) = message,
                   case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                    presentation.receive(snapshot)
                    continue
                }
                guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
                switch try decoder.decode(surfaceMessage) {
                case .surface(let surface):
                    try presentation.receive(surface)
                case .patch(let patch):
                    if presentation.receive(patch) == .rejected { rejected += 1 }
                }
            }
            XCTAssertEqual(rejected, expected.rejected_patches, fixture.name)
            XCTAssertEqual(presentation.surface?.surfaceRevision, expected.surface_revision, fixture.name)
            XCTAssertEqual(presentation.surface.map { HerdrSurfaceDecoderTests.digest($0.frame.cells) }, expected.cells, fixture.name)
            if expected.surface_revision != nil {
                XCTAssertNotNil(presentation.presented, fixture.name)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 22)
    }

    // MARK: - Ordering

    func testNoSurfaceIsAcceptedBeforeASnapshot() throws {
        var presentation = HerdrPresentation()
        try presentation.receive(try Self.surface(projection: 1, revision: 1))
        XCTAssertNil(presentation.surface)
    }

    func testDrawsOnlyASurfaceRenderedAgainstTheCurrentSnapshot() throws {
        var presentation = HerdrPresentation()
        presentation.receive(try Self.snapshot(revision: 1))
        try presentation.receive(try Self.surface(projection: 1, revision: 1))
        XCTAssertEqual(presentation.presented?.surface.surfaceRevision, 1)
    }

    /// The next revision's surface waits for its snapshot; nothing new is drawn meanwhile.
    func testASurfaceForTheNextSnapshotWaitsForIt() throws {
        var presentation = HerdrPresentation()
        presentation.receive(try Self.snapshot(revision: 1))
        try presentation.receive(try Self.surface(projection: 1, revision: 1))
        try presentation.receive(try Self.surface(projection: 2, revision: 2))
        XCTAssertNil(presentation.presented)
        XCTAssertEqual(presentation.surface?.surfaceRevision, 1)
        presentation.receive(try Self.snapshot(revision: 2))
        XCTAssertEqual(presentation.presented?.surface.surfaceRevision, 2)
    }

    /// A surface that skips revisions is kept and drawn once its snapshot arrives; a late surface
    /// for an earlier revision doesn't replace it.
    func testASurfaceThatSkipsRevisionsIsKeptAndOlderOnesAreDropped() throws {
        var presentation = HerdrPresentation()
        presentation.receive(try Self.snapshot(revision: 1))
        try presentation.receive(try Self.surface(projection: 3, revision: 5))
        try presentation.receive(try Self.surface(projection: 3, revision: 4))
        XCTAssertNil(presentation.presented)
        presentation.receive(try Self.snapshot(revision: 3))
        XCTAssertEqual(presentation.presented?.surface.surfaceRevision, 5)
    }

    func testAnOlderSnapshotIsIgnored() throws {
        var presentation = HerdrPresentation()
        presentation.receive(try Self.snapshot(revision: 5))
        presentation.receive(try Self.snapshot(revision: 4))
        XCTAssertEqual(presentation.snapshot?.revision, 5)
    }

    /// As Herdr's client: a new boot clears the surfaces of the old one.
    func testANewBootClearsTheSurfaces() throws {
        var presentation = try Self.presenting(try Self.surface(projection: 1, revision: 1))
        try presentation.receive(try Self.surface(projection: 2, revision: 2))
        presentation.receive(try Self.snapshot(revision: 1, boot: "restarted"))
        XCTAssertEqual(presentation.snapshot?.bootID, "restarted")
        XCTAssertNil(presentation.surface)
        XCTAssertNil(presentation.presented)
    }

    // MARK: - Patches

    /// A patch replaces the metadata of the panes it lists; the other pane keeps its mouse flag.
    func testAPatchKeepsTheFlagsOfPanesItDoesNotList() throws {
        var presentation = try Self.presenting(try Self.surface(projection: 1, revision: 1, panes: [
            Self.pane("w1:p1", x: 0, width: 2, mouseReporting: true),
            Self.pane("w1:p2", x: 2, width: 2, mouseReporting: true),
        ]))
        let patch = try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: HerdrSurfaceDecoderTests.cells("x"))], panes: [
            Self.pane("w1:p1", x: 0, width: 2, mouseReporting: false),
        ])
        XCTAssertEqual(presentation.receive(patch), .applied)
        let panes = try XCTUnwrap(presentation.presented?.surface.panes)
        XCTAssertEqual(panes.map(\.mouseReporting), [false, true])
        XCTAssertEqual(presentation.presented?.surface.frame.cells.first?.symbol, "x")
        XCTAssertEqual(presentation.presented?.surface.surfaceRevision, 2)
    }

    func testRejectedPatchesKeepTheFrame() throws {
        let surface = try Self.surface(projection: 1, revision: 1, panes: [Self.pane("w1:p1", x: 0, width: 2, scrollbarX: 2)])
        let x = HerdrSurfaceDecoderTests.cells("x")
        let pane = Self.pane("w1:p1", x: 0, width: 2, scrollbarX: 2)
        let rejected: [(String, HerdrPaneSurfacePatch)] = [
            ("wrong base", try Self.patch(base: 3, rows: [HerdrPatchRow(x: 0, y: 0, cells: x)], panes: [pane])),
            ("unknown pane", try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: x)], panes: [Self.pane("w1:p9", x: 0, width: 2)])),
            ("geometry changed", try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: x)], panes: [Self.pane("w1:p1", x: 0, width: 1)])),
            ("row outside the listed pane", try Self.patch(base: 1, rows: [HerdrPatchRow(x: 3, y: 0, cells: x)], panes: [pane])),
            ("row and no pane listed", try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: x)], panes: [])),
            ("empty row", try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: [])], panes: [pane])),
        ]
        for (name, patch) in rejected {
            var presentation = try Self.presenting(surface)
            XCTAssertEqual(presentation.receive(patch), .rejected, name)
            XCTAssertEqual(presentation.presented?.surface, surface, name)
        }
        var presentation = try Self.presenting(surface)
        let scrollbar = try Self.patch(base: 1, rows: [HerdrPatchRow(x: 2, y: 0, cells: HerdrSurfaceDecoderTests.cells("▐"))], panes: [pane])
        XCTAssertEqual(presentation.receive(scrollbar), .applied)
    }

    func testPatchesAreRejectedWhileAPopupOrImageIsShown() throws {
        for extra in [
            #""popup":{"terminal_id":"t","title":"p","width":null,"height":null,"frame":{"cells":[],"width":0,"height":0,"cursor":null,"hyperlinks":[],"graphics":[]},"mouse_reporting":false,"sgr_pixel_mouse":false,"pixel_width":0,"pixel_height":0}"#,
            #""graphics":{"assets":[],"placements":[\#(Self.placementJSON)],"retained_assets":[]}"#,
        ] {
            var presentation = try Self.presenting(try Self.surface(projection: 1, revision: 1, extra: extra))
            let patch = try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: HerdrSurfaceDecoderTests.cells("x"))], panes: [Self.pane("w1:p1", x: 0, width: 4)])
            XCTAssertEqual(presentation.receive(patch), .rejected)
        }
    }

    // MARK: - Grid checks

    func testAnInconsistentGridEndsTheAttachment() throws {
        var presentation = HerdrPresentation()
        presentation.receive(try Self.snapshot(revision: 1))
        for (surface, reason) in [
            (try Self.surface(projection: 1, revision: 1, cellCount: 3), "surface cells do not match its size"),
            (try Self.surface(projection: 1, revision: 1, panes: [Self.pane("w1:p1", x: 3, width: 2)]), "surface pane lies outside the frame"),
        ] {
            XCTAssertThrowsError(try presentation.receive(surface)) { error in
                XCTAssertEqual(error as? HerdrWireError, .invalidSurfaceUpdate(reason))
            }
        }
    }

    /// As Herdr's client, a link index outside the frame's links is kept: it paints as plain text.
    func testALinkThatDoesNotResolveIsKept() throws {
        var presentation = try Self.presenting(try Self.surface(projection: 1, revision: 1, panes: [Self.pane("w1:p1", x: 0, width: 4)], hyperlink: 0))
        let linked = HerdrCell(symbol: "x", fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: 5)
        let patch = try Self.patch(base: 1, rows: [HerdrPatchRow(x: 0, y: 0, cells: [linked])], panes: [Self.pane("w1:p1", x: 0, width: 4)])
        XCTAssertEqual(presentation.receive(patch), .applied)
        XCTAssertEqual(presentation.presented?.surface.frame.cells.first?.hyperlink, 5)
    }
}

// MARK: - Helpers

extension HerdrPresentationTests {
    static let placementJSON = #"{"asset":{"source":{"PaneLayer":{"pane_id":"w1:p1","layer_id":"l"}},"image_width":1,"image_height":1,"format":"Png","data_len":1,"data_fingerprint":1},"logical_placement_id":1,"x":0,"y":0,"cols":1,"rows":1,"source_x":0,"source_y":0,"source_width":1,"source_height":1,"x_offset":0,"y_offset":0,"z":0,"scrollback_offset":0}"#

    static func presenting(_ surface: HerdrPaneSurfaceFrame) throws -> HerdrPresentation {
        var presentation = HerdrPresentation()
        presentation.receive(try snapshot(revision: surface.projectionRevision))
        try presentation.receive(surface)
        XCTAssertNotNil(presentation.presented)
        return presentation
    }

    static func snapshot(revision: UInt64, boot: String = "boot") throws -> HerdrSnapshot {
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":null,"focused_tab_id":null,
         "focused_pane_id":null,"workspaces":[],"tabs":[],"panes":[],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// A one-row pane `width` cells wide at column `x`, with an optional one-cell scrollbar column.
    static func pane(
        _ id: String,
        x: Int,
        width: Int,
        mouseReporting: Bool = false,
        scrollbarX: Int? = nil
    ) -> String {
        let scrollbar = scrollbarX.map { #"{"x":\#($0),"y":0,"width":1,"height":1}"# } ?? "null"
        return """
        {"pane_id":"\(id)","content_revision":1,"rect":{"x":\(x),"y":0,"width":\(width),"height":1},
         "inner_rect":{"x":\(x),"y":0,"width":\(width),"height":1},"scrollbar_rect":\(scrollbar),"scroll":null,
         "focused":false,"mouse_reporting":\(mouseReporting),"sgr_pixel_mouse":false,
         "alternate_screen_active":false,"pixel_width":0,"pixel_height":0}
        """
    }

    /// A 4×1 surface of cells "abcd".
    static func surface(
        projection: UInt64,
        revision: UInt64,
        panes: [String] = [],
        cellCount: Int = 4,
        hyperlink: Int? = nil,
        extra: String? = nil
    ) throws -> HerdrPaneSurfaceFrame {
        let link = hyperlink.map(String.init) ?? "null"
        let cells = "abcd".prefix(cellCount).map {
            #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":\#(link)}"#
        }
        var fields = [
            #""boot_id":"boot","projection_revision":\#(projection),"surface_revision":\#(revision)"#,
            #""frame":{"cells":[\#(cells.joined(separator: ","))],"width":4,"height":1,"cursor":null,"hyperlinks":[],"graphics":[]}"#,
            #""panes":[\#(panes.joined(separator: ","))]"#,
            #""splits":[]"#,
        ]
        let extraKeys = extra ?? ""
        if !extraKeys.hasPrefix(#""popup""#) { fields.append(#""popup":null"#) }
        if !extraKeys.hasPrefix(#""graphics""#) { fields.append(#""graphics":{"assets":[],"placements":[],"retained_assets":[]}"#) }
        if let extra { fields.append(extra) }
        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    static func patch(base: UInt64, rows: [HerdrPatchRow], panes: [String]) throws -> HerdrPaneSurfacePatch {
        let json = """
        {"boot_id":"boot","projection_revision":1,"base_surface_revision":\(base),
         "surface_revision":\(base + 1),"rows":[],"panes":[\(panes.joined(separator: ","))],"cursor":null}
        """
        var patch = try JSONDecoder().decode(HerdrPaneSurfacePatch.self, from: Data(json.utf8))
        patch.rows = rows
        return patch
    }
}
