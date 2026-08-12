import CoreGraphics
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyKitControlSurfaceTests: XCTestCase {
    func testDisplayMetricsUseScaleForPixelDimensions() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1170,
                pixelHeight: 1923
            )
        )

        XCTAssertEqual(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 41,
                    rows: 28,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            ),
            TmuxControlViewport(
                columns: 41,
                rows: 28,
                pixelWidth: 1170,
                pixelHeight: 1923
            )
        )
        XCTAssertNil(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 0,
                    rows: 28,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            )
        )
        XCTAssertNil(
            TmuxControlViewport(
                ghosttySurfaceSize: ghostty_surface_size_s(
                    columns: 41,
                    rows: 0,
                    width_px: 1170,
                    height_px: 1923,
                    cell_width_px: 28,
                    cell_height_px: 68
                )
            )
        )
    }

    func testDisplayMetricsClampTransientInvalidScale() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: 0
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
    }

    func testDisplayMetricsClampNonFiniteScale() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: .nan
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 390, height: 641),
                scale: .infinity
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 1,
                pixelWidth: 390,
                pixelHeight: 641
            )
        )
    }

    func testDisplayMetricsClampInvalidSizeToOnePixel() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: 0, height: CGFloat.nan),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: 1,
                pixelHeight: 1
            )
        )
    }

    func testDisplayMetricsClampOversizedPixelDimensions() {
        XCTAssertEqual(
            GhosttySurfaceDisplayMetrics(
                size: CGSize(width: CGFloat(UInt32.max), height: 10),
                scale: 3
            ),
            GhosttySurfaceDisplayMetrics(
                contentScale: 3,
                pixelWidth: UInt32.max,
                pixelHeight: 30
            )
        )
    }

    func testSelectionSnapshotConvertsBackingPixelsWithoutSwappingEndpointRoles() {
        let snapshot = GhosttyLocalSelectionSnapshot(
            cValue: ghostty_terminal_surface_selection_snapshot_s(
                start: ghostty_terminal_surface_cell_geometry_s(
                    x_px: 180,
                    y_px: 30,
                    width_px: 24,
                    height_px: 60,
                    visible: true
                ),
                end: ghostty_terminal_surface_cell_geometry_s(
                    x_px: 60,
                    y_px: 90,
                    width_px: 24,
                    height_px: 60,
                    visible: true
                ),
                active: true,
                rectangle: false
            ),
            scaleFactor: 3
        )

        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.start, CGRect(x: 60, y: 10, width: 8, height: 20))
        XCTAssertEqual(snapshot.end, CGRect(x: 20, y: 30, width: 8, height: 20))
    }

    func testSelectionSnapshotOmitsInvisibleEndpointGeometry() {
        let snapshot = GhosttyLocalSelectionSnapshot(
            cValue: ghostty_terminal_surface_selection_snapshot_s(
                start: ghostty_terminal_surface_cell_geometry_s(
                    x_px: 30,
                    y_px: 60,
                    width_px: 24,
                    height_px: 60,
                    visible: true
                ),
                end: ghostty_terminal_surface_cell_geometry_s(
                    x_px: 0,
                    y_px: 0,
                    width_px: 0,
                    height_px: 0,
                    visible: false
                ),
                active: true,
                rectangle: false
            ),
            scaleFactor: 3
        )

        XCTAssertEqual(snapshot.start, CGRect(x: 10, y: 20, width: 8, height: 20))
        XCTAssertNil(snapshot.end)
    }


    func testDecodeGhosttyTextReturnsEmptyStringForMissingBuffer() {
        XCTAssertEqual(
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: 0,
                    text: nil,
                    text_len: 0
                )
            ),
            ""
        )
    }

    func testDecodeGhosttyTextPreservesUtf8Content() {
        let value = "café λ"

        let decoded = value.withCString { pointer in
            GhosttyKitControlSurface.decodeGhosttyText(
                ghostty_text_s(
                    tl_px_x: 0,
                    tl_px_y: 0,
                    offset_start: 0,
                    offset_len: UInt32(value.utf8.count),
                    text: pointer,
                    text_len: UInt(value.utf8.count)
                )
            )
        }

        XCTAssertEqual(decoded, value)
    }

}
