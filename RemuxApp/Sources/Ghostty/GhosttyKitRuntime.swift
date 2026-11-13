import Darwin
import Foundation
import GhosttyKit
import QuartzCore
import UIKit

enum GhosttyKitRuntimeError: Error, Equatable {
    case initializationFailed(Int32)
    case processDirectoryConfigurationFailed(String)
    case environmentConfigurationFailed(String)
    case runtimeConfigurationFileFailed(String)
    case configCreationFailed
    case appCreationFailed
    case surfaceMeasurementFailed(ghostty_terminal_surface_result_e)
    case colorsUnavailable
}

/// The terminal's colours as Ghostty resolves them from the settings: its default text and background
/// colours and all 256 indexed colours.
struct GhosttyTerminalColors: Equatable, Sendable {
    struct Color: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    let foreground: Color
    let background: Color
    let palette: [Color]
}

extension GhosttyTerminalColors {
    /// The least contrast with the background that a line (3) and text (4.5) keep, as WCAG asks of
    /// graphics and of text.
    enum MinimumContrast {
        static let line = 3.0
        static let text = 4.5
    }

    /// The contrast WCAG gives two colours, from 1, none, to 21, black on white.
    static func contrast(_ first: Color, _ second: Color) -> Double {
        let (lighter, darker) = (max(first.luminance, second.luminance), min(first.luminance, second.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `color` as it stays readable against the background: as is when it has `minimumContrast`, else
    /// mixed toward the foreground just as far as reaches it, so it keeps as much of its hue as the theme
    /// allows; the foreground itself when not even that does.
    func legible(_ color: Color, minimumContrast: Double) -> Color {
        guard Self.contrast(color, background) < minimumContrast else { return color }
        guard Self.contrast(foreground, background) > minimumContrast else { return foreground }
        var (low, high) = (0.0, 1.0)
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if Self.contrast(color.mixed(toward: foreground, by: middle), background) >= minimumContrast {
                high = middle
            } else {
                low = middle
            }
        }
        return color.mixed(toward: foreground, by: high)
    }

    /// Text that reads as secondary to the foreground: halfway from it to the background, as readable as
    /// text must be.
    var secondaryText: Color {
        legible(foreground.mixed(toward: background, by: 0.5), minimumContrast: MinimumContrast.text)
    }
}

extension GhosttyTerminalColors.Color {
    /// Relative luminance, from sRGB (WCAG 2).
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour moved `fraction` of the way to `other`, channel by channel.
    func mixed(toward other: Self, by fraction: Double) -> Self {
        func mix(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8((Double(from) + (Double(to) - Double(from)) * fraction).rounded())
        }
        return Self(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }
}

enum GhosttyTerminalDeviceClass {
    case phone
    case pad
}

enum GhosttyTerminalAppearancePolicy {
    static let phoneMinimumFontSize: Float32 = 10
    static let phoneDefaultFontSize: Float32 = 10

    static func effectiveFontSize(
        for settings: TerminalSettings,
        deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> Float32? {
        if let fontSize = settings.fontSize {
            return fontSize
        }
        return effectiveFontSize(for: deviceClass, contentSizeCategory: contentSizeCategory)
    }

    static func effectiveFontSize(
        for deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> Float32? {
        switch deviceClass {
        case .phone:
            return phoneFontSize(contentSizeCategory: contentSizeCategory)
        case .pad:
            return nil
        }
    }

    @MainActor
    static func currentDeviceFontSize(
        settings: TerminalSettings = .default
    ) -> Float32? {
        let category = UIApplication.shared.preferredContentSizeCategory
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return effectiveFontSize(
                for: settings,
                deviceClass: .phone,
                contentSizeCategory: category
            )
        case .pad:
            return effectiveFontSize(
                for: settings,
                deviceClass: .pad,
                contentSizeCategory: category
            )
        default:
            return settings.fontSize
        }
    }

    private static func phoneFontSize(contentSizeCategory: UIContentSizeCategory) -> Float32 {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: CGFloat(phoneDefaultFontSize),
            compatibleWith: traits
        )
        return Float32(max(scaled, CGFloat(phoneMinimumFontSize)))
    }
}

private struct GhosttyTerminalRendererWarmupKey: Hashable {
    let theme: String
    let fontSize: Float32?
    let screenScale: Int
    let contentSizeCategory: String

    init(
        terminalSettings: TerminalSettings,
        screenScale: CGFloat,
        contentSizeCategory: UIContentSizeCategory
    ) {
        theme = terminalSettings.theme.rawValue
        fontSize = terminalSettings.fontSize
        self.screenScale = Int((screenScale * 1000).rounded())
        self.contentSizeCategory = contentSizeCategory.rawValue
    }
}

final class GhosttyKitSurfaceView: UIView {
    var onWindowAttachmentChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowAttachmentChange?()
    }

    override init(frame: CGRect) {
        super.init(frame: frame.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignGhosttyRendererSublayers()
    }

    func alignGhosttyRendererSublayers() {
        let scale = max(window?.screen.scale ?? contentScaleFactor, 1)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = bounds
            // Core Animation stores bounds at float precision. Ghostty Metal truncates
            // bounds * contentsScale, so round the representation upward when needed
            // to preserve the requested integer pixel extent (e.g. 1984 pixels at 3x).
            sublayer.bounds.size = CGSize(
                width: Self.rendererPointExtent(points: bounds.width, scale: scale),
                height: Self.rendererPointExtent(points: bounds.height, scale: scale)
            )
            sublayer.contentsScale = scale
        }
    }

    static func rendererPointExtent(points: CGFloat, scale: CGFloat) -> CGFloat {
        guard points.isFinite, scale.isFinite, points > 0, scale > 0 else { return points }
        let pixels = (points * scale).rounded()
        var extent = Float(pixels / scale)
        if Double(extent) * Double(scale) < Double(pixels) {
            extent = extent.nextUp
        }
        return CGFloat(extent)
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        backgroundColor = theme.terminalBackgroundUIColor
    }

    private func configure() {
        applyTerminalTheme(.ghosttyDefault)
        clipsToBounds = true
        isOpaque = true
        contentScaleFactor = max(UIScreen.main.scale, 1)
    }
}

extension TerminalTheme {
    var terminalBackgroundUIColor: UIColor {
        terminalUIColor(hex: terminalBackgroundHex)
    }

    var terminalCompositeSeparatorUIColor: UIColor {
        terminalUIColor(hex: terminalCompositeSeparatorHex)
    }

    private func terminalUIColor(hex: UInt32) -> UIColor {
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
final class GhosttyKitRuntime {
    private static var initialized = false
    private static var terminalRendererWarmupKeys = Set<GhosttyTerminalRendererWarmupKey>()

    private let state: GhosttyKitRuntimeState

    init(terminalSettings: TerminalSettings = .default) throws {
        try Self.initializeBackend()
        state = try GhosttyKitRuntimeState(terminalSettings: terminalSettings)
    }

    var appHandle: ghostty_app_t { state.app }

    func makeTmuxBaseSurfaceConfig() -> ghostty_terminal_surface_config_s {
        ghostty_terminal_surface_config_new()
    }

    static func prewarmTerminalRenderer(terminalSettings: TerminalSettings) {
        let key = GhosttyTerminalRendererWarmupKey(
            terminalSettings: terminalSettings,
            screenScale: UIScreen.main.scale,
            contentSizeCategory: UIApplication.shared.preferredContentSizeCategory
        )
        guard terminalRendererWarmupKeys.insert(key).inserted else { return }

        do {
            let runtime = try GhosttyKitRuntime(terminalSettings: terminalSettings)
            _ = try runtime.measureTmuxViewport(
                size: CGSize(width: 96, height: 96),
                scale: UIScreen.main.scale
            )
        } catch {
            terminalRendererWarmupKeys.remove(key)
            GhosttyRuntimeTrace.diagnostics(
                "runtime.prewarmTerminalRenderer failed error=\(String(describing: error))"
            )
        }
    }

    func measureTmuxViewport(size: CGSize, scale: CGFloat) throws -> TmuxControlViewport? {
        try measureTmuxViewportLayout(size: size, scale: scale)?.controlViewport
    }

    func measureTmuxViewportLayout(
        size: CGSize,
        scale: CGFloat
    ) throws -> GhosttyTerminalViewportMeasurement? {
        let size = GhosttyTerminalViewportCoordinator.normalized(size)
        guard size.width > 1, size.height > 1 else { return nil }

        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        var config = makeTmuxBaseSurfaceConfig()
        config.scale_factor = metrics.contentScale
        config.width_px = metrics.pixelWidth
        config.height_px = metrics.pixelHeight
        var measured = ghostty_surface_size_s()
        let result = ghostty_terminal_surface_measure(state.app, &config, &measured)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            throw GhosttyKitRuntimeError.surfaceMeasurementFailed(result)
        }
        return GhosttyTerminalViewportMeasurement(
            measuredSize: measured,
            displayMetrics: metrics
        )
    }

    #if DEBUG
    var appHandleForTesting: ghostty_app_t { state.app }
    #endif

    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        try state.applyTerminalSettings(settings)
    }

    /// The colours of the current settings, for a backend that reports them to its server.
    func terminalColors() throws -> GhosttyTerminalColors {
        try state.terminalColors()
    }

    private static func initializeBackend() throws {
        guard !initialized else { return }
        try configureProcessDirectories()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyKitRuntimeError.initializationFailed(result)
        }
        initialized = true
        removeRetiredCrashReports()
    }

    // GhosttyKit is built without Sentry, so nothing reads or writes these
    // any more; builds that linked it left crash dumps and Sentry's run
    // database in Ghostty's state and cache directories.
    private static func removeRetiredCrashReports() {
        let retired: [(variable: String, subdirectory: String)] = [
            ("XDG_STATE_HOME", "ghostty/crash"),
            ("XDG_CACHE_HOME", "ghostty/sentry"),
        ]
        let paths = retired.compactMap { entry in
            getenv(entry.variable).map { "\(String(cString: $0))/\(entry.subdirectory)" }
        }
        Task.detached(priority: .utility) {
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func configureProcessDirectories() throws {
        let home = NSHomeDirectory()
        let applicationSupport = "\(home)/Library/Application Support"
        let caches = "\(home)/Library/Caches"
        try createDirectoryIfNeeded(at: applicationSupport)
        try createDirectoryIfNeeded(at: caches)
        try setEnvironment("HOME", to: home)
        try setEnvironment("XDG_CONFIG_HOME", to: applicationSupport)
        try setEnvironment("XDG_CACHE_HOME", to: caches)
        try setEnvironment("XDG_STATE_HOME", to: applicationSupport)
    }

    private static func createDirectoryIfNeeded(at path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        } catch {
            throw GhosttyKitRuntimeError.processDirectoryConfigurationFailed(path)
        }
    }

    private static func setEnvironment(_ name: String, to value: String) throws {
        guard getenv(name) == nil else { return }
        let result = name.withCString { namePointer in
            value.withCString { valuePointer in
                setenv(namePointer, valuePointer, 1)
            }
        }
        guard result == 0 else {
            throw GhosttyKitRuntimeError.environmentConfigurationFailed(name)
        }
    }
}

private final class GhosttyKitRuntimeState {
    let app: ghostty_app_t
    private(set) var terminalSettings: TerminalSettings

    private let config: ghostty_config_t
    private let callbacks: GhosttyKitRuntimeCallbacks

    @MainActor
    init(terminalSettings: TerminalSettings) throws {
        guard let config = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        try Self.loadSettings(
            terminalSettings,
            into: config,
            effectiveFontSize: GhosttyTerminalAppearancePolicy
                .currentDeviceFontSize(settings: terminalSettings)
        )
        ghostty_config_finalize(config)

        let callbacks = GhosttyKitRuntimeCallbacks()
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: callbacks.userdata,
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyKitRuntimeCallbacks.wakeupCallback,
            action_cb: GhosttyKitRuntimeCallbacks.actionCallback,
            read_clipboard_cb: nil,
            confirm_read_clipboard_cb: nil,
            write_clipboard_cb: nil,
            close_surface_cb: nil
        )
        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw GhosttyKitRuntimeError.appCreationFailed
        }

        self.app = app
        self.config = config
        self.callbacks = callbacks
        self.terminalSettings = terminalSettings
        callbacks.app = app
    }

    deinit {
        callbacks.app = nil
        ghostty_app_free(app)
        ghostty_config_free(config)
        _ = callbacks
    }

    @MainActor
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard settings != terminalSettings else { return }
        guard let replacement = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        defer { ghostty_config_free(replacement) }

        try Self.loadSettings(
            settings,
            into: replacement,
            effectiveFontSize: GhosttyTerminalAppearancePolicy
                .currentDeviceFontSize(settings: settings)
        )
        ghostty_config_finalize(replacement)
        ghostty_app_update_config(app, replacement)
        terminalSettings = settings
    }

    /// Read from a config built from the current settings: a settings change gives the app a new
    /// config, and `config` keeps the first.
    func terminalColors() throws -> GhosttyTerminalColors {
        guard let config = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        defer { ghostty_config_free(config) }
        try Self.loadSettings(terminalSettings, into: config, effectiveFontSize: nil)
        ghostty_config_finalize(config)

        var foreground = ghostty_config_color_s()
        var background = ghostty_config_color_s()
        var palette = ghostty_config_palette_s()
        guard Self.read("foreground", from: config, into: &foreground),
              Self.read("background", from: config, into: &background),
              Self.read("palette", from: config, into: &palette)
        else { throw GhosttyKitRuntimeError.colorsUnavailable }

        func color(_ value: ghostty_config_color_s) -> GhosttyTerminalColors.Color {
            GhosttyTerminalColors.Color(red: value.r, green: value.g, blue: value.b)
        }
        let paletteColors = withUnsafeBytes(of: palette.colors) { bytes in
            bytes.bindMemory(to: ghostty_config_color_s.self).map(color)
        }
        return GhosttyTerminalColors(
            foreground: color(foreground),
            background: color(background),
            palette: paletteColors
        )
    }

    private static func read<Value>(
        _ key: String,
        from config: ghostty_config_t,
        into value: inout Value
    ) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            ghostty_config_get(config, pointer, key, UInt(key.utf8.count))
        }
    }

    private static func loadSettings(
        _ settings: TerminalSettings,
        into config: ghostty_config_t,
        effectiveFontSize: Float32?
    ) throws {
        var contents = settings.ghosttyConfigContents(
            effectiveFontSize: effectiveFontSize
        ) ?? ""
        contents += "window-padding-x = 0\n"
        contents += "window-padding-y = 0\n"
        contents += "window-padding-balance = false\n"

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-ghostty-\(UUID().uuidString).conf")
        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GhosttyKitRuntimeError.runtimeConfigurationFileFailed(fileURL.path)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        fileURL.path.withCString { ghostty_config_load_file(config, $0) }
    }
}

private final class GhosttyKitRuntimeCallbacks: @unchecked Sendable {
    var app: ghostty_app_t?

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
        guard let userdata else { return }
        let callbacks = Unmanaged<GhosttyKitRuntimeCallbacks>
            .fromOpaque(userdata).takeUnretainedValue()
        Task { @MainActor in
            guard let app = callbacks.app else { return }
            ghostty_app_tick(app)
        }
    }

    static let actionCallback: ghostty_runtime_action_cb = { _, _, _ in true }
}
