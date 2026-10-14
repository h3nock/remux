import CryptoKit
import Foundation
import XCTest
@testable import Remux

final class HerdrPanePainterTests: XCTestCase {
    // MARK: - Recorded streams

    /// Every pane of every recorded surface and applied patch paints as the reference painter does
    /// (`Fixtures/HerdrWire`, `painted`): whole on its first paint, then only the rows that changed
    /// since the pane's last paint, byte for byte.
    func testPaintsEveryRecordedPaneAsTheReferencePainter() throws {
        var full = 0
        var partial = 0
        var unchanged = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated else { continue }
            var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
            var presentation = HerdrPresentation()
            var lastPainted: [String: HerdrPanePainter.Painted] = [:]
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)

            func check(_ surface: HerdrPaneSurfaceFrame, against expected: [String: HerdrWireTests.GoldenPainted], _ context: String) {
                XCTAssertEqual(Set(expected.keys), Set(surface.panes.map(\.paneID)), context)
                for pane in surface.panes {
                    let next = HerdrPanePainter.Painted(
                        frame: surface.frame,
                        area: pane.innerRect,
                        cursor: HerdrPanePainter.paneCursor(of: surface)
                    )
                    let rows = lastPainted[pane.paneID].flatMap { HerdrPanePainter.changedRows(from: $0, to: next) }
                    lastPainted[pane.paneID] = next
                    let paneContext = "\(context) \(pane.paneID)"
                    XCTAssertEqual(rows, expected[pane.paneID]?.rows, paneContext)
                    if rows == [] {
                        XCTAssertNil(expected[pane.paneID]?.digest, paneContext)
                        unchanged += 1
                        continue
                    }
                    let bytes = HerdrPanePainter.rows(rows ?? Array(0..<Int(pane.innerRect.height)), of: surface.frame, area: pane.innerRect)
                    XCTAssertEqual(Self.digest(bytes), expected[pane.paneID]?.digest, paneContext)
                    if rows == nil { full += 1 } else { partial += 1 }
                }
            }

            for entry in fixture.golden.server {
                let context = "\(fixture.name) @\(entry.offset)"
                let message = try HerdrServerMessage.decode(try XCTUnwrap(try splitter.nextPayload(), context))
                if case .control(let kind, let data) = message,
                   case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                    presentation.receive(snapshot)
                }
                guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
                switch try decoder.decode(surfaceMessage) {
                case .surface(let surface):
                    try presentation.receive(surface)
                    check(surface, against: try XCTUnwrap(entry.painted, context), context)
                case .patch(let patch):
                    guard presentation.receive(patch) == .applied else {
                        XCTAssertNil(entry.painted, context)
                        continue
                    }
                    check(try XCTUnwrap(presentation.surface, context), against: try XCTUnwrap(entry.painted, context), context)
                }
            }
        }
        XCTAssertEqual(full, 22)
        XCTAssertEqual(partial, 66)
        XCTAssertEqual(unchanged, 55)
    }

    // MARK: - Cells

    func testRowsArePaintedRightToLeftWithEachCellAtItsColumn() {
        let frame = Self.frame(width: 5, rows: [["a", "漢", "", "b", "c"]])
        let area = HerdrSurfaceRect(x: 1, y: 0, width: 3, height: 1)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: area)),
            "\u{1B}[1;3H\u{1B}[0;39;49mb\u{1B}[1;1H\u{1B}[0;39;49m漢\u{1B}[0m"
        )
    }

    /// The first two expectations are Herdr's own render tests; the rest follow its SGR mapping.
    func testCellStylesUseHerdrsSGR() {
        func sgr(fg: UInt32, bg: UInt32, modifier: UInt16) -> String {
            let cell = HerdrCell(symbol: "x", fg: HerdrColor(raw: fg), bg: HerdrColor(raw: bg), modifier: modifier, skip: false, hyperlink: nil)
            let frame = HerdrFrame(cells: [cell], width: 1, height: 1, cursor: nil, hyperlinks: [], graphics: [])
            let text = Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 1, height: 1)))
            return String(text.dropFirst("\u{1B}[1;1H".count).dropLast("x\u{1B}[0m".count))
        }

        XCTAssertEqual(sgr(fg: 0, bg: 0, modifier: 0), "\u{1B}[0;39;49m")
        XCTAssertEqual(sgr(fg: 0, bg: 0, modifier: 8 | 3 << 12), "\u{1B}[0;4:3;39;49m")
        XCTAssertEqual(sgr(fg: 2, bg: 1, modifier: 1), "\u{1B}[0;1;31;40m")
        XCTAssertEqual(sgr(fg: 9, bg: 16, modifier: 2 | 4 | 8), "\u{1B}[0;2;3;4;90;107m")
        XCTAssertEqual(sgr(fg: 0x0100_00C4, bg: 0x0200_0102, modifier: 16 | 32 | 64 | 128 | 256), "\u{1B}[0;5;6;7;8;9;38;5;196;48;2;0;1;2m")
        XCTAssertEqual(sgr(fg: 0xFF00_0000, bg: 17, modifier: 8 | 7 << 12), "\u{1B}[0;4;39;49m")
    }

    /// Control characters are dropped from a link and an empty result is no link, as in Herdr's
    /// client; every cell of a link opens it with the same id (the reference's FNV-1a of the URI).
    func testLinksCarryAnIDFromTheirURIWithoutControlCharacters() {
        var frame = Self.frame(width: 3, rows: [["a", "b", "c"]], hyperlinks: ["https://e.com/\u{1B}x\u{07}y\u{85}", "\u{1B}\u{07}"])
        frame.cells[0] = Self.cell("a", hyperlink: 0)
        frame.cells[1] = Self.cell("b", hyperlink: 1)
        frame.cells[2] = Self.cell("c", hyperlink: 7)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 3, height: 1))),
            "\u{1B}[1;3H\u{1B}[0;39;49mc"
                + "\u{1B}[1;2H\u{1B}[0;39;49mb"
                + "\u{1B}[1;1H\u{1B}[0;39;49m\u{1B}]8;id=d718a06433e710f0;https://e.com/xy\u{1B}\\a\u{1B}]8;;\u{1B}\\"
                + "\u{1B}[0m"
        )
    }

    /// Herdr's client never writes a cell marked skip.
    func testSkippedCellsAreNotWritten() {
        var frame = Self.frame(width: 2, rows: [["a", "b"]])
        frame.cells[1] = HerdrCell(symbol: "b", fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: true, hyperlink: nil)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 1))),
            "\u{1B}[1;1H\u{1B}[0;39;49ma\u{1B}[0m"
        )
    }

    // MARK: - Cursor

    /// The area holding the cursor places it, then shows or hides it, as Herdr's client writes it;
    /// another area just hides its own.
    func testTheCursorIsPlacedOnlyInTheAreaThatHoldsIt() {
        let holding = HerdrSurfaceRect(x: 4, y: 1, width: 3, height: 2)
        let beside = HerdrSurfaceRect(x: 0, y: 1, width: 4, height: 2)
        let shown = HerdrCursor(x: 5, y: 2, visible: true, shape: 6)
        let hidden = HerdrCursor(x: 5, y: 2, visible: false, shape: 6)

        XCTAssertEqual(HerdrPanePainter.cursor(shown, in: holding), HerdrCursor(x: 1, y: 1, visible: true, shape: 6))
        XCTAssertNil(HerdrPanePainter.cursor(shown, in: beside))
        XCTAssertNil(HerdrPanePainter.cursor(nil, in: holding))
        XCTAssertEqual(Self.text(HerdrPanePainter.cursorBytes(HerdrPanePainter.cursor(shown, in: holding))), "\u{1B}[2;2H\u{1B}[6 q\u{1B}[?25h")
        XCTAssertEqual(Self.text(HerdrPanePainter.cursorBytes(HerdrPanePainter.cursor(hidden, in: holding))), "\u{1B}[2;2H\u{1B}[?25l")
        XCTAssertEqual(Self.text(HerdrPanePainter.cursorBytes(nil)), "\u{1B}[?25l")
    }

    /// With a popup open the popup has the only cursor, as Herdr's client composes them.
    func testPanesShowNoCursorWhileAPopupIsOpen() throws {
        let popup = #""popup":{"terminal_id":"t","title":"p","width":null,"height":null,"frame":{"cells":[],"width":0,"height":0,"cursor":{"x":0,"y":0,"visible":true,"shape":0},"hyperlinks":[],"graphics":[]},"mouse_reporting":false,"sgr_pixel_mouse":false,"pixel_width":0,"pixel_height":0}"#
        var withPopup = try HerdrPresentationTests.surface(projection: 1, revision: 1, extra: popup)
        var without = try HerdrPresentationTests.surface(projection: 1, revision: 1)
        withPopup.frame.cursor = HerdrCursor(x: 1, y: 0, visible: true, shape: 0)
        without.frame.cursor = HerdrCursor(x: 1, y: 0, visible: true, shape: 0)
        XCTAssertNil(HerdrPanePainter.paneCursor(of: withPopup))
        XCTAssertEqual(HerdrPanePainter.paneCursor(of: without), HerdrCursor(x: 1, y: 0, visible: true, shape: 0))
    }

    // MARK: - Repaint and update

    func testARepaintSetsTheModesPaintsEveryRowAndEndsWithTheCursor() {
        let frame = Self.frame(width: 4, rows: [["a", "b", "c", "d"], ["e", "f", "g", "h"]])
        let area = HerdrSurfaceRect(x: 2, y: 0, width: 2, height: 2)
        let painted = HerdrPanePainter.Painted(frame: frame, area: area, cursor: HerdrCursor(x: 2, y: 1, visible: true, shape: 2))

        XCTAssertEqual(
            Self.text(HerdrPanePainter.repaint(painted)),
            "\u{1B}[?2027h\u{1B}[?7l"
                + Self.text(HerdrPanePainter.rows([0, 1], of: frame, area: area))
                + "\u{1B}[2;1H\u{1B}[2 q\u{1B}[?25h"
        )
    }

    /// An update paints the rows that look different, then the cursor; only the cursor when that alone
    /// moved; nothing when nothing changed.
    func testAnUpdatePaintsOnlyWhatChanged() {
        let area = HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 2)
        let cursor = HerdrCursor(x: 1, y: 0, visible: true, shape: 0)
        let before = HerdrPanePainter.Painted(frame: Self.frame(width: 2, rows: [["a", "b"], ["c", "d"]]), area: area, cursor: cursor)
        let typed = HerdrPanePainter.Painted(frame: Self.frame(width: 2, rows: [["a", "b"], ["c", "x"]]), area: area, cursor: cursor)
        let moved = HerdrPanePainter.Painted(frame: before.frame, area: area, cursor: HerdrCursor(x: 0, y: 1, visible: true, shape: 0))

        XCTAssertEqual(HerdrPanePainter.changedRows(from: before, to: typed), [1])
        XCTAssertEqual(
            HerdrPanePainter.update(from: before, to: typed),
            HerdrPanePainter.rows([1], of: typed.frame, area: area) + HerdrPanePainter.cursorBytes(HerdrCursor(x: 1, y: 0, visible: true, shape: 0))
        )
        XCTAssertEqual(Self.text(HerdrPanePainter.update(from: before, to: moved)), "\u{1B}[2;1H\u{1B}[0 q\u{1B}[?25h")
        XCTAssertEqual(HerdrPanePainter.update(from: before, to: before), [])
    }

    /// Rows are compared as Herdr's client compares cells: a different link counts, `skip` doesn't; and
    /// the areas are compared at their own origins.
    func testRowsAreComparedAsHerdrComparesCells() {
        let area = HerdrSurfaceRect(x: 0, y: 0, width: 1, height: 1)
        let plain = HerdrPanePainter.Painted(frame: Self.frame(width: 1, rows: [["a"]], hyperlinks: ["https://a"]), area: area, cursor: nil)
        var linked = plain.frame
        linked.cells[0] = Self.cell("a", hyperlink: 0)
        var skipped = plain.frame
        skipped.cells[0] = HerdrCell(symbol: "a", fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: true, hyperlink: nil)
        let moved = HerdrPanePainter.Painted(frame: Self.frame(width: 2, rows: [["z", "a"]]), area: HerdrSurfaceRect(x: 1, y: 0, width: 1, height: 1), cursor: nil)

        XCTAssertEqual(HerdrPanePainter.changedRows(from: plain, to: HerdrPanePainter.Painted(frame: linked, area: area, cursor: nil)), [0])
        XCTAssertEqual(HerdrPanePainter.changedRows(from: plain, to: HerdrPanePainter.Painted(frame: skipped, area: area, cursor: nil)), [])
        XCTAssertEqual(HerdrPanePainter.changedRows(from: plain, to: moved), [])
    }
}

// MARK: - Helpers

extension HerdrPanePainterTests {
    static func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func cell(_ symbol: String, hyperlink: UInt32? = nil) -> HerdrCell {
        HerdrCell(symbol: symbol, fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: hyperlink)
    }

    static func frame(width: UInt16, rows: [[String]], hyperlinks: [String] = []) -> HerdrFrame {
        HerdrFrame(
            cells: rows.flatMap { $0.map { cell($0) } },
            width: width,
            height: UInt16(rows.count),
            cursor: nil,
            hyperlinks: hyperlinks,
            graphics: []
        )
    }
}
