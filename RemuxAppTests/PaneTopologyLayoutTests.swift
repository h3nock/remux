import CoreGraphics
import XCTest
@testable import Remux

final class PaneTopologyLayoutTests: XCTestCase {
    func testSizeUsesAvailableWidthAndCapsItsHeight() {
        let size = PaneTopologyLayout.size(
            availableWidth: 361,
            maximumHeight: 240
        )

        XCTAssertEqual(size.width, 361, accuracy: 0.001)
        XCTAssertEqual(size.height, 240, accuracy: 0.001)
    }

    func testSizeUsesPortraitAspectWhenHeightAllows() {
        let size = PaneTopologyLayout.size(
            availableWidth: 361,
            maximumHeight: 520
        )

        XCTAssertEqual(size, CGSize(width: 361, height: 271))
    }

    func testPreservesSplitStructureWithEqualPaneArea() throws {
        let panes = fivePaneTopology()
        let metrics = try XCTUnwrap(PaneTopologyLayout.frames(
            panes: panes,
            size: CGSize(width: 360, height: 100)
        ))
        let frames = try panes.map { try XCTUnwrap(metrics.frame(for: $0.id)) }
        let expectedArea = frames[0].width * frames[0].height

        for frame in frames {
            XCTAssertEqual(frame.width * frame.height, expectedArea, accuracy: 0.01)
        }
        XCTAssertEqual(frames[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[2].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[3].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[4].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[0].maxY, frames[1].minY, accuracy: 0.001)
        XCTAssertEqual(frames[2].maxY, frames[3].minY, accuracy: 0.001)
        XCTAssertEqual(frames[3].maxY, frames[4].minY, accuracy: 0.001)
    }

    private func fivePaneTopology() -> [PaneTopologyLayout.Pane] {
        [
            .init(id: UUID(), frame: .init(x: 0, y: 0, columns: 39, rows: 59)),
            .init(id: UUID(), frame: .init(x: 0, y: 60, columns: 39, rows: 40)),
            .init(id: UUID(), frame: .init(x: 40, y: 0, columns: 60, rows: 9)),
            .init(id: UUID(), frame: .init(x: 40, y: 10, columns: 60, rows: 69)),
            .init(id: UUID(), frame: .init(x: 40, y: 80, columns: 60, rows: 20)),
        ]
    }
}
