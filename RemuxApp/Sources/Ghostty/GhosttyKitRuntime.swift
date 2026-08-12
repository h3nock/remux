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
            sublayer.contentsScale = scale
        }
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

    private static func initializeBackend() throws {
        guard !initialized else { return }
        try configureProcessDirectories()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyKitRuntimeError.initializationFailed(result)
        }
        initialized = true
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
