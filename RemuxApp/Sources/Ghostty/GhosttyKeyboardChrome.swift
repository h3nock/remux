import SwiftUI

enum GhosttyKeyboardChromeMode: Equatable {
    case hidden
    case system

    var enablesSystemKeyboard: Bool {
        self == .system
    }

    func toggledKeyboard() -> Self {
        switch self {
        case .hidden:
            .system
        case .system:
            .hidden
        }
    }

    func applyingSystemKeyboardVisibility(_ isVisible: Bool) -> Self {
        if isVisible, self == .hidden {
            return .system
        }

        if !isVisible, self == .system {
            return .hidden
        }

        return self
    }
}

enum GhosttyKeyboardChromeSizing {
    static let dockButtonHeight: CGFloat = 38
    static let dockButtonWidth: CGFloat = 38
    static let compactDockButtonWidth: CGFloat = 35
    static let controlGroupVerticalPadding: CGFloat = 4

    /// Fallback reservation before the bottom chrome reports its intrinsic
    /// height. Settled chrome subsequently owns its full measured footprint.
    static let baselineHeight = dockButtonHeight + (controlGroupVerticalPadding * 2)

    static func keyboardReplacementHeight(
        keyboardOverlapHeight: CGFloat,
        bottomSafeAreaHeight: CGFloat
    ) -> CGFloat {
        guard keyboardOverlapHeight.isFinite, keyboardOverlapHeight > 0 else {
            return 0
        }
        let safeAreaHeight = bottomSafeAreaHeight.isFinite ? max(0, bottomSafeAreaHeight) : 0
        return ceil(max(0, keyboardOverlapHeight - safeAreaHeight))
    }
}

struct GhosttyBottomChromeReservation: Equatable {
    private(set) var settledHeight: CGFloat = 0

    func layoutHeight(fallback: CGFloat) -> CGFloat {
        settledHeight > 0 ? settledHeight : fallback
    }

    @discardableResult
    mutating func observe(renderedHeight: CGFloat, isTransient: Bool) -> Bool {
        guard !isTransient,
              renderedHeight.isFinite,
              renderedHeight > 0 else { return false }

        let normalizedHeight = ceil(renderedHeight)
        guard settledHeight != normalizedHeight else { return false }
        settledHeight = normalizedHeight
        return true
    }
}

struct GhosttyTerminalChromeStyle {
    let accent: Color
    let accentForeground: Color

    var toolbarButtonActiveFill: Color {
        accent.opacity(0.16)
    }

    var selectedFill: Color {
        accent.opacity(0.18)
    }

    var selectedStroke: Color {
        accent.opacity(0.76)
    }

    static let ghosttyDefault = GhosttyTerminalChromeStyle(
        accent: Color(uiColor: .ghosttyDefaultTerminalChromeAccent),
        accentForeground: Color(uiColor: .terminalChromeAccentForegroundForDarkAccent)
    )

    static let catppuccinMocha = GhosttyTerminalChromeStyle(
        accent: Color(uiColor: .catppuccinMochaTerminalChromeAccent),
        accentForeground: Color(uiColor: .terminalChromeAccentForegroundForDarkAccent)
    )

    static let catppuccinLatte = GhosttyTerminalChromeStyle(
        accent: Color(uiColor: .catppuccinLatteTerminalChromeAccent),
        accentForeground: Color(uiColor: .terminalChromeAccentForegroundForLightAccent)
    )
}

private struct GhosttyTerminalChromeStyleKey: EnvironmentKey {
    static let defaultValue = GhosttyTerminalChromeStyle.ghosttyDefault
}

extension EnvironmentValues {
    var ghosttyTerminalChromeStyle: GhosttyTerminalChromeStyle {
        get { self[GhosttyTerminalChromeStyleKey.self] }
        set { self[GhosttyTerminalChromeStyleKey.self] = newValue }
    }
}

extension TerminalTheme {
    var terminalChromeStyle: GhosttyTerminalChromeStyle {
        switch self {
        case .ghosttyDefault:
            .ghosttyDefault
        case .remuxDark:
            .catppuccinMocha
        case .remuxLight:
            .catppuccinLatte
        }
    }
}

enum GhosttyKeyboardChromeAnimation {
    static let composerTransition = Animation.spring(
        response: 0.34,
        dampingFraction: 0.88,
        blendDuration: 0
    )
}

struct GhosttyKeyboardChrome<ComposerContent: View>: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let keyboardMode: GhosttyKeyboardChromeMode
    let isEnabled: Bool
    let isInteractionLocked: Bool
    let isCompact: Bool
    let isControlArmed: Bool
    let selectedWindowIndex: Int?
    let windowCount: Int
    let paneCount: Int
    let isComposerPresented: Bool
    let onShowSessions: () -> Void
    let onShowLibrary: () -> Void
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let onOpenComposer: () -> Void
    let onToggleKeyboard: () -> Void
    let onToggleControl: () -> Void
    let onShowShortcuts: () -> Void
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool
    let composerContent: () -> ComposerContent

    var body: some View {
        selectorRow
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { Haptic.prewarmChromeFeedback() }
    }

    @ViewBuilder
    private var selectorRow: some View {
        if isComposerPresented {
            composerSelectorRow
        } else {
            standardSelectorRowContainer
        }
    }

    @ViewBuilder
    private var standardSelectorRowContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: isCompact ? 6 : 10) {
                standardSelectorRow
            }
        } else {
            standardSelectorRow
        }
    }

    private var standardSelectorRow: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            terminalKeyControls
            navigationControls
            inputControls
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var composerSelectorRow: some View {
        composerContent()
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }

    private var navigationControls: some View {
        controlGroup {
            HStack(spacing: isCompact ? 1 : 2) {
                GhosttyKeyboardChromeDockButton(
                    systemName: "rectangle.stack",
                    badge: nil,
                    chromeStyle: chromeStyle,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: "Sessions",
                    accessibilityHint: "Switch active sessions, resume recent sessions, or create a new session.",
                    accessibilityIdentifier: "terminal.sessions",
                    isActive: false,
                    isEnabled: !isInteractionLocked,
                    action: onShowSessions
                )

                GhosttyKeyboardChromeDockButton(
                    systemName: "rectangle.on.rectangle",
                    badge: windowBadge,
                    chromeStyle: chromeStyle,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: windowAccessibilityLabel,
                    accessibilityHint: windowDetail,
                    accessibilityIdentifier: "terminal.windows",
                    isActive: false,
                    isEnabled: isEnabled && !isInteractionLocked && windowCount > 0,
                    action: onShowWindows
                )

                GhosttyKeyboardChromeDockButton(
                    systemName: "square.split.2x1",
                    badge: paneBadge,
                    chromeStyle: chromeStyle,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: paneAccessibilityLabel,
                    accessibilityHint: paneDetail,
                    accessibilityIdentifier: "terminal.panes",
                    isActive: false,
                    isEnabled: isEnabled && !isInteractionLocked && paneCount > 0,
                    action: onShowPanes
                )
            }
        }
    }

    private var terminalKeyControls: some View {
        controlGroup {
            HStack(spacing: isCompact ? 1 : 2) {
                accessoryKey(
                    title: "ctrl",
                    accessibilityIdentifier: "terminal.ctrl",
                    isActive: isControlArmed,
                    onLongPress: onShowShortcuts
                ) {
                    onToggleControl()
                    return true
                }
                accessoryKey(title: "esc", accessibilityIdentifier: "terminal.esc") {
                    sendKey(.init(keyCode: .escape))
                }
                accessoryKey(title: "tab", accessibilityIdentifier: "terminal.tab") {
                    sendKey(.init(keyCode: .tab))
                }
            }
        }
    }

    private var inputControls: some View {
        controlGroup {
            HStack(spacing: isCompact ? 1 : 2) {
                GhosttyKeyboardChromeDockButton(
                    systemName: "house",
                    badge: nil,
                    chromeStyle: chromeStyle,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: "Home",
                    accessibilityHint: "Open the Remux library.",
                    accessibilityIdentifier: "terminal.home",
                    isActive: false,
                    isEnabled: !isInteractionLocked,
                    action: onShowLibrary
                )

                composerButton
                keyboardToggleButton
            }
        }
    }

    private var composerButton: some View {
        GhosttyKeyboardChromeDockButton(
            systemName: "square.and.pencil",
            badge: nil,
            chromeStyle: chromeStyle,
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            accessibilityLabel: "Open composer",
            accessibilityHint: "Prepare an editable message before sending it to the terminal.",
            accessibilityIdentifier: "terminal.composer.toggle",
            isActive: false,
            isEnabled: !isInteractionLocked,
            action: onOpenComposer
        )
    }

    private var keyboardToggleButton: some View {
        GhosttyKeyboardChromeDockButton(
            systemName: "keyboard",
            badge: nil,
            chromeStyle: chromeStyle,
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            accessibilityLabel: keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
            accessibilityHint: nil,
            accessibilityIdentifier: "terminal.keyboard",
            isActive: keyboardMode != .hidden,
            isEnabled: isEnabled,
            action: onToggleKeyboard
        )
    }

    private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, isCompact ? 3 : 5)
            .padding(.vertical, GhosttyKeyboardChromeSizing.controlGroupVerticalPadding)
            .ghosttyToolbarGroupSurface()
    }

    private func accessoryKey(
        title: String,
        accessibilityIdentifier: String,
        isActive: Bool = false,
        onLongPress: (() -> Void)? = nil,
        action: @escaping () -> Bool
    ) -> some View {
        GhosttyKeyboardKeyButton(
            title: title,
            accessibilityIdentifier: accessibilityIdentifier,
            chromeStyle: chromeStyle,
            fontSize: 12,
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            isActive: isActive,
            isEnabled: isEnabled && !isInteractionLocked,
            onLongPress: onLongPress,
            action: action
        )
    }

    private var dockButtonWidth: CGFloat {
        isCompact
            ? GhosttyKeyboardChromeSizing.compactDockButtonWidth
            : GhosttyKeyboardChromeSizing.dockButtonWidth
    }

    private var windowDetail: String? {
        windowCount > 1 ? "switch or create" : "create"
    }

    private var windowAccessibilityLabel: String {
        guard windowCount > 0 else { return "Windows" }
        return "Window \(displayIndex(selectedWindowIndex, count: windowCount)) of \(windowCount)"
    }

    private var windowBadge: String? {
        guard windowCount > 1 else { return nil }
        return "\(displayIndex(selectedWindowIndex, count: windowCount))"
    }

    private var paneDetail: String? {
        paneCount > 1 ? "switch or split" : "split or stack"
    }

    private var paneBadge: String? {
        guard paneCount > 1 else { return nil }
        return paneCount < 100 ? "\(paneCount)" : "99+"
    }

    private var paneAccessibilityLabel: String {
        guard paneCount > 0 else { return "Panes" }
        return "Panes, \(paneCount) \(paneCount == 1 ? "pane" : "panes")"
    }

    private func displayIndex(_ index: Int?, count: Int) -> Int {
        min(max((index ?? 0) + 1, 1), max(count, 1))
    }
}

private struct GhosttyKeyboardChromeDockButton: View {
    let systemName: String
    let badge: String?
    let chromeStyle: GhosttyTerminalChromeStyle
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String
    let accessibilityHint: String?
    let accessibilityIdentifier: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 16.5, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .contentTransition(.symbolEffect(.replace))

                if let badge {
                    dockBadge(badge)
                }
            }
        }
        .buttonStyle(GhosttyChromeDockButtonStyle(
            isActive: isActive,
            isEnabled: isEnabled,
            chromeStyle: chromeStyle,
            width: width,
            height: height
        ))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func dockBadge(_ value: String) -> some View {
        let horizontalPadding: CGFloat = value.count > 1 ? 3 : 0

        return Text(value)
            .font(.system(size: 8, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(chromeStyle.accentForeground)
            .frame(minWidth: 12.5, minHeight: 12.5)
            .padding(.horizontal, horizontalPadding)
            .background(chromeStyle.accent.opacity(0.88), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 4)
            .padding(.trailing, 4)
    }
}

private struct GhosttyKeyboardKeyButton: View {
    let title: String
    let accessibilityIdentifier: String
    let chromeStyle: GhosttyTerminalChromeStyle
    var fontSize: CGFloat = 13
    var width: CGFloat = GhosttyKeyboardChromeSizing.dockButtonWidth
    var height: CGFloat = GhosttyKeyboardChromeSizing.dockButtonHeight
    var isActive = false
    let isEnabled: Bool
    var onLongPress: (() -> Void)?
    let action: () -> Bool

    @State private var isPressed = false
    @State private var didLongPress = false

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isActive ? chromeStyle.accent : GhosttyPhoneChromePalette.chromeForeground)
            .frame(width: width, height: height)
            .ghosttyToolbarButtonSurface(
                isActive: isActive,
                isPressed: isPressed,
                isEnabled: isEnabled,
                chromeStyle: chromeStyle
            )
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                guard isEnabled else { return }
                isPressed = false
                if didLongPress {
                    didLongPress = false
                    return
                }
                _ = action()
            }
            .onLongPressGesture(
                minimumDuration: 0.5,
                maximumDistance: 18,
                pressing: { pressing in
                    guard isEnabled else { return }
                    if pressing, !isPressed {
                        Haptic.keyboardPress()
                    }
                    isPressed = pressing
                },
                perform: {
                    guard let onLongPress else { return }
                    didLongPress = true
                    Haptic.tap(.medium)
                    onLongPress()
                }
            )
    }
}

/// Shared press primitive for dock buttons. Owns the press scale,
/// disabled opacity, and rising-edge feedback dispatch.
private struct GhosttyChromePressBody<Content: View>: View {
    let isPressed: Bool
    let isEnabled: Bool
    let onPressDown: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var lastPressed = false

    var body: some View {
        content()
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onChange(of: isPressed) { _, nowPressed in
                let wasPressed = lastPressed
                lastPressed = nowPressed
                guard isEnabled, nowPressed, !wasPressed else { return }
                onPressDown()
            }
    }
}

private struct GhosttyChromeDockButtonStyle: ButtonStyle {
    let isActive: Bool
    let isEnabled: Bool
    let chromeStyle: GhosttyTerminalChromeStyle
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GhosttyChromePressBody(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            onPressDown: { Haptic.chromeControlPress() }
        ) {
            configuration.label
                .foregroundStyle(isActive ? chromeStyle.accent : GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: width, height: height)
                .ghosttyToolbarButtonSurface(
                    isActive: isActive,
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled,
                    chromeStyle: chromeStyle
                )
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    @ViewBuilder
    func ghosttyToolbarGroupSurface() -> some View {
        ghosttyToolbarSurface(in: Capsule())
    }

    @ViewBuilder
    private func ghosttyToolbarSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyPhoneChromePalette.toolbarGlassTint)
                        .interactive(),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarGlassStroke,
                        lineWidth: 0.75
                    )
                }
                .shadow(color: GhosttyPhoneChromePalette.toolbarGlassShadow, radius: 13, y: 7)
        } else {
            self
                .background(GhosttyPhoneChromePalette.toolbarFallbackFill, in: shape)
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarStroke,
                        lineWidth: 1
                    )
                }
                .shadow(color: GhosttyPhoneChromePalette.toolbarShadow, radius: 8, y: 4)
        }
    }

    @ViewBuilder
    func ghosttyToolbarButtonSurface(
        isActive: Bool,
        isPressed: Bool,
        isEnabled: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        let shape = Circle()

        if #available(iOS 26.0, *) {
            self
                .background(isActive ? chromeStyle.toolbarButtonActiveFill : Color.clear, in: shape)
                .overlay {
                    shape.fill(isPressed && isEnabled ? GhosttyPhoneChromePalette.toolbarButtonPressedFill : Color.clear)
                }
        } else {
            let activeFill = isActive ? chromeStyle.toolbarButtonActiveFill : Color.clear
            let pressedFill = isPressed && isEnabled ? GhosttyPhoneChromePalette.toolbarButtonPressedFill : Color.clear

            self
                .background(activeFill, in: shape)
                .overlay {
                    shape.fill(pressedFill)
                }
        }
    }
}

enum GhosttyPhoneChromePalette {
    static let screenBackground = Color(red: 0.18, green: 0.20, blue: 0.24)
    static let tray = screenBackground
    static let dock = Color(red: 0.15, green: 0.16, blue: 0.20)
    static let groupSurface = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let pill = Color(red: 0.23, green: 0.25, blue: 0.30)
    static let keySurface = Color(red: 0.22, green: 0.24, blue: 0.30)
    static let keySurfacePressed = Color(red: 0.30, green: 0.32, blue: 0.39)
    static let keySurfaceActivePressedOverlay = Color.black.opacity(0.12)
    static let chromeControlPressedOverlay = Color.white.opacity(0.10)
    static let chromeForeground = Color.primary.opacity(0.84)
    static let chromeSecondaryForeground = Color.secondary.opacity(0.78)
    static let toolbarGlassTint = Color.primary.opacity(0.065)
    static let toolbarGlassStroke = Color.primary.opacity(0.16)
    static let toolbarGlassShadow = Color.black.opacity(0.16)
    static let toolbarFallbackFill = Color(uiColor: .secondarySystemBackground).opacity(0.88)
    static let toolbarStroke = Color.primary.opacity(0.12)
    static let toolbarShadow = Color.black.opacity(0.18)
    static let toolbarButtonPressedFill = Color.primary.opacity(0.08)

    static let uiBackground = UIColor(
        red: 0.18,
        green: 0.20,
        blue: 0.24,
        alpha: 1.0
    )
}

private extension UIColor {
    static let ghosttyDefaultTerminalChromeAccent = UIColor(red: 0.38, green: 0.69, blue: 0.94, alpha: 1.0)
    static let catppuccinMochaTerminalChromeAccent = UIColor(red: 0.54, green: 0.71, blue: 0.98, alpha: 1.0)
    static let catppuccinLatteTerminalChromeAccent = UIColor(red: 0.12, green: 0.40, blue: 0.96, alpha: 1.0)
    static let terminalChromeAccentForegroundForDarkAccent = UIColor.black.withAlphaComponent(0.74)
    static let terminalChromeAccentForegroundForLightAccent = UIColor.white
}

extension View {
    @ViewBuilder
    func ghosttyTerminalChromePresentation(
        _ colorScheme: ColorScheme? = nil,
        chromeStyle: GhosttyTerminalChromeStyle? = nil
    ) -> some View {
        if let colorScheme, let chromeStyle {
            preferredColorScheme(colorScheme)
                .environment(\.ghosttyTerminalChromeStyle, chromeStyle)
        } else if let colorScheme {
            preferredColorScheme(colorScheme)
        } else if let chromeStyle {
            environment(\.ghosttyTerminalChromeStyle, chromeStyle)
        } else {
            self
        }
    }
}
