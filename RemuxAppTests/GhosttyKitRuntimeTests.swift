import Foundation
import GhosttyKit
import QuartzCore
import UIKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyKitRuntimeTests: XCTestCase {
    func testReleaseBuildModePolicyAcceptsReleaseFastGhosttyKit() {
        XCTAssertNil(
            GhosttyKitBuildModePolicy.releaseValidationFailure(
                for: GHOSTTY_BUILD_MODE_RELEASE_FAST
            )
        )
    }

    func testReleaseBuildModePolicyRejectsDebugGhosttyKitWithActionableFailure() {
        XCTAssertEqual(
            GhosttyKitBuildModePolicy.releaseValidationFailure(
                for: GHOSTTY_BUILD_MODE_DEBUG
            ),
            "Remux Release requires ReleaseFast GhosttyKit; detected Debug. Run scripts/build_release_ghosttykit.sh and rebuild."
        )
    }

    func testRuntimeInitializesGhosttyBackend() throws {
        _ = try GhosttyKitRuntime()
    }

    func testSurfaceViewDoesNotDefaultToDesktopSizedFrame() {
        let view = GhosttyKitSurfaceView(frame: .zero)

        XCTAssertEqual(view.frame.size.width, 1)
        XCTAssertEqual(view.frame.size.height, 1)
    }

    func testPhoneTerminalAppearanceUsesAccessibleMobileDensity() throws {
        let fontSize = GhosttyTerminalAppearancePolicy.effectiveFontSize(
            for: .phone,
            contentSizeCategory: .large
        )

        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(fontSize),
            GhosttyTerminalAppearancePolicy.phoneMinimumFontSize
        )
        XCTAssertEqual(fontSize, 10)
    }

    func testPhoneTerminalAppearanceScalesWithAccessibilityTextSize() throws {
        let regular = GhosttyTerminalAppearancePolicy.effectiveFontSize(
            for: .phone,
            contentSizeCategory: .large
        )
        let accessibility = GhosttyTerminalAppearancePolicy.effectiveFontSize(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        XCTAssertGreaterThan(try XCTUnwrap(accessibility), try XCTUnwrap(regular))
    }

    func testPadTerminalAppearanceUsesGhosttyDefaultDensity() {
        let fontSize = GhosttyTerminalAppearancePolicy.effectiveFontSize(for: .pad)

        XCTAssertNil(fontSize)
    }

    func testTmuxBaseSurfaceConfigDoesNotOverrideAppOwnedFontSize() throws {
        let runtime = try GhosttyKitRuntime()

        XCTAssertEqual(runtime.makeTmuxBaseSurfaceConfig().font_size, 0)
    }

    func testTerminalSurfaceReplacementLeavesOneRendererLayerAndDetachesFreedLayers() throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        var firstLayer: CALayer?

        for index in 0..<12 {
            let layer = try fixture.createSurface()
            XCTAssertEqual(fixture.view.layer.sublayers?.count, 1)
            if index == 0 {
                firstLayer = layer
            } else {
                XCTAssertFalse(layer === firstLayer)
            }
            try fixture.setVisible()

            let freedLayer = try XCTUnwrap(fixture.freeSurface())
            XCTAssertNil(freedLayer.superlayer)
            XCTAssertEqual(fixture.view.layer.sublayers?.count ?? 0, 0)
            freedLayer.setNeedsDisplay()
            freedLayer.displayIfNeeded()
        }
    }

    func testOwnedIOSurfaceFrameSurvivesRendererReuseAndRelease() async throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        let layer = try fixture.createSurface()
        try await awaitPublication(on: layer) {
            try fixture.setVisible()
        }
        let frame = try GhosttyIOSurfaceFrame.read(from: layer)
        let originalBytes = frame.bytes

        for index in 0..<5 {
            try await awaitPublication(on: layer) {
                try fixture.feed("\u{1B}[\(41 + index)mframe-\(index)\u{1B}[0m\r\n")
            }
        }
        _ = fixture.freeSurface()

        let image = try await Task.detached {
            try frame.image(maxWidth: 160, maxHeight: 120)
        }.value
        XCTAssertEqual(frame.bytes, originalBytes)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testHiddenSurfacePublishesRequestedCurrentFrame() async throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        let layer = try fixture.createSurface()
        try fixture.feed("hidden frame\r\n")

        try await awaitPublication(on: layer) {
            try fixture.requestFrame()
        }

        let frame = try GhosttyIOSurfaceFrame.read(from: layer)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)

        try fixture.feed("\n\u{1B}]11;#010203\u{1B}\\")
        try await awaitPublication(
            on: layer,
            matchingBGRPixel: [3, 2, 1]
        ) {
            try fixture.requestFrame()
        }
        XCTAssertTrue(
            try GhosttyIOSurfaceFrame.read(from: layer).bgrPixel
                .isApproximatelyEqual(to: [3, 2, 1])
        )
    }

    func testIOSurfaceReadCopiesOnlyRequestedRectangle() async throws {
        let fixture = try NativeTerminalSurfaceFixture()
        defer { fixture.close() }
        let layer = try fixture.createSurface()
        try await awaitPublication(on: layer) {
            try fixture.setVisible()
        }

        let frame = try GhosttyIOSurfaceFrame.read(
            from: layer,
            sourceRect: CGRect(x: 10, y: 12, width: 40, height: 30)
        )

        XCTAssertEqual(frame.width, 40)
        XCTAssertEqual(frame.height, 30)
        XCTAssertEqual(frame.bytesPerRow, 160)
        XCTAssertEqual(frame.bytes.count, 4_800)
    }

    func testPreviewSourceRectCentersOnCursorAndClampsToFrameEdges() throws {
        XCTAssertEqual(
            GhosttyIOSurfaceFrame.sourceRect(
                width: 1_000,
                height: 800,
                centeredOn: CGRect(x: 495, y: 395, width: 10, height: 10),
                maxWidth: 400,
                maxHeight: 300
            ),
            CGRect(x: 300, y: 250, width: 400, height: 300)
        )
        XCTAssertEqual(
            GhosttyIOSurfaceFrame.sourceRect(
                width: 1_000,
                height: 800,
                centeredOn: CGRect(x: 0, y: 0, width: 10, height: 10),
                maxWidth: 400,
                maxHeight: 300
            ),
            CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertEqual(
            GhosttyIOSurfaceFrame.sourceRect(
                width: 1_000,
                height: 800,
                centeredOn: CGRect(x: 990, y: 790, width: 10, height: 10),
                maxWidth: 400,
                maxHeight: 300
            ),
            CGRect(x: 600, y: 500, width: 400, height: 300)
        )
    }

    func testPreviewSourceRectRejectsCursorOutsideFrame() {
        XCTAssertNil(
            GhosttyIOSurfaceFrame.sourceRect(
                width: 100,
                height: 80,
                centeredOn: CGRect(x: 120, y: 10, width: 8, height: 16),
                maxWidth: 40,
                maxHeight: 30
            )
        )
    }

    func testLiveConfigUpdatePreservesSurfaceAndTerminalOSCBackgroundOverride() async throws {
        let fixture = try NativeTerminalSurfaceFixture(
            settings: TerminalSettings(fontSize: 11, theme: .remuxDark)
        )
        defer { fixture.close() }
        let layer = try fixture.createSurface()
        // Embedded terminal surfaces intentionally have no internal padding.
        // Move the cursor away from the sampled top-left background pixel so
        // this test observes the configured/OSC background, not cursor paint.
        try fixture.feed("\n")
        try await awaitPublication(
            on: layer,
            matchingBGRPixel: [0x2E, 0x1E, 0x1E]
        ) {
            try fixture.setVisible()
        }
        XCTAssertTrue(
            try GhosttyIOSurfaceFrame.read(from: layer).bgrPixel
                .isApproximatelyEqual(to: [0x2E, 0x1E, 0x1E])
        )
        try await awaitPublication(on: layer, matchingBGRPixel: [3, 2, 1]) {
            try fixture.feed("\u{1B}]11;#010203\u{1B}\\")
        }
        let originalSurface = try XCTUnwrap(fixture.surfaceHandle)
        let originalSize = try fixture.surfaceSize()
        XCTAssertEqual(try GhosttyIOSurfaceFrame.read(from: layer).bgrPixel, [3, 2, 1])

        try await awaitPublication(on: layer, matchingBGRPixel: [3, 2, 1]) {
            try fixture.updateSettings(
                TerminalSettings(fontSize: 11, theme: .remuxLight)
            )
        }

        XCTAssertEqual(fixture.surfaceHandle, originalSurface)
        XCTAssertTrue(viewRendererLayer(fixture.view) === layer)
        let updatedSize = try fixture.surfaceSize()
        XCTAssertEqual(updatedSize.width_px, originalSize.width_px)
        XCTAssertEqual(updatedSize.height_px, originalSize.height_px)
        XCTAssertEqual(updatedSize.cell_width_px, originalSize.cell_width_px)
        XCTAssertEqual(updatedSize.cell_height_px, originalSize.cell_height_px)
        XCTAssertEqual(try GhosttyIOSurfaceFrame.read(from: layer).bgrPixel, [3, 2, 1])

        try await awaitPublication(
            on: layer,
            matchingBGRPixel: [0xF5, 0xF1, 0xEF]
        ) {
            try fixture.feed("\u{1B}]111\u{1B}\\")
        }
        XCTAssertTrue(
            try GhosttyIOSurfaceFrame.read(from: layer).bgrPixel
                .isApproximatelyEqual(to: [0xF5, 0xF1, 0xEF])
        )
    }

    func testLiveConfigUpdateAdoptsAppOwnedFontSize() throws {
        let fixture = try NativeTerminalSurfaceFixture(
            settings: TerminalSettings(fontSize: 11, theme: .remuxDark)
        )
        defer { fixture.close() }
        _ = try fixture.createSurface()
        let before = try fixture.surfaceSize()

        try fixture.updateSettings(TerminalSettings(fontSize: 18, theme: .remuxDark))

        let after = try fixture.surfaceSize()
        XCTAssertEqual(after.width_px, before.width_px)
        XCTAssertEqual(after.height_px, before.height_px)
        XCTAssertGreaterThan(after.cell_width_px, before.cell_width_px)
        XCTAssertGreaterThan(after.cell_height_px, before.cell_height_px)
    }

    func testLiveConfigUpdatePreservesExplicitPerSurfaceFontOverride() throws {
        let fixture = try NativeTerminalSurfaceFixture(
            settings: TerminalSettings(fontSize: 11, theme: .remuxDark),
            surfaceFontSizeOverride: 14
        )
        defer { fixture.close() }
        _ = try fixture.createSurface()
        let originalSurface = fixture.surfaceHandle
        let before = try fixture.surfaceSize()

        try fixture.updateSettings(TerminalSettings(fontSize: 20, theme: .remuxLight))

        let after = try fixture.surfaceSize()
        XCTAssertEqual(fixture.surfaceHandle, originalSurface)
        XCTAssertEqual(after.width_px, before.width_px)
        XCTAssertEqual(after.height_px, before.height_px)
        XCTAssertEqual(after.cell_width_px, before.cell_width_px)
        XCTAssertEqual(after.cell_height_px, before.cell_height_px)
    }

    private func awaitPublication(
        on layer: CALayer,
        matchingBGRPixel expectedPixel: [UInt8]? = nil,
        perform: () throws -> Void
    ) async throws {
        let publication = expectation(description: "renderer publishes IOSurface")
        publication.assertForOverFulfill = false
        let observation = layer.observe(\.contents, options: [.new]) { layer, _ in
            guard let expectedPixel else {
                publication.fulfill()
                return
            }
            guard let frame = try? GhosttyIOSurfaceFrame.read(from: layer),
                  frame.bgrPixel.isApproximatelyEqual(to: expectedPixel)
            else { return }
            publication.fulfill()
        }
        defer { observation.invalidate() }
        try perform()
        await fulfillment(of: [publication], timeout: 2)
    }

    private func viewRendererLayer(_ view: UIView) -> CALayer? {
        GhosttyIOSurfaceFrame.rendererLayer(in: view.layer)
    }

}

@MainActor
private final class NativeTerminalSurfaceFixture {
    enum FixtureError: Error {
        case producer(ghostty_terminal_producer_result_e)
        case terminal(ghostty_terminal_producer_result_e)
        case surface(ghostty_terminal_surface_result_e)
        case missingRendererLayer
    }

    let runtime: GhosttyKitRuntime
    let view = GhosttyKitSurfaceView(
        frame: CGRect(x: 0, y: 0, width: 320, height: 180)
    )
    private let window = UIWindow(
        frame: CGRect(x: 0, y: 0, width: 320, height: 180)
    )

    private let producer: ghostty_terminal_producer_t
    private let terminal: ghostty_terminal_t
    private let surfaceFontSizeOverride: Float32
    private var surface: ghostty_terminal_surface_t?

    var surfaceHandle: ghostty_terminal_surface_t? { surface }

    init(
        settings: TerminalSettings = .default,
        surfaceFontSizeOverride: Float32 = 0
    ) throws {
        runtime = try GhosttyKitRuntime(terminalSettings: settings)
        self.surfaceFontSizeOverride = surfaceFontSizeOverride
        var producerConfig = ghostty_terminal_producer_config_new()
        producerConfig.columns = 80
        producerConfig.rows = 24
        producerConfig.max_scrollback = 100

        var createdProducer: ghostty_terminal_producer_t?
        let producerResult = ghostty_terminal_producer_new(
            &producerConfig,
            &createdProducer
        )
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdProducer
        else { throw FixtureError.producer(producerResult) }

        var createdTerminal: ghostty_terminal_t?
        let terminalResult = ghostty_terminal_producer_retain_terminal(
            createdProducer,
            &createdTerminal
        )
        guard terminalResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK,
              let createdTerminal
        else {
            ghostty_terminal_producer_free(createdProducer)
            throw FixtureError.terminal(terminalResult)
        }
        producer = createdProducer
        terminal = createdTerminal

        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
    }

    func createSurface() throws -> CALayer {
        precondition(surface == nil)
        let scale = max(window.screen.scale, 1)
        var config = runtime.makeTmuxBaseSurfaceConfig()
        config.font_size = surfaceFontSizeOverride
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.scale_factor = scale
        config.width_px = UInt32((view.bounds.width * scale).rounded())
        config.height_px = UInt32((view.bounds.height * scale).rounded())
        config.visible = false
        config.focused = true

        var createdSurface: ghostty_terminal_surface_t?
        let result = ghostty_terminal_surface_new(
            runtime.appHandleForTesting,
            terminal,
            &config,
            &createdSurface
        )
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
              let createdSurface
        else { throw FixtureError.surface(result) }
        surface = createdSurface
        view.alignGhosttyRendererSublayers()
        guard let layer = view.layer.sublayers?.first else {
            ghostty_terminal_surface_free(createdSurface)
            surface = nil
            throw FixtureError.missingRendererLayer
        }
        return layer
    }

    func setVisible() throws {
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_set_visible(surface, true)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func feed(_ text: String) throws {
        let producerResult = text.utf8.withContiguousStorageIfAvailable { bytes in
            ghostty_terminal_producer_feed(producer, bytes.baseAddress, bytes.count)
        } ?? Array(text.utf8).withUnsafeBufferPointer { bytes in
            ghostty_terminal_producer_feed(producer, bytes.baseAddress, bytes.count)
        }
        guard producerResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            throw FixtureError.producer(producerResult)
        }
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_terminal_changed(surface)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func updateSettings(_ settings: TerminalSettings) throws {
        try runtime.applyTerminalSettings(settings)
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_update_config(surface)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func requestFrame() throws {
        guard let surface else { throw FixtureError.missingRendererLayer }
        let result = ghostty_terminal_surface_request_frame(surface)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        ghostty_app_tick(runtime.appHandleForTesting)
    }

    func surfaceSize() throws -> ghostty_surface_size_s {
        guard let surface else { throw FixtureError.missingRendererLayer }
        var size = ghostty_surface_size_s()
        let result = ghostty_terminal_surface_size(surface, &size)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw FixtureError.surface(result)
        }
        return size
    }

    func freeSurface() -> CALayer? {
        guard let surface else { return nil }
        let layer = view.layer.sublayers?.first
        ghostty_terminal_surface_free(surface)
        self.surface = nil
        return layer
    }

    func close() {
        window.isHidden = true
        if let surface { ghostty_terminal_surface_free(surface) }
        surface = nil
        ghostty_terminal_release(terminal)
        ghostty_terminal_producer_free(producer)
        _ = runtime
    }
}

private extension GhosttyIOSurfaceFrame {
    var bgrPixel: [UInt8] {
        Array(bytes.prefix(3))
    }
}

private extension CGImage {
    func firstChannelPixel(x: Int, y: Int) -> UInt8? {
        guard x >= 0, x < width, y >= 0, y < height,
              let data = dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }
        return bytes[y * bytesPerRow + x * 4]
    }
}

private extension Array where Element == UInt8 {
    func isApproximatelyEqual(to expected: [UInt8], tolerance: Int = 1) -> Bool {
        count == expected.count && zip(self, expected).allSatisfy { actual, expected in
            abs(Int(actual) - Int(expected)) <= tolerance
        }
    }
}
