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
                // Palette inline: the app bundles no Ghostty theme resources
                // for "theme = …" to resolve against.
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

    /// Whether the theme is light, as a terminal tells programs its colour scheme.
    var isLight: Bool {
        switch self {
        case .ghosttyDefault, .remuxDark:
            false
        case .remuxLight:
            true
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

enum TerminalToolbarKey: String, CaseIterable, Codable, Sendable {
    case control
    case shift
    case alt
    case escape
    case tab
    case shiftTab
    case enter
    case backspace
    case delete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown

    /// Control, Shift and Alt, which apply to the next key instead of sending anything.
    static let modifierKeys = allCases.filter { $0.modifier != nil }
    /// The keys that send themselves.
    static let sendingKeys = allCases.filter { $0.modifier == nil }

    var settingsTitle: String {
        switch self {
        case .control:
            "Control"
        case .shift:
            "Shift"
        case .alt:
            "Alt"
        case .escape:
            "Escape"
        case .tab:
            "Tab"
        case .shiftTab:
            "Shift-Tab"
        case .enter:
            "Enter"
        case .backspace:
            "Backspace"
        case .delete:
            "Delete"
        case .arrowUp:
            "Up Arrow"
        case .arrowDown:
            "Down Arrow"
        case .arrowLeft:
            "Left Arrow"
        case .arrowRight:
            "Right Arrow"
        case .home:
            "Home"
        case .end:
            "End"
        case .pageUp:
            "Page Up"
        case .pageDown:
            "Page Down"
        }
    }

    var toolbarTitle: String {
        switch self {
        case .control:
            "ctrl"
        case .shift:
            "shift"
        case .alt:
            "alt"
        case .escape:
            "esc"
        case .tab:
            "tab"
        case .shiftTab:
            "⇧tab"
        case .enter:
            "enter"
        case .backspace:
            "⌫"
        case .delete:
            "del"
        case .arrowUp:
            "↑"
        case .arrowDown:
            "↓"
        case .arrowLeft:
            "←"
        case .arrowRight:
            "→"
        case .home:
            "home"
        case .end:
            "end"
        case .pageUp:
            "pgup"
        case .pageDown:
            "pgdn"
        }
    }

    /// The modifier this key arms for the next key, or nil for a key that sends itself.
    var modifier: ShortcutModifiers? {
        switch self {
        case .control:
            .control
        case .shift:
            .shift
        case .alt:
            .option
        default:
            nil
        }
    }

    /// The key this sends, or nil for a modifier.
    var shortcutKey: ShortcutKey? {
        switch self {
        case .control, .shift, .alt:
            nil
        case .shiftTab:
            .tab
        default:
            ShortcutKey(rawValue: rawValue)
        }
    }

    /// The modifiers this key always sends with `shortcutKey`.
    var shortcutModifiers: ShortcutModifiers {
        self == .shiftTab ? .shift : []
    }
}

/// Three toolbar keys shown together.
struct TerminalToolbarKeyPage: Equatable, Codable, Sendable {
    var first: TerminalToolbarKey
    var second: TerminalToolbarKey
    var third: TerminalToolbarKey

    var values: [TerminalToolbarKey] {
        [first, second, third]
    }

    var summary: String {
        values.map(\.settingsTitle).joined(separator: ", ")
    }

    var compactSummary: String {
        values.map(\.toolbarTitle).joined(separator: " · ")
    }
}

/// The toolbar's key pages, swiped through three keys at a time. Never empty.
struct TerminalToolbarKeys: Equatable, Codable, Sendable {
    /// The second page answers a program's prompt or menu with the keyboard down; it sits next to Escape because
    /// answering is pressed more often than the third page's keys.
    static let `default` = Self(pages: [
        TerminalToolbarKeyPage(first: .control, second: .escape, third: .tab),
        TerminalToolbarKeyPage(first: .enter, second: .arrowUp, third: .arrowDown),
        TerminalToolbarKeyPage(first: .shiftTab, second: .shift, third: .alt),
    ])

    private(set) var pages: [TerminalToolbarKeyPage]

    init(pages: [TerminalToolbarKeyPage]) {
        self.pages = pages.isEmpty ? Self.default.pages : pages
    }

    /// A single page.
    init(first: TerminalToolbarKey, second: TerminalToolbarKey, third: TerminalToolbarKey) {
        self.init(pages: [TerminalToolbarKeyPage(first: first, second: second, third: third)])
    }

    subscript(page index: Int) -> TerminalToolbarKeyPage {
        get { pages[index] }
        set { pages[index] = newValue }
    }

    /// Every key, page by page.
    var values: [TerminalToolbarKey] {
        pages.flatMap(\.values)
    }

    var summary: String {
        guard pages.count > 1 else { return pages[0].summary }
        return pages.enumerated()
            .map { "Page \($0.offset + 1): \($0.element.summary)" }
            .joined(separator: ". ")
    }

    /// The first page, which the toolbar shows until it is swiped.
    var compactSummary: String {
        pages[0].compactSummary
    }

    /// The modifiers some key on the toolbar can arm.
    var modifiers: ShortcutModifiers {
        values.reduce(into: []) { modifiers, key in
            if let modifier = key.modifier {
                modifiers.formUnion(modifier)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pages
    }

    /// Settings from before pages hold one page's three keys; they keep those keys as the first page
    /// and gain the default's other pages. A page with a key this build doesn't know is left out, so a
    /// newer build's settings still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pages) {
            let pages = try container.decode([DecodedPage].self, forKey: .pages).compactMap(\.page)
            self.init(pages: pages)
        } else {
            self.init(pages: [try TerminalToolbarKeyPage(from: decoder)] + Self.default.pages.dropFirst())
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pages, forKey: .pages)
    }

    private struct DecodedPage: Decodable {
        let page: TerminalToolbarKeyPage?

        init(from decoder: Decoder) throws {
            page = try? TerminalToolbarKeyPage(from: decoder)
        }
    }
}

struct TerminalSettings: Equatable, Codable, Sendable {
    static let minimumFontSize: Float32 = 5
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

    /// The configurable key pages shown on the leading side of the terminal
    /// toolbar. The first key of each page owns the long-press shortcut-palette gesture.
    var toolbarKeys: TerminalToolbarKeys

    /// Vibrate when a program rings the bell, or an agent needs the user or finishes.
    var vibratesForBellsAndAgents: Bool

    /// Vibrate when the user presses toolbar keys and Remux's buttons.
    var vibratesForKeysAndButtons: Bool

    init(
        fontSize: Float32?,
        theme: TerminalTheme,
        allowInsecureRSAHostKeys: Bool = false,
        zoomMultipaneWindowsByDefault: Bool = false,
        toolbarKeys: TerminalToolbarKeys = .default,
        vibratesForBellsAndAgents: Bool = true,
        vibratesForKeysAndButtons: Bool = true
    ) {
        self.fontSize = Self.normalizedFontSize(fontSize)
        self.theme = theme
        self.allowInsecureRSAHostKeys = allowInsecureRSAHostKeys
        self.zoomMultipaneWindowsByDefault = zoomMultipaneWindowsByDefault
        self.toolbarKeys = toolbarKeys
        self.vibratesForBellsAndAgents = vibratesForBellsAndAgents
        self.vibratesForKeysAndButtons = vibratesForKeysAndButtons
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize
        case theme
        case allowInsecureRSAHostKeys
        case zoomMultipaneWindowsByDefault
        case toolbarKeys
        case vibratesForBellsAndAgents
        case vibratesForKeysAndButtons
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
            ) ?? decoder.userInfo[.terminalSettingsDefaultMultipaneZoom] as? Bool ?? false,
            toolbarKeys: try container.decodeIfPresent(
                TerminalToolbarKeys.self,
                forKey: .toolbarKeys
            ) ?? .default,
            vibratesForBellsAndAgents: try container.decodeIfPresent(
                Bool.self,
                forKey: .vibratesForBellsAndAgents
            ) ?? true,
            vibratesForKeysAndButtons: try container.decodeIfPresent(
                Bool.self,
                forKey: .vibratesForKeysAndButtons
            ) ?? true
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
