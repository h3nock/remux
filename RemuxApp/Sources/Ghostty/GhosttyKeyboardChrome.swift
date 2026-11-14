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

enum GhosttyKeyboardChromeAnimation {
    static let composerTransition = Animation.spring(
        response: 0.34,
        dampingFraction: 0.88,
        blendDuration: 0
    )
}

struct GhosttyKeyboardChrome<ComposerContent: View>: View {
    let keyboardMode: GhosttyKeyboardChromeMode
    let isEnabled: Bool
    let isInteractionLocked: Bool
    let isCompact: Bool
    let isControlArmed: Bool
    let toolbarKeys: TerminalToolbarKeys
    let topLevelNoun: GhosttyTopLevelNoun
    let selectedWindowIndex: Int?
    let windowCount: Int
    let paneCount: Int
    /// A popup holds the tab on screen: its tabs and panes are inert until it closes, as Herdr's client
    /// keeps its tab bar visible but inert under a popup.
    let isNavigationHeldByPopup: Bool
    let isComposerPresented: Bool
    let onShowSessions: () -> Void
    let onShowLibrary: () -> Void
    /// The state of the agents waiting out of sight, which the Home button's dot shows. Read as the toolbar
    /// is drawn, so the dot follows both the agents and the tab on screen.
    var waitingAgentStatus: () -> TerminalAgentStatus? = { nil }
    let onShowWindows: () -> Void
    let onShowPanes: () -> Void
    let onOpenComposer: () -> Void
    let onToggleKeyboard: () -> Void
    let onToggleControl: () -> Void
    let onShowShortcuts: () -> Void
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool
    let composerContent: () -> ComposerContent
    var allowsTerminalKeys = true

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
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: "Sessions",
                    accessibilityHint: "Switch active sessions, resume recent or available sessions, or create a new session.",
                    accessibilityIdentifier: "terminal.sessions",
                    isEnabled: !isInteractionLocked,
                    action: onShowSessions
                )

                GhosttyKeyboardChromeDockButton(
                    systemName: "rectangle.on.rectangle",
                    badge: windowBadge,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: windowAccessibilityLabel,
                    accessibilityHint: navigation.tabsHint,
                    accessibilityIdentifier: "terminal.windows",
                    isEnabled: navigation.isTabsEnabled,
                    action: onShowWindows
                )

                GhosttyKeyboardChromeDockButton(
                    systemName: "square.split.2x1",
                    badge: paneBadge,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: paneAccessibilityLabel,
                    accessibilityHint: navigation.panesHint,
                    accessibilityIdentifier: "terminal.panes",
                    isEnabled: navigation.isPanesEnabled,
                    action: onShowPanes
                )
            }
        }
    }

    private var terminalKeyControls: some View {
        controlGroup {
            HStack(spacing: isCompact ? 1 : 2) {
                ForEach(Array(toolbarKeys.values.enumerated()), id: \.offset) { index, key in
                    accessoryKey(
                        title: key.toolbarTitle,
                        accessibilityLabel: key.settingsTitle,
                        accessibilityHint: toolbarKeyAccessibilityHint(key),
                        accessibilityIdentifier: "terminal.toolbar-key.\(index)",
                        accessibilityValue: key == .control && isControlArmed ? "Armed" : nil,
                        isArmed: key == .control && isControlArmed,
                        onLongPress: index == 0 ? onShowShortcuts : nil
                    ) {
                        activateToolbarKey(key)
                    }
                }
            }
        }
    }

    private var inputControls: some View {
        controlGroup {
            HStack(spacing: isCompact ? 1 : 2) {
                let waiting = waitingAgentStatus()
                GhosttyKeyboardChromeDockButton(
                    systemName: "house",
                    badge: nil,
                    dot: waiting,
                    width: dockButtonWidth,
                    height: GhosttyKeyboardChromeSizing.dockButtonHeight,
                    accessibilityLabel: "Home",
                    accessibilityValue: waiting.map { "An agent is \($0.word)" },
                    accessibilityHint: "Open the Remux library.",
                    accessibilityIdentifier: "terminal.home",
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
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            accessibilityLabel: "Open composer",
            accessibilityHint: "Prepare an editable message before sending it to the terminal.",
            accessibilityIdentifier: "terminal.composer.toggle",
            isEnabled: !isInteractionLocked,
            action: onOpenComposer
        )
    }

    /// The icon shows what a tap does, using iOS's own hide-keyboard symbol while the keyboard is up. The active fill
    /// stays with armed keys such as Control, so an open keyboard doesn't light the toolbar.
    private var keyboardToggleButton: some View {
        GhosttyKeyboardChromeDockButton(
            systemName: keyboardMode == .hidden ? "keyboard" : "keyboard.chevron.compact.down",
            badge: nil,
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            accessibilityLabel: keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
            accessibilityHint: nil,
            accessibilityIdentifier: "terminal.keyboard",
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
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil,
        isArmed: Bool = false,
        onLongPress: (() -> Void)? = nil,
        action: @escaping () -> Bool
    ) -> some View {
        GhosttyKeyboardKeyButton(
            title: title,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: accessibilityHint,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityValue: accessibilityValue,
            fontSize: 12,
            width: dockButtonWidth,
            height: GhosttyKeyboardChromeSizing.dockButtonHeight,
            isArmed: isArmed,
            isEnabled: isEnabled && allowsTerminalKeys && !isInteractionLocked,
            onLongPress: onLongPress,
            action: action
        )
    }

    private func activateToolbarKey(_ key: TerminalToolbarKey) -> Bool {
        if key == .control {
            onToggleControl()
            return true
        }

        guard let keyCode = key.shortcutKey?.ghosttyKeyCode else { return false }
        return sendKey(.init(keyCode: keyCode))
    }

    private func toolbarKeyAccessibilityHint(_ key: TerminalToolbarKey) -> String {
        if key == .control {
            return "Arms Control for the next terminal input."
        }
        return "Sends \(key.settingsTitle) to the terminal."
    }

    private var dockButtonWidth: CGFloat {
        isCompact
            ? GhosttyKeyboardChromeSizing.compactDockButtonWidth
            : GhosttyKeyboardChromeSizing.dockButtonWidth
    }

    private var navigation: GhosttyKeyboardChromeNavigation {
        GhosttyKeyboardChromeNavigation(
            isEnabled: isEnabled && !isInteractionLocked,
            isHeldByPopup: isNavigationHeldByPopup,
            windowCount: windowCount,
            paneCount: paneCount
        )
    }

    private var windowAccessibilityLabel: String {
        guard windowCount > 0 else { return topLevelNoun.plural }
        return "\(topLevelNoun.singular) \(displayIndex(selectedWindowIndex, count: windowCount)) of \(windowCount)"
    }

    private var windowBadge: String? {
        guard windowCount > 1 else { return nil }
        return "\(displayIndex(selectedWindowIndex, count: windowCount))"
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

/// Whether the toolbar's Tabs and Panes buttons work, and what each says it does.
struct GhosttyKeyboardChromeNavigation: Equatable {
    let isTabsEnabled: Bool
    let isPanesEnabled: Bool
    let tabsHint: String
    let panesHint: String

    static let heldByPopupHint = "Unavailable while a popup is open."

    /// `isEnabled`: the terminal takes input and nothing holds the chrome. A popup over the tab holds both
    /// buttons, which stay visible, dimmed and say why.
    init(isEnabled: Bool, isHeldByPopup: Bool, windowCount: Int, paneCount: Int) {
        isTabsEnabled = isEnabled && !isHeldByPopup && windowCount > 0
        isPanesEnabled = isEnabled && !isHeldByPopup && paneCount > 0
        tabsHint = isHeldByPopup ? Self.heldByPopupHint : windowCount > 1 ? "switch or create" : "create"
        panesHint = isHeldByPopup ? Self.heldByPopupHint : paneCount > 1 ? "switch or split" : "split or stack"
    }
}

private struct GhosttyKeyboardChromeDockButton: View {
    /// The dot is the size of the agent dot on a tab's tile, in the place of a button's count.
    private static let dotDiameter: CGFloat = 7
    private static let dotBox: CGFloat = 12.5
    /// What is cut from the symbol around the dot, so the two don't touch.
    private static let dotClearance: CGFloat = 1.5

    let systemName: String
    let badge: String?
    /// An agent's state, shown as its dot where a count would be.
    var dot: TerminalAgentStatus?
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String
    var accessibilityValue: String?
    let accessibilityHint: String?
    let accessibilityIdentifier: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ZStack {
                    Image(systemName: systemName)
                        .font(.system(size: 16.5, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .contentTransition(.symbolEffect(.replace))

                    if dot != nil {
                        Circle()
                            .frame(
                                width: Self.dotDiameter + 2 * Self.dotClearance,
                                height: Self.dotDiameter + 2 * Self.dotClearance
                            )
                            .dockCorner(box: Self.dotBox)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()

                if let badge {
                    dockBadge(badge)
                }
                if let dot {
                    TerminalAgentDot(status: dot, size: Self.dotDiameter)
                        .dockCorner(box: Self.dotBox)
                }
            }
        }
        .buttonStyle(GhosttyChromeDockButtonStyle(
            isEnabled: isEnabled,
            width: width,
            height: height
        ))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func dockBadge(_ value: String) -> some View {
        let horizontalPadding: CGFloat = value.count > 1 ? 3 : 0

        return Text(value)
            .font(.system(size: 8, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(RemuxAccent.onFill)
            .frame(minWidth: 12.5, minHeight: 12.5)
            .padding(.horizontal, horizontalPadding)
            .background(RemuxAccent.fill.opacity(0.88), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 4)
            .padding(.trailing, 4)
    }
}

private extension View {
    /// Centres the view where a dock button's count sits: in a box of `box` points, 4 points in from the
    /// button's top and trailing edges.
    func dockCorner(box: CGFloat) -> some View {
        frame(width: box, height: box)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 4)
            .padding(.trailing, 4)
    }
}

private struct GhosttyKeyboardKeyButton: View {
    let title: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let accessibilityIdentifier: String
    let accessibilityValue: String?
    var fontSize: CGFloat = 13
    var width: CGFloat = GhosttyKeyboardChromeSizing.dockButtonWidth
    var height: CGFloat = GhosttyKeyboardChromeSizing.dockButtonHeight
    var isArmed = false
    let isEnabled: Bool
    var onLongPress: (() -> Void)?
    let action: () -> Bool

    @State private var isPressed = false

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isArmed ? GhosttyPhoneChromePalette.armedKeyLabel : GhosttyPhoneChromePalette.chromeForeground)
            .frame(width: width, height: height)
            .background {
                if isArmed {
                    Circle().fill(GhosttyPhoneChromePalette.armedKeyFill)
                }
            }
            .ghosttyToolbarButtonSurface(isPressed: isPressed, isEnabled: isEnabled)
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            // Dimmed as one image, so a disabled button's symbol doesn't show through its badge or surface.
            .compositingGroup()
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint ?? "")
            .accessibilityValue(accessibilityValue ?? "")
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
            .accessibilityActions {
                if isEnabled, let onLongPress {
                    Button("Open Shortcuts", action: onLongPress)
                }
            }
            .onTapGesture {
                guard isEnabled else { return }
                isPressed = false
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
                    guard isEnabled, let onLongPress else { return }
                    Haptic.tap(.medium)
                    onLongPress()
                }
            )
            .disabled(!isEnabled)
    }
}

private struct GhosttyChromePressBody<Content: View>: View {
    let isPressed: Bool
    let isEnabled: Bool
    let onPressDown: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var lastPressed = false

    var body: some View {
        content()
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1)
            // Dimmed as one image, so a disabled button's symbol doesn't show through its badge or surface.
            .compositingGroup()
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
    let isEnabled: Bool
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GhosttyChromePressBody(
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            onPressDown: { Haptic.chromeControlPress() }
        ) {
            configuration.label
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: width, height: height)
                .ghosttyToolbarButtonSurface(isPressed: configuration.isPressed, isEnabled: isEnabled)
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

    /// The press feedback every toolbar button shares: a faint disc while a finger is down.
    func ghosttyToolbarButtonSurface(isPressed: Bool, isEnabled: Bool) -> some View {
        overlay {
            Circle().fill(isPressed && isEnabled ? GhosttyPhoneChromePalette.toolbarButtonPressedFill : Color.clear)
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
    /// An armed key reads like the keyboard's latched Shift: a light disc with a dark label in dark, the reverse in
    /// light.
    static let armedKeyFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : UIColor(white: 0.11, alpha: 1)
    })
    static let armedKeyLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : .white
    })

    static let uiBackground = UIColor(
        red: 0.18,
        green: 0.20,
        blue: 0.24,
        alpha: 1.0
    )
}

extension View {
    func ghosttyTerminalChromePresentation(_ colorScheme: ColorScheme) -> some View {
        preferredColorScheme(colorScheme)
    }
}
