import Foundation
import XCTest
@testable import Remux

@MainActor
final class HerdrFindTests: XCTestCase {
    func testReplyRejectsWrongIdentityRevisionIndicesAndCellBounds() throws {
        let request = HerdrFindRequest(pane_id: "P", query: "x", direction: "forward",
                                      cursor: .init(row: 0, col: 0), content_revision: 2, previous: nil)
        let valid: [String: Any] = [
            "type": "pane_copy_search", "pane_id": "P", "content_revision": 2,
            "matches": [["start": ["row": 20, "col": 0], "end": ["row": 20, "col": 2]]],
            "total": 4000, "current": 0, "current_global": 2048
        ]
        func decode(_ value: [String: Any]) throws -> HerdrFindResult {
            try .decode(JSONSerialization.data(withJSONObject: ["result": value]), request: request, columns: 4)
        }
        XCTAssertEqual(try decode(valid).windowStart, 2048)
        for patch: [String: Any] in [
            ["pane_id": "other"], ["content_revision": 4], ["current": 1],
            ["current_global": 4000], ["total": 0],
            ["matches": [["start": ["row": 20, "col": 0], "end": ["row": 20, "col": 4]]]]
        ] {
            XCTAssertThrowsError(try decode(valid.merging(patch) { _, new in new }), "accepted \(patch)")
        }
    }

    func testGlobalOrdinalsUseTheReturnedWindowBaseAndBoundaryUsesCanonicalSearch() {
        let ranges = [range(100), range(101)]
        var find = HerdrFindState(paneID: "P", bootID: "boot", generation: 1)
        find.query = "x"
        find.result = HerdrFindResult(type: "pane_copy_search", pane_id: "P", content_revision: 2,
                                     matches: ranges, total: 4000, current: 1, current_global: 2049)
        find.desiredIndex = 2048
        find.showResult()
        XCTAssertEqual(find.selectedRange, ranges[0])
        XCTAssertEqual(find.presentation.status, "2049 of 4000")
        find.desiredIndex = 2050
        find.showResult()
        XCTAssertNil(find.selectedRange)
        XCTAssertTrue(find.presentation.canNavigate, "window fetch must keep accepting navigation intent")
        let request = find.request(for: content())
        XCTAssertEqual(request.previous, ranges[1])
        XCTAssertEqual(request.cursor, ranges[1].end)
        find.direction = -1
        XCTAssertEqual(find.request(for: content()).previous, ranges[0])
    }

    func testWrappedDecorationClipsToVisibleCellsAndIsRemovedAtAnotherRevision() {
        var find = HerdrFindState(paneID: "P", bootID: "boot", generation: 1)
        let wrapped = HerdrFindRange(start: .init(row: 9, col: 2), end: .init(row: 11, col: 3))
        find.result = HerdrFindResult(type: "pane_copy_search", pane_id: "P", content_revision: 2,
                                     matches: [wrapped], total: 1, current: 0, current_global: 0)
        find.desiredIndex = 0
        let decoration = HerdrFindDecoration(find: find, content: content())
        XCTAssertEqual(decoration?.rows[0]?.first?.start, 0)
        XCTAssertEqual(decoration?.rows[0]?.first?.end, 7)
        XCTAssertEqual(decoration?.rows[1]?.first?.end, 3)
        XCTAssertEqual(decoration?.rows[1]?.first?.selected, true)
        XCTAssertNil(HerdrFindDecoration(find: find, content: content(revision: 4)))
        find.invalidate()
        XCTAssertNil(HerdrFindDecoration(find: find, content: content()))
    }

    func testFreshSearchIncludesItsAnchorInsteadOfSteppingPastIt() {
        var find = HerdrFindState(paneID: "P", bootID: "boot", generation: 1)
        find.query = "x"
        find.origin = .init(row: 10, col: 0)
        find.direction = -1
        let request = find.request(for: content())
        XCTAssertEqual(request.cursor, .init(row: 9, col: 7))
        XCTAssertEqual(request.direction, "forward")
        XCTAssertNil(request.previous)
    }

    private func range(_ row: UInt32) -> HerdrFindRange {
        HerdrFindRange(start: .init(row: row, col: 0), end: .init(row: row, col: 1))
    }

    private func content(revision: UInt64 = 2) -> HerdrPaneContent {
        // The viewport begins at history row 10 and contains rows 10 and 11.
        let json = HerdrTerminalEngineTests.pane("P", x: 0, width: 8, height: 2, focused: true,
                                               contentRevision: revision, scroll: (10, 20, 2))
        return HerdrPaneContent(of: try! JSONDecoder().decode(HerdrSurfacePane.self, from: Data(json.utf8)))
    }
}
