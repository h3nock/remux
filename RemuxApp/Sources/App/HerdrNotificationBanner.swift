import SwiftUI
import UIKit

/// What a Herdr notification's banner says, worded as Herdr's own mobile layout words it
/// (`client/shell/notifications.rs`): the agent and its state, then where it is, by name.
struct HerdrNotificationBannerContent: Equatable {
    enum Dot: Equatable {
        case status(TerminalAgentStatus)
        case accent
    }

    let title: String
    /// The workspace and tab, prefixed with the server, and the session unless it is Herdr's default
    /// one, when the notification comes from a session other than the one on screen.
    let place: String?
    let dot: Dot

    static let defaultSessionName = "default"

    init(_ banner: HerdrNotificationPolicy.Banner, fromShownSession: Bool) {
        let notification = banner.notification
        // An agent's own context line numbers its workspace, so an agent's place is named from the
        // snapshot; any other notification's body is its message.
        let message: String?
        switch notification.kind {
        case .needsAttention:
            title = Self.title(notification.title, replacing: " needs attention", with: " waiting")
            dot = .status(.blocked)
            message = nil
        case .finished:
            title = Self.title(notification.title, replacing: " finished", with: " done")
            dot = .status(.done)
            message = nil
        case .updateInstalled:
            title = "update ready"
            dot = .accent
            message = notification.body
        case .custom:
            title = notification.title
            dot = .accent
            message = notification.body
        }
        let names = [banner.origin.place.workspace, banner.origin.place.tab].compactMap { $0 }
        let location = names.isEmpty ? message : names.joined(separator: " › ")
        var parts: [String] = []
        if !fromShownSession {
            parts.append(banner.origin.serverName)
            if banner.origin.sessionName != Self.defaultSessionName { parts.append(banner.origin.sessionName) }
        }
        if let location, !location.isEmpty { parts.append(location) }
        place = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func title(_ title: String, replacing suffix: String, with state: String) -> String {
        guard title.hasSuffix(suffix) else { return title }
        return String(title.dropLast(suffix.count)) + state
    }
}

/// Herdr's accent, from its default theme (`app/state.rs` `Palette::catppuccin`).
enum HerdrPalette {
    static let accent = Color(red: 137 / 255, green: 180 / 255, blue: 250 / 255)
}

/// One banner: Herdr's mark, the agent's state dot and title over the place, and "now".
struct HerdrNotificationBanner: View {
    let content: HerdrNotificationBannerContent

    private static let fill = Color(red: 48 / 255, green: 51 / 255, blue: 58 / 255).opacity(0.97)
    private static let secondary = Color(red: 169 / 255, green: 174 / 255, blue: 184 / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 12) {
                SessionBackendLogo(backend: .herdr, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 9, height: 9)
                            // The banner is dark in either appearance.
                            .environment(\.colorScheme, .dark)
                        Text(content.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    if let place = content.place {
                        Text(place)
                            .font(.system(size: 13))
                            .foregroundStyle(Self.secondary)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("now")
                .font(.system(size: 12))
                .foregroundStyle(Self.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 500)
        .background(Self.fill, in: shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 15, y: 10)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([content.title, content.place].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("herdr.notification.banner")
    }

    private var dotColor: Color {
        switch content.dot {
        case .status(let status): status.color
        case .accent: HerdrPalette.accent
        }
    }
}

/// The Herdr notification on screen, at the top like an iOS notification's. A tap opens its session at
/// its pane; a swipe up puts it away. The banner's frame is reported so its window takes touches there
/// alone.
struct HerdrNotificationBannerLayer: View {
    @ObservedObject var center: HerdrNotificationCenter
    let shownWorkspaceID: SavedWorkspace.ID?
    let onOpen: (HerdrNotificationPolicy.Banner) -> Void
    let onFrameChange: (CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let banner = center.banner {
                HerdrNotificationBanner(content: HerdrNotificationBannerContent(
                    banner,
                    fromShownSession: banner.origin.workspaceID == shownWorkspaceID
                ))
                .onTapGesture { onOpen(banner) }
                .gesture(
                    DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.height < -24 { center.dismiss(banner.id) }
                    }
                )
                .id(banner.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            onFrameChange(center.banner == nil ? .zero : frame)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: center.banner?.id)
        .onChange(of: center.banner?.id) {
            // VoiceOver reads a banner out as it does an iOS notification's.
            guard let banner = center.banner else { return }
            let content = HerdrNotificationBannerContent(
                banner,
                fromShownSession: banner.origin.workspaceID == shownWorkspaceID
            )
            AccessibilityNotification.Announcement(
                [content.title, content.place].compactMap { $0 }.joined(separator: ", ")
            ).post()
        }
    }
}

/// Puts Herdr's notification banner above everything in the app's window, sheets included, as iOS puts
/// its own: in a window of its own over the app's window, taking touches only on the banner. A tap closes
/// whatever is presented over the app, then opens the banner, unless a form the user is typing into is
/// open: the typing is kept, and the tap only puts the banner away.
struct HerdrNotificationBannerWindow: UIViewRepresentable {
    let center: HerdrNotificationCenter
    let shownWorkspaceID: SavedWorkspace.ID?
    let holdsUnsavedInput: Bool
    let onOpen: (HerdrNotificationPolicy.Banner) -> Void

    func makeUIView(context: Context) -> HerdrNotificationBannerAnchor {
        HerdrNotificationBannerAnchor()
    }

    func updateUIView(_ anchor: HerdrNotificationBannerAnchor, context: Context) {
        anchor.show(
            center: center,
            shownWorkspaceID: shownWorkspaceID,
            holdsUnsavedInput: holdsUnsavedInput,
            onOpen: onOpen
        )
    }

    static func dismantleUIView(_ anchor: HerdrNotificationBannerAnchor, coordinator: ()) {
        anchor.removeOverlay()
    }
}

/// Lives in the app's window and keeps the banner's window on the same scene, in the same appearance, so
/// the status bar it covers keeps the app's style.
final class HerdrNotificationBannerAnchor: UIView {
    private struct Content {
        let center: HerdrNotificationCenter
        let shownWorkspaceID: SavedWorkspace.ID?
        let holdsUnsavedInput: Bool
        let onOpen: (HerdrNotificationPolicy.Banner) -> Void
    }

    private final class OverlayWindow: UIWindow {
        /// Where the banner is, in the window's coordinates; every other touch goes to the app.
        var bannerFrame: CGRect = .zero

        /// The banner takes taps, never text, so the app's window stays key: UIKit shows the keyboard only
        /// for the key window's first responder, and the terminal or composer it opens onto keeps it.
        override var canBecomeKey: Bool { false }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bannerFrame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    private var content: Content?
    private var overlay: OverlayWindow?
    private var hosting: UIHostingController<HerdrNotificationBannerLayer>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (anchor: HerdrNotificationBannerAnchor, _: UITraitCollection) in
            anchor.matchAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        center: HerdrNotificationCenter,
        shownWorkspaceID: SavedWorkspace.ID?,
        holdsUnsavedInput: Bool,
        onOpen: @escaping (HerdrNotificationPolicy.Banner) -> Void
    ) {
        content = Content(
            center: center,
            shownWorkspaceID: shownWorkspaceID,
            holdsUnsavedInput: holdsUnsavedInput,
            onOpen: onOpen
        )
        render()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { removeOverlay() } else { render() }
    }

    func removeOverlay() {
        overlay?.isHidden = true
        overlay = nil
        hosting = nil
    }

    private func render() {
        guard let content, let scene = window?.windowScene else { return }
        let layer = HerdrNotificationBannerLayer(
            center: content.center,
            shownWorkspaceID: content.shownWorkspaceID,
            onOpen: { [weak self] banner in self?.open(banner) },
            onFrameChange: { [weak self] frame in self?.overlay?.bannerFrame = frame }
        )
        if let hosting, overlay?.windowScene === scene {
            hosting.rootView = layer
            return
        }
        removeOverlay()
        let hosting = UIHostingController(rootView: layer)
        hosting.view.backgroundColor = .clear
        let overlay = OverlayWindow(windowScene: scene)
        overlay.windowLevel = .normal + 1
        overlay.rootViewController = hosting
        overlay.isHidden = false
        self.hosting = hosting
        self.overlay = overlay
        matchAppearance()
    }

    private func matchAppearance() {
        overlay?.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        hosting?.setNeedsStatusBarAppearanceUpdate()
    }

    /// The banner goes at once; a sheet or alert over the app closes before the pane opens, so it is
    /// what the user lands on. A form with the user's typing stays, and nothing else happens.
    private func open(_ banner: HerdrNotificationPolicy.Banner) {
        guard let content else { return }
        content.center.dismiss(banner.id)
        guard !content.holdsUnsavedInput else { return }
        guard let root = window?.rootViewController, root.presentedViewController != nil else {
            content.onOpen(banner)
            return
        }
        root.dismiss(animated: true) { content.onOpen(banner) }
    }
}
