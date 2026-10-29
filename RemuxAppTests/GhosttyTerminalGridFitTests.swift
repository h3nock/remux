import XCTest
@testable import Remux

/// How a popup's grid is fitted to the terminal area: the largest font whose cells hold it.
final class GhosttyTerminalGridFitTests: XCTestCase {
    private static let scale: CGFloat = 3

    /// A cell 0.6 wide and 1.25 tall per point of font, in whole pixels, as Ghostty rounds a cell.
    private static func cell(_ fontSize: Float32) -> GhosttyTerminalCellDisplayMetrics {
        GhosttyTerminalCellDisplayMetrics(
            pixelWidth: UInt32((Double(fontSize) * 0.6 * scale).rounded()),
            pixelHeight: UInt32((Double(fontSize) * 1.25 * scale).rounded()),
            contentScale: scale
        )
    }

    private func fit(
        current: GhosttyTerminalGridFit? = nil,
        columns: UInt16 = 20,
        rows: UInt16 = 10,
        area: (width: UInt32, height: UInt32) = (600, 600)
    ) -> GhosttyTerminalGridFit? {
        GhosttyTerminalGridFit.next(
            current: current,
            columns: columns,
            rows: rows,
            areaPixels: area,
            baseFontSize: 10,
            baseCell: Self.cell(10),
            measure: Self.cell
        )
    }

    /// The largest half-point size whose cells hold the grid: at 16 points 20 × 10 cells of 29 × 60
    /// pixels fill 580 × 600 of 600 × 600; at 16.5 the rows would need 620.
    func testTheGridGetsTheLargestFontItsAreaHolds() throws {
        let fit = try XCTUnwrap(fit())
        XCTAssertEqual(fit.fontSize, 16)
        XCTAssertEqual(fit.cell, Self.cell(16))
        XCTAssertLessThanOrEqual(20 * fit.cell.pixelWidth, 600)
        XCTAssertLessThanOrEqual(10 * fit.cell.pixelHeight, 600)
        XCTAssertGreaterThan(10 * Self.cell(16.5).pixelHeight, 600)
    }

    /// A grid of a few cells grows to three times the screen's font, no more.
    func testASmallGridStopsAtThreeTimesTheScreensFont() throws {
        XCTAssertEqual(fit(columns: 2, rows: 1)?.fontSize, 30)
    }

    /// A grid larger than the area at the screen's font gets a smaller font, as Herdr's grid for a device
    /// sized otherwise can be.
    func testALargeGridGetsASmallerFont() throws {
        let fit = try XCTUnwrap(fit(columns: 80, rows: 30))
        XCTAssertLessThan(fit.fontSize, 10)
        XCTAssertLessThanOrEqual(80 * fit.cell.pixelWidth, 600)
        XCTAssertLessThanOrEqual(30 * fit.cell.pixelHeight, 600)
    }

    /// The font in use stays while it fits and is within a point of the best, since a new size takes a new
    /// renderer; one further off, or one that no longer fits, gives way to the best.
    func testTheFontInUseStaysWhileItFitsAndIsCloseToTheBest() throws {
        let close = GhosttyTerminalGridFit(fontSize: 15.5, cell: Self.cell(15.5))
        XCTAssertEqual(fit(current: close), close)
        let far = GhosttyTerminalGridFit(fontSize: 14.5, cell: Self.cell(14.5))
        XCTAssertEqual(fit(current: far)?.fontSize, 16)
        let best = GhosttyTerminalGridFit(fontSize: 16, cell: Self.cell(16))
        let shrunk = try XCTUnwrap(fit(current: best, area: (600, 400)))
        XCTAssertLessThan(shrunk.fontSize, 16)
        XCTAssertLessThanOrEqual(10 * shrunk.cell.pixelHeight, 400)
    }

    /// A fit measured on a screen of another scale isn't kept.
    func testAFitFromAnotherScaleIsReplaced() throws {
        let other = GhosttyTerminalGridFit(
            fontSize: 15.5,
            cell: GhosttyTerminalCellDisplayMetrics(pixelWidth: 19, pixelHeight: 39, contentScale: 2)
        )
        XCTAssertEqual(fit(current: other)?.fontSize, 16)
    }

    /// No fit without a grid or an area, or when not even the smallest font holds the grid.
    func testNothingFitsAnEmptyGridOrATinyArea() {
        XCTAssertNil(fit(columns: 0))
        XCTAssertNil(fit(area: (0, 600)))
        XCTAssertNil(fit(columns: 200, rows: 100, area: (20, 20)))
    }
}
