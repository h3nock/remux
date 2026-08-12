import Foundation

enum TerminalTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case ghosttyDefault
    case remuxDark
    case remuxLight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ghosttyDefault:
            "Ghostty Default"
        case .remuxDark:
            "Catppuccin Mocha"
        case .remuxLight:
            "Catppuccin Latte"
        }
    }

    var pickerTitle: String {
        switch self {
        case .ghosttyDefault:
            "Default"
        case .remuxDark:
            "Mocha"
        case .remuxLight:
            "Latte"
        }
    }

    var ghosttyConfigLines: [String] {
        switch self {
        case .ghosttyDefault:
            []
        case .remuxDark:
            [
                // Catppuccin Mocha is the dark member of the popular
                // Catppuccin family. Keep the full palette inline so iOS
                // config updates don't depend on theme resource lookup in the
                // embedded runtime.
                "palette = 0=#45475a",
                "palette = 1=#f38ba8",
                "palette = 2=#a6e3a1",
                "palette = 3=#f9e2af",
                "palette = 4=#89b4fa",
                "palette = 5=#f5c2e7",
                "palette = 6=#94e2d5",
                "palette = 7=#a6adc8",
                "palette = 8=#585b70",
                "palette = 9=#f38ba8",
                "palette = 10=#a6e3a1",
                "palette = 11=#f9e2af",
                "palette = 12=#89b4fa",
                "palette = 13=#f5c2e7",
                "palette = 14=#94e2d5",
                "palette = 15=#bac2de",
                "background = #1e1e2e",
                "foreground = #cdd6f4",
                "cursor-color = #f5e0dc",
                "cursor-text = #11111b",
                "selection-background = #353749",
                "selection-foreground = #cdd6f4",
                "split-divider-color = #313244",
            ]
        case .remuxLight:
            [
                // Catppuccin Latte is the light member of the popular
                // Catppuccin family.
                "palette = 0=#5c5f77",
                "palette = 1=#d20f39",
                "palette = 2=#40a02b",
                "palette = 3=#df8e1d",
                "palette = 4=#1e66f5",
                "palette = 5=#ea76cb",
                "palette = 6=#179299",
                "palette = 7=#acb0be",
                "palette = 8=#6c6f85",
                "palette = 9=#d20f39",
                "palette = 10=#40a02b",
                "palette = 11=#df8e1d",
                "palette = 12=#1e66f5",
                "palette = 13=#ea76cb",
                "palette = 14=#179299",
                "palette = 15=#bcc0cc",
                "background = #eff1f5",
                "foreground = #4c4f69",
                "cursor-color = #dc8a78",
                "cursor-text = #eff1f5",
                "selection-background = #d8dae1",
                "selection-foreground = #4c4f69",
                "split-divider-color = #ccd0da",
            ]
        }
    }

    /// Background color the terminal renders against, mirrored by Ghostty UI
    /// chrome so surfaces can blend into the terminal area during keyboard
    /// transitions. Values must stay in sync with `ghosttyConfigLines` and with
    /// Ghostty's own default for `.ghosttyDefault`, sourced from
    /// `src/config/Config.zig`.
    var terminalBackgroundHex: UInt32 {
        switch self {
        case .ghosttyDefault:
            0x282C34
        case .remuxDark:
            0x1E1E2E
        case .remuxLight:
            0xEFF1F5
        }
    }

    /// Neutral separator used by Remux's phone-sized composite. These colors
    /// deliberately have more contrast than Ghostty's desktop split divider
    /// because a one-pixel line otherwise disappears at mobile scale.
    var terminalCompositeSeparatorHex: UInt32 {
        switch self {
        case .ghosttyDefault:
            0x4F5259
        case .remuxDark:
            0x3E3F52
        case .remuxLight:
            0xD2D4DC
        }
    }
}

struct TerminalSettings: Equatable, Codable, Sendable {
    static let minimumFontSize: Float32 = 8
    static let maximumFontSize: Float32 = 24
    static let defaultExplicitFontSize: Float32 = 10
    static let `default` = TerminalSettings(fontSize: nil, theme: .ghosttyDefault)

    var fontSize: Float32?
    var theme: TerminalTheme

    /// Opt-in to the legacy `ssh-rsa` host-key algorithm, which uses SHA-1
    /// signatures.
    /// Defaults to `false` when absent from persisted settings.
    var allowInsecureRSAHostKeys: Bool

    /// The zoom state applied to multipane windows when a Remux session starts
    /// or this global preference changes.
    var zoomMultipaneWindowsByDefault: Bool

    init(
        fontSize: Float32?,
        theme: TerminalTheme,
        allowInsecureRSAHostKeys: Bool = false,
        zoomMultipaneWindowsByDefault: Bool = false
    ) {
        self.fontSize = Self.normalizedFontSize(fontSize)
        self.theme = theme
        self.allowInsecureRSAHostKeys = allowInsecureRSAHostKeys
        self.zoomMultipaneWindowsByDefault = zoomMultipaneWindowsByDefault
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize
        case theme
        case allowInsecureRSAHostKeys
        case zoomMultipaneWindowsByDefault
    }

    // Custom decoding keeps older persisted settings (written before these keys
    // existed) loadable rather than failing the whole store on a missing key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontSize: try container.decodeIfPresent(Float32.self, forKey: .fontSize),
            theme: try container.decodeIfPresent(TerminalTheme.self, forKey: .theme) ?? .ghosttyDefault,
            allowInsecureRSAHostKeys: try container.decodeIfPresent(Bool.self, forKey: .allowInsecureRSAHostKeys) ?? false,
            zoomMultipaneWindowsByDefault: try container.decodeIfPresent(
                Bool.self,
                forKey: .zoomMultipaneWindowsByDefault
            ) ?? decoder.userInfo[.terminalSettingsDefaultMultipaneZoom] as? Bool ?? false
        )
    }

    func hasSameTerminalAppearance(as other: TerminalSettings) -> Bool {
        fontSize == other.fontSize && theme == other.theme
    }

    var ghosttyConfigContents: String? {
        ghosttyConfigContents(effectiveFontSize: nil)
    }

    func ghosttyConfigContents(effectiveFontSize: Float32?) -> String? {
        var lines = theme.ghosttyConfigLines
        if let effectiveFontSize = effectiveFontSize ?? fontSize {
            lines.append("font-size = \(Self.configString(for: effectiveFontSize))")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalizedFontSize(_ value: Float32?) -> Float32? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, minimumFontSize), maximumFontSize)
    }

    private static func configString(for value: Float32) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.2f", value)
    }
}

extension CodingUserInfoKey {
    static let terminalSettingsDefaultMultipaneZoom = CodingUserInfoKey(
        rawValue: "terminalSettingsDefaultMultipaneZoom"
    )!
}
