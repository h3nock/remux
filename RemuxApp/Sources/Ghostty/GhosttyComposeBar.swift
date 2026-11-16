import SwiftUI
import UIKit

struct GhosttyComposerSessionState: Equatable {
    var draft = ""
    var attachments: [GhosttyPendingAttachment] = []

    var hasContent: Bool {
        !draft.isEmpty || !attachments.isEmpty
    }

    var areAttachmentsReady: Bool {
        attachments.allSatisfy { $0.transferSource != nil }
    }
}

enum GhosttyComposerMessageFormatter {
    static func message(draft: String, attachmentText: String) -> String {
        guard !draft.isEmpty else { return attachmentText }
        guard !attachmentText.isEmpty else { return draft }
        return draft + "\n" + attachmentText
    }
}

enum GhosttyComposeBarSubmissionState: Equatable {
    case composing(canSend: Bool)
    case sending

    var allowsComposerInput: Bool {
        if case .composing = self { return true }
        return false
    }

    var isSendEnabled: Bool {
        switch self {
        case .composing(let canSend):
            canSend
        case .sending:
            false
        }
    }

    var isSending: Bool {
        self == .sending
    }
}

extension GhosttyComposerDictationPhase {
    enum ComposerStatus: Equatable {
        case none
        case message(String)
        case meter
    }

    enum ComposerControl: Equatable {
        case dictate
        case stop
        case progress
    }

    var composerStatus: ComposerStatus {
        switch self {
        case .idle:
            .none
        case .preparing:
            .message("Preparing dictation…")
        case .starting:
            .message("Starting…")
        case .recording:
            .meter
        case .transcribing:
            .message("Transcribing…")
        }
    }

    var composerControl: ComposerControl {
        switch self {
        case .idle:
            .dictate
        case .recording:
            .stop
        case .preparing, .starting, .transcribing:
            .progress
        }
    }

    var allowsSending: Bool {
        !isActive || self == .recording
    }
}

private struct GhosttyComposerInputLayout: Layout {
    let isDictationActive: Bool
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let editingContentInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        guard let width = proposal.width, width.isFinite, width > 0 else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(
                width: sizes.reduce(0) { $0 + $1.width } + (horizontalSpacing * 3),
                height: sizes.map(\.height).max() ?? 0
            )
        }

        return CGSize(
            width: width,
            height: metrics(width: width, subviews: subviews).height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 4 else { return }
        let metrics = metrics(width: bounds.width, subviews: subviews)

        if !isDictationActive {
            subviews[1].place(
                at: CGPoint(
                    x: bounds.minX + editingContentInset,
                    y: bounds.minY + editingContentInset
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: max(0, bounds.width - (editingContentInset * 2)),
                    height: metrics.center.height
                )
            )
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.maxY),
                anchor: .bottomLeading,
                proposal: ProposedViewSize(metrics.leading)
            )
            subviews[3].place(
                at: CGPoint(x: bounds.maxX, y: bounds.maxY),
                anchor: .bottomTrailing,
                proposal: ProposedViewSize(metrics.send)
            )
            subviews[2].place(
                at: CGPoint(
                    x: bounds.maxX - metrics.send.width - horizontalSpacing,
                    y: bounds.maxY
                ),
                anchor: .bottomTrailing,
                proposal: ProposedViewSize(metrics.dictation)
            )
            return
        }

        var x = bounds.minX
        for (index, size) in metrics.compactSizes.enumerated() {
            let centersDictationContent = isDictationActive && index == 1
            subviews[index].place(
                at: CGPoint(
                    x: x,
                    y: centersDictationContent ? bounds.midY : bounds.maxY
                ),
                anchor: centersDictationContent ? .leading : .bottomLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
        }
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> Metrics {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let dictation = subviews[2].sizeThatFits(.unspecified)
        let send = subviews[3].sizeThatFits(.unspecified)
        let controlsHeight = max(leading.height, max(dictation.height, send.height))
        let centerWidth = isDictationActive
            ? max(
                0,
                width - leading.width - dictation.width - send.width - (horizontalSpacing * 3)
            )
            : max(0, width - (editingContentInset * 2))
        let center = subviews[1].sizeThatFits(
            ProposedViewSize(width: centerWidth, height: nil)
        )
        let height = isDictationActive
            ? max(controlsHeight, center.height)
            : editingContentInset + center.height + verticalSpacing + controlsHeight

        return Metrics(
            leading: leading,
            center: center,
            dictation: dictation,
            send: send,
            compactSizes: [leading, center, dictation, send],
            height: height
        )
    }

    private struct Metrics {
        let leading: CGSize
        let center: CGSize
        let dictation: CGSize
        let send: CGSize
        let compactSizes: [CGSize]
        let height: CGFloat
    }
}

struct GhosttyComposeBar: View {
    @AppStorage("terminal.composer.keyboardDismissHintShown")
    private var hasShownKeyboardDismissHint = false
    @State private var isShowingKeyboardDismissHint = false
    @State private var hasCommittedKeyboardDismissDrag = false
    /// The open attachment menu, or `nil` while it is closed.
    @State private var attachmentMenu: GhosttyComposerAttachmentMenuModel?
    @State private var attachmentMenuButtonFrame: CGRect = .zero
    @State private var barFrameOnScreen: CGRect = .zero
    /// Shows the menu in the keyboard's window while the keyboard is up, so it lies over the keyboard.
    @State private var attachmentMenuOverKeyboard = GhosttyKeyboardOverlayPresenter()
    @State private var isAttachmentMenuOverKeyboard = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The bar observes the composer directly so draft keystrokes and
    // dictation updates re-render only this subtree, not the terminal
    // screen that hosts it.
    @ObservedObject var composer: GhosttyComposerModel
    /// The terminal can take a composed message now.
    let canSubmit: Bool

    let wantsKeyboardFocus: Bool
    let isSoftwareKeyboardVisible: Bool
    let isKeyboardDismissalActive: Bool
    let keyboardActivationToken: Int
    let keyboardResponderHandoff: GhosttyKeyboardResponderHandoff
    let onKeyboardFocusRequest: () -> Void
    let onKeyboardResponderAttached: () -> Void
    let onDismissKeyboard: () -> Void
    let onClose: () -> Void
    /// `nil` where there is no camera to open; the menu then leaves Camera out.
    let onTakePhoto: (() -> Void)?
    let onChoosePhotos: () -> Void
    let onChooseFiles: () -> Void
    let onOpenAttachment: (GhosttyPendingAttachment.ID) -> Void
    let onRetryAttachment: (GhosttyPendingAttachment.ID) -> Void
    let onRemoveAttachment: (GhosttyPendingAttachment.ID) -> Void
    let onPasteAttachment: () -> Bool
    let onStartDictation: () -> Void
    let onCancelDictation: () -> Void
    let onFinishDictation: () -> Void
    let onSend: () -> Void

    private var attachments: [GhosttyPendingAttachment] {
        composer.attachments
    }

    private var dictationPhase: GhosttyComposerDictationPhase {
        composer.dictationController.phase
    }

    private var dictationAudioLevelModel: GhosttyComposerAudioLevelModel {
        composer.dictationController.audioLevelModel
    }

    private var statusMessage: String? {
        composer.statusMessage
    }

    private var attachmentUploadCount: Int {
        composer.attachmentTransferUploadCount
    }

    private var attachmentTransferProgress: GhosttyAttachmentTransferProgress? {
        composer.attachmentTransferProgress
    }

    private var submissionState: GhosttyComposeBarSubmissionState {
        if composer.isSubmitting {
            return .sending
        }
        return .composing(
            canSend: canSubmit
                && composer.hasContent
                && composer.areAttachmentsReady
        )
    }

    private var showsAttachments: Bool {
        !dictationPhase.isActive && !attachments.isEmpty
    }

    var body: some View {
#if DEBUG
        let _ = GhosttySurfaceScreenPerfProbe.recordBarEval()
#endif
        VStack(spacing: showsAttachments ? 6 : 0) {
            if showsAttachments {
                GhosttyComposerAttachmentStrip(
                    attachments: attachments,
                    isEnabled: submissionState.allowsComposerInput,
                    onOpen: onOpenAttachment,
                    onRetry: onRetryAttachment,
                    onRemove: onRemoveAttachment
                )

                if submissionState.isSending, attachmentUploadCount > 0 {
                    GhosttyComposerAttachmentProgress(
                        uploadCount: attachmentUploadCount,
                        progress: attachmentTransferProgress
                    )
                }
            }

            composerRow
        }
        .padding(.top, dictationPhase.isActive ? 0 : 12)
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .frame(minHeight: GhosttyKeyboardChromeSizing.baselineHeight)
        .frame(maxWidth: .infinity)
        .ghosttyComposerSurface()
        .animation(
            GhosttyKeyboardChromeAnimation.composerTransition,
            value: dictationPhase.isActive
        )
        .overlay(alignment: .top) {
            if showsKeyboardDismissAffordance {
                keyboardDismissAffordance
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.12)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))
                        )
                    )
            }
        }
        .onChange(of: showsKeyboardDismissAffordance, initial: true) { _, isVisible in
            guard isVisible else {
                isShowingKeyboardDismissHint = false
                hasCommittedKeyboardDismissDrag = false
                return
            }
            guard !hasShownKeyboardDismissHint else { return }
            isShowingKeyboardDismissHint = true
            hasShownKeyboardDismissHint = true
        }
        .overlay {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("terminal.composer.bounds")
        }
#if DEBUG
        .overlay {
            if GhosttySurfaceScreenPerfProbe.isEnabled {
                GhosttyComposeBarPerfMarker(
                    value: GhosttySurfaceScreenPerfProbe.markerValue
                )
            }
        }
#endif
        .coordinateSpace(.named(GhosttyComposerAttachmentMenuLayout.barSpace))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            barFrameOnScreen = frame
            // The menu was placed by the bar's old frame.
            if attachmentMenu != nil { removeAttachmentMenu() }
        }
        // Last, so the menu also covers the keyboard-dismiss handle drawn over the field's top edge.
        .overlay {
            if #available(iOS 26.0, *), let attachmentMenu, !isAttachmentMenuOverKeyboard {
                GeometryReader { proxy in
                    GhosttyComposerAttachmentMenu(model: attachmentMenu, barSize: proxy.size)
                }
            }
        }
        .onChange(of: submissionState.allowsComposerInput && !dictationPhase.isActive) { _, isAvailable in
            if !isAvailable { removeAttachmentMenu() }
        }
        .onChange(of: isSoftwareKeyboardVisible) { _, isVisible in
            // Shown over the keyboard, the menu has nothing to rest on once the keyboard leaves.
            if !isVisible, isAttachmentMenuOverKeyboard { removeAttachmentMenu() }
        }
        .onDisappear(perform: removeAttachmentMenu)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.composer")
    }

    /// With the keyboard up the menu is shown in the keyboard's window, so its lower edge lies over the keyboard and
    /// a touch on the keys closes it. With the keyboard down it is shown in this view. (The + opens Apple's menu
    /// instead when the keyboard is up and its window is not known; should the window go between drawing the + and
    /// the tap, the menu is shown in this view, under the keyboard's top edge.)
    private func presentAttachmentMenu() {
        guard #available(iOS 26.0, *) else { return }
        typealias Layout = GhosttyComposerAttachmentMenuLayout
        let overhang = Layout.overhang(
            itemCount: attachmentMenuItems.count,
            barFrameOnScreen: barFrameOnScreen,
            screenHeight: UIScreen.main.bounds.height,
            isKeyboardUp: isSoftwareKeyboardVisible
        )
        let menu = GhosttyComposerAttachmentMenuModel(
            items: attachmentMenuItems,
            overhang: overhang,
            sourceFrame: attachmentMenuButtonFrame,
            growsFromSource: !reduceMotion && !attachmentMenuButtonFrame.isEmpty,
            onChoose: chooseAttachmentSource,
            // A menu opened while this one was still closing is not this one's to remove.
            onClosed: { closed in
                if attachmentMenu === closed { removeAttachmentMenu() }
            }
        )
        attachmentMenu = menu
        guard isSoftwareKeyboardVisible else { return }

        isAttachmentMenuOverKeyboard = attachmentMenuOverKeyboard.present(
            GhosttyComposerAttachmentMenu(model: menu, barSize: barFrameOnScreen.size)
                .offset(x: barFrameOnScreen.minX, y: barFrameOnScreen.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.colorScheme, colorScheme)
        )
    }

    private func removeAttachmentMenu() {
        attachmentMenuOverKeyboard.dismiss()
        isAttachmentMenuOverKeyboard = false
        attachmentMenu = nil
    }

    private var attachmentMenuItems: [GhosttyComposerAttachmentMenuModel.Item] {
        GhosttyComposerAttachmentMenuModel.Item.allCases.filter { $0 != .camera || onTakePhoto != nil }
    }

    private func chooseAttachmentSource(_ item: GhosttyComposerAttachmentMenuModel.Item) {
        switch item {
        case .camera: onTakePhoto?()
        case .photos: onChoosePhotos()
        case .files: onChooseFiles()
        }
    }

    private var showsKeyboardDismissAffordance: Bool {
        isSoftwareKeyboardVisible
            && !isKeyboardDismissalActive
            && !dictationPhase.isActive
    }

    private var composerRow: some View {
        GhosttyComposerInputLayout(
            isDictationActive: dictationPhase.isActive,
            horizontalSpacing: 2,
            verticalSpacing: 2,
            editingContentInset: 8
        ) {
            leadingControls

            composerTextRegion

            dictationControl

            sendButton(
                state: submissionState,
                allowsTap: submissionState.isSendEnabled && dictationPhase.allowsSending,
                action: onSend
            )
        }
    }

    private var keyboardDismissAffordance: some View {
        ZStack {
            Color.clear

            VStack(spacing: 3) {
                Capsule()
                    .fill(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                    .frame(width: 34, height: 5)

                if isShowingKeyboardDismissHint && !dictationPhase.isActive {
                    Text("Drag down to hide keyboard")
                        .font(.caption2)
                        .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(Rectangle())
        .highPriorityGesture(keyboardDismissGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard")
        .accessibilityHint("Drag down to hide the keyboard.")
        .accessibilityIdentifier("terminal.composer.keyboard-dismiss")
        .accessibilityAction(named: Text("Hide Keyboard")) {
            onDismissKeyboard()
        }
    }

    private var keyboardDismissGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard showsKeyboardDismissAffordance,
                      !hasCommittedKeyboardDismissDrag else { return }
                let downwardDistance = value.translation.height
                guard downwardDistance >= 10,
                      downwardDistance > abs(value.translation.width) else { return }
                hasCommittedKeyboardDismissDrag = true
                onDismissKeyboard()
            }
            .onEnded { _ in
                hasCommittedKeyboardDismissDrag = false
            }
    }

    private var composerTextRegion: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !dictationPhase.isActive, let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("terminal.composer.status")
            }

            ZStack(alignment: .topLeading) {
                GhosttyComposerTextView(
                    text: $composer.draft,
                    caretColor: RemuxAccent.uiFill,
                    allowsUserEdits: submissionState.allowsComposerInput
                        && !dictationPhase.isActive,
                    wantsFirstResponder: wantsKeyboardFocus,
                    activationToken: keyboardActivationToken,
                    responderHandoff: keyboardResponderHandoff,
                    onFocusRequest: onKeyboardFocusRequest,
                    onResponderAttached: onKeyboardResponderAttached,
                    onPasteAttachment: onPasteAttachment
                )
                .frame(height: dictationPhase.isActive ? 32 : nil)
                .opacity(dictationPhase.isActive ? 0 : 1)
                .allowsHitTesting(!dictationPhase.isActive)
                .accessibilityHidden(dictationPhase.isActive)
                .overlay(alignment: .topLeading) {
                    composerCenterPresentation
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var composerCenterPresentation: some View {
        if dictationPhase.isActive {
            dictationCenterContent
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        } else if composer.draft.isEmpty {
            Text(composerPlaceholder)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                .padding(.leading, 4)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .accessibilityIdentifier("terminal.composer.placeholder")
        }
    }

    @ViewBuilder
    private var leadingControls: some View {
        if dictationPhase.isActive {
            dictationModeButton(
                systemName: "xmark",
                accessibilityLabel: "Cancel dictation",
                accessibilityIdentifier: "terminal.composer.dictation.cancel",
                action: onCancelDictation
            )
        } else {
            HStack(spacing: 2) {
                attachmentButton
                closeButton
            }
        }
    }

    @ViewBuilder
    private var dictationCenterContent: some View {
        switch dictationPhase.composerStatus {
        case .none:
            EmptyView()
        case .message(let title):
            dictationStatus(title)
        case .meter:
            GhosttyComposerDictationMeter(model: dictationAudioLevelModel)
        }
    }

    @ViewBuilder
    private var dictationControl: some View {
        switch dictationPhase.composerControl {
        case .dictate:
            dictationButton
        case .stop:
            dictationModeButton(
                systemName: "stop.fill",
                accessibilityLabel: "Stop dictation",
                accessibilityIdentifier: "terminal.composer.dictation.stop",
                action: onFinishDictation
            )
        case .progress:
            ProgressView()
                .controlSize(.small)
                .tint(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
    }

    private func dictationStatus(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
            .lineLimit(1)
            .accessibilityIdentifier("terminal.composer.dictation.status")
    }

    private func dictationModeButton(
        systemName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        return Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 34, height: 34)
                .background(
                    GhosttyPhoneChromePalette.toolbarButtonPressedFill,
                    in: Circle()
                )
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var composerPlaceholder: String {
        return attachments.isEmpty ? "Compose…" : "Describe the task…"
    }

    /// The app's own menu hangs just below the bar, over the keyboard when it is up, and closes on a touch anywhere
    /// outside it. Where it can't (before iOS 26, or with the keyboard up and its window not known) the + opens
    /// Apple's standard menu instead.
    @ViewBuilder
    private var attachmentButton: some View {
        if GhosttyKeyboardWindowTracker.isSupported,
           !isSoftwareKeyboardVisible || attachmentMenuOverKeyboard.canPresent {
            attachmentMenuButton
        } else {
            standardAttachmentMenu
        }
    }

    private var standardAttachmentMenu: some View {
        Menu {
            ForEach(attachmentMenuItems, id: \.self) { item in
                Button {
                    chooseAttachmentSource(item)
                } label: {
                    Label(item.title, systemImage: item.systemName)
                }
                .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("terminal.composer.attachments")
    }

    private var attachmentMenuButton: some View {
        Button {
            Haptic.chromeControlPress()
            presentAttachmentMenu()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                // The menu grows out of the + and shrinks back into it, so the + gives way while it is open.
                .opacity(attachmentMenu?.coversSource == true ? 0 : 1)
                .animation(.easeOut(duration: 0.14), value: attachmentMenu?.coversSource)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(GhosttyComposerAttachmentMenuLayout.barSpace))
        } action: { frame in
            attachmentMenuButtonFrame = frame
        }
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("terminal.composer.attachments")
    }

    private var closeButton: some View {
        Button {
            Haptic.chromeControlPress()
            onClose()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .accessibilityLabel("Close composer")
        .accessibilityHint("Return to direct terminal input while preserving the draft.")
        .accessibilityIdentifier("terminal.composer.toggle")
    }

    private var dictationButton: some View {
        Button {
            Haptic.chromeControlPress()
            onStartDictation()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!submissionState.allowsComposerInput)
        .opacity(submissionState.allowsComposerInput ? 1 : 0.38)
        .accessibilityLabel("Start dictation")
        .accessibilityIdentifier("terminal.composer.mic")
    }

    private func sendButton(
        state: GhosttyComposeBarSubmissionState,
        allowsTap: Bool,
        action: @escaping () -> Void
    ) -> some View {
        return Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .systemBlue))

                if state.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                }
            }
                .frame(width: 34, height: 34)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(GhosttyComposerPressButtonStyle())
        .disabled(!allowsTap)
        .opacity(allowsTap || state.isSending ? 1 : 0.38)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("terminal.composer.send")
    }
}

private struct GhosttyComposerPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Circle()
                    .fill(
                        configuration.isPressed
                            ? GhosttyPhoneChromePalette.toolbarButtonPressedFill
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct GhosttyComposerDictationMeterSizing {
    static let height: CGFloat = 32
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 2
    static let maximumWidth: CGFloat = 220
    static let targetWidthFraction: CGFloat = 0.86
    static let minimumSideInset: CGFloat = 12
    static let maximumBarCount = Int(
        (maximumWidth + barSpacing) / (barWidth + barSpacing)
    )

    static func visibleBarCount(
        availableWidth: CGFloat,
        sampleCount: Int
    ) -> Int {
        guard sampleCount > 0 else { return 0 }

        let proportionalWidth = availableWidth * targetWidthFraction
        let insetWidth = availableWidth - (minimumSideInset * 2)
        let targetWidth = min(maximumWidth, min(proportionalWidth, insetWidth))
        guard targetWidth >= barWidth else { return 0 }

        let fittingCount = Int(
            floor((targetWidth + barSpacing) / (barWidth + barSpacing))
        )
        return min(sampleCount, fittingCount)
    }
}

private struct GhosttyComposerDictationMeter: View {
    @ObservedObject var model: GhosttyComposerAudioLevelModel

    var body: some View {
        GeometryReader { geometry in
            let visibleBarCount = GhosttyComposerDictationMeterSizing.visibleBarCount(
                availableWidth: geometry.size.width,
                sampleCount: model.levels.count
            )
            let firstVisibleIndex = model.levels.count - visibleBarCount

            HStack(spacing: GhosttyComposerDictationMeterSizing.barSpacing) {
                ForEach(0..<visibleBarCount, id: \.self) { offset in
                    Capsule()
                        .fill(GhosttyPhoneChromePalette.chromeForeground.opacity(0.72))
                        .frame(
                            width: GhosttyComposerDictationMeterSizing.barWidth,
                            height: max(
                                4,
                                6 + (model.levels[firstVisibleIndex + offset] * 24)
                            )
                        )
                }
            }
            .frame(height: geometry.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GhosttyComposerDictationMeterSizing.height)
        .clipped()
        .accessibilityLabel("Recording audio")
        .accessibilityIdentifier("terminal.composer.dictation.meter")
    }
}

private extension View {
    @ViewBuilder
    func ghosttyComposerSurface(cornerRadius: CGFloat = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background {
                    Color.clear
                        .glassEffect(
                            .regular.tint(
                                GhosttyPhoneChromePalette.toolbarGlassTint.opacity(0.70)
                            ),
                            in: shape
                        )
                        .shadow(
                            color: GhosttyPhoneChromePalette.toolbarGlassShadow.opacity(0.60),
                            radius: 8,
                            y: 4
                        )
                }
        } else {
            self
                .background(GhosttyPhoneChromePalette.toolbarFallbackFill, in: shape)
                .overlay {
                    shape.strokeBorder(
                        GhosttyPhoneChromePalette.toolbarStroke,
                        lineWidth: 0.75
                    )
                }
                .shadow(
                    color: GhosttyPhoneChromePalette.toolbarShadow.opacity(0.70),
                    radius: 6,
                    y: 3
                )
        }
    }
}

private struct GhosttyComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let caretColor: UIColor
    let allowsUserEdits: Bool
    let wantsFirstResponder: Bool
    let activationToken: Int
    let responderHandoff: GhosttyKeyboardResponderHandoff
    let onFocusRequest: () -> Void
    let onResponderAttached: () -> Void
    let onPasteAttachment: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> GhosttyComposerUITextView {
        let textView = GhosttyComposerUITextView()
        textView.delegate = context.coordinator
        textView.allowsUserEdits = allowsUserEdits
        textView.onPasteAttachment = onPasteAttachment
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = caretColor
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        // Keep the keyboard's assistance geometry identical when ownership
        // moves between the terminal and composer responders.
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        textView.textContainer.lineFragmentPadding = 4
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "terminal.composer.field"
        textView.onAttachedToWindow = onResponderAttached
        responderHandoff.register(textView, as: .composer)
        return textView
    }

    func updateUIView(_ textView: GhosttyComposerUITextView, context: Context) {
        context.coordinator.parent = self
        textView.tintColor = caretColor
        textView.allowsUserEdits = allowsUserEdits
        textView.onPasteAttachment = onPasteAttachment
        textView.onAttachedToWindow = onResponderAttached
        responderHandoff.register(textView, as: .composer)

        if textView.text != text {
            textView.text = text
            textView.selectedRange = NSRange(
                location: textView.text.utf16.count,
                length: 0
            )
        }

        context.coordinator.reconcileFirstResponder(
            textView,
            wantsFirstResponder: wantsFirstResponder,
            activationToken: activationToken
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: GhosttyComposerUITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measuredHeight = ceil(
            textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
        )
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let maximumHeight = ceil((lineHeight * 6) + verticalInsets)
        let resolvedHeight = min(max(measuredHeight, 36), maximumHeight)
        textView.isScrollEnabled = measuredHeight > maximumHeight
        return CGSize(width: width, height: resolvedHeight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GhosttyComposerTextView
        private var appliedActivationToken = -1
        private var reconciliationGeneration: UInt64 = 0

        init(parent: GhosttyComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusRequest()
        }

        func textViewDidChange(_ textView: UITextView) {
#if DEBUG
            GhosttySurfaceScreenPerfProbe.beginComposerUpdatePassIfNeeded()
#endif
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            parent.allowsUserEdits
        }

        func reconcileFirstResponder(
            _ textView: UITextView,
            wantsFirstResponder: Bool,
            activationToken: Int
        ) {
            let activationChanged = appliedActivationToken != activationToken
            appliedActivationToken = activationToken
            reconciliationGeneration &+= 1
            let requestedGeneration = reconciliationGeneration

            if wantsFirstResponder {
                guard !textView.isFirstResponder else { return }
                guard activationChanged || textView.window != nil else { return }
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          self.reconciliationGeneration == requestedGeneration,
                          self.parent.wantsFirstResponder,
                          let textView,
                          textView.window != nil,
                          !textView.isFirstResponder else {
                        return
                    }
                    _ = textView.becomeFirstResponder()
                }
            } else if textView.isFirstResponder {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          self.reconciliationGeneration == requestedGeneration,
                          !self.parent.wantsFirstResponder,
                          let textView,
                          textView.isFirstResponder else {
                        return
                    }
                    _ = textView.resignFirstResponder()
                }
            }
        }
    }
}

#if DEBUG
private struct GhosttyComposeBarPerfMarker: View {
    let value: String

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Composer perf probe")
            .accessibilityValue(value)
            .accessibilityIdentifier("terminal.composer.perf")
    }
}
#endif

final class GhosttyComposerUITextView: UITextView {
    /// False while a send is in flight. The field then takes no pasted attachment either: the send clears the draft it
    /// took, which would drop one added meanwhile.
    var allowsUserEdits = true
    var onPasteAttachment: (() -> Bool)?
    var onAttachedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        onAttachedToWindow?()
    }

    /// A text view offers Paste for text alone; the composer also takes a copied picture as an attachment.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, allowsUserEdits, onPasteAttachment != nil,
           UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if allowsUserEdits, onPasteAttachment?() == true {
            return
        }
        super.paste(sender)
    }
}

/// Starts the attachments and their upload progress on the draft text's left edge. The strip still scrolls
/// under this margin to the composer's own edge.
private enum GhosttyComposerAttachmentInset {
    static let horizontal: CGFloat = 13
}

private struct GhosttyComposerAttachmentStrip: View {
    let attachments: [GhosttyPendingAttachment]
    let isEnabled: Bool
    let onOpen: (GhosttyPendingAttachment.ID) -> Void
    let onRetry: (GhosttyPendingAttachment.ID) -> Void
    let onRemove: (GhosttyPendingAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
        }
        .contentMargins(.horizontal, GhosttyComposerAttachmentInset.horizontal, for: .scrollContent)
        .accessibilityIdentifier("terminal.composer.attachment-strip")
    }

    private func attachmentChip(_ attachment: GhosttyPendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                Haptic.chromeControlPress()
                if attachment.didFailPreparingTransferSource {
                    onRetry(attachment.id)
                } else {
                    onOpen(attachment.id)
                }
            } label: {
                attachmentPreview(attachment)
            }
            .buttonStyle(.plain)
            .disabled(
                !isEnabled
                    || (!attachment.isPreviewable && !attachment.didFailPreparingTransferSource)
            )
            .accessibilityLabel(
                attachment.didFailPreparingTransferSource
                    ? "Retry \(attachment.title)"
                    : "Preview \(attachment.title)"
            )

            Button {
                Haptic.chromeControlPress()
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel("Remove \(attachment.title)")
            .accessibilityIdentifier("terminal.composer.attachment.remove")
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .opacity(isEnabled ? 1 : 0.68)
    }

    @ViewBuilder
    private func attachmentPreview(_ attachment: GhosttyPendingAttachment) -> some View {
        if case .imageData(let data) = attachment.previewPayload {
            GhosttyAttachmentPreviewSquare(imageData: data, side: 58)
                .equatable()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if isImageAttachment(attachment) {
            attachmentLoadingPreview(attachment)
        } else {
            filePreview(attachment)
        }
    }

    private func attachmentLoadingPreview(_ attachment: GhosttyPendingAttachment) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if attachment.isPreparingTransferSource {
                ProgressView()
                    .controlSize(.small)
            } else if attachment.didFailPreparingTransferSource {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Retry")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.orange)
            } else {
                Image(systemName: attachment.systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
            }
        }
        .frame(width: 58, height: 58)
    }

    private func filePreview(_ attachment: GhosttyPendingAttachment) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.09))

                if attachment.isPreparingTransferSource {
                    ProgressView()
                        .controlSize(.mini)
                } else if attachment.didFailPreparingTransferSource {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text(fileTypeLabel(for: attachment))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                        .lineLimit(1)
                }
            }
            .frame(width: 34, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                    .lineLimit(attachment.didFailPreparingTransferSource ? 1 : 2)

                if attachment.didFailPreparingTransferSource {
                    Text("Tap to retry")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(width: 154, height: 58)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func isImageAttachment(_ attachment: GhosttyPendingAttachment) -> Bool {
        switch attachment.kind {
        case .photo, .pasteboardImage:
            true
        case .video, .media, .file, .pasteboardLink, .pasteboardText:
            false
        }
    }

    private func fileTypeLabel(for attachment: GhosttyPendingAttachment) -> String {
        let fileExtension = (attachment.title as NSString).pathExtension
        return fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(5)).uppercased()
    }
}

private struct GhosttyComposerAttachmentProgress: View {
    let uploadCount: Int
    let progress: GhosttyAttachmentTransferProgress?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progressFraction)
                .tint(.blue)

            Text(progressLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(GhosttyPhoneChromePalette.chromeSecondaryForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, GhosttyComposerAttachmentInset.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressAccessibilityLabel)
        .accessibilityIdentifier("terminal.composer.attachment-progress")
    }

    private var progressFraction: Double {
        guard let progress else { return 0 }
        let completed = Double(progress.completedUploadCount)
        let current = progress.currentUploadFraction
        return min(1, (completed + current) / Double(max(uploadCount, 1)))
    }

    private var progressLabel: String {
        guard let progress else {
            return uploadCount > 1 ? "Uploading 1 of \(uploadCount)" : "Uploading"
        }
        let percent = Int((progress.currentUploadFraction * 100).rounded())
        if uploadCount > 1 {
            return "\(progress.currentUploadIndex) of \(uploadCount) · \(percent)%"
        }
        return "\(percent)%"
    }

    private var progressAccessibilityLabel: String {
        "Attachment upload \(Int((progressFraction * 100).rounded())) percent"
    }
}

/// The composer's attachment menu while it is open: Camera, Photos and Files, drawn by the app so it can sit across
/// the field's edge and over the keyboard.
///
/// The menu grows out of the `+` as one piece of glass. Where the screen has room, its last icon ends level with the
/// field's bottom edge and only the padding below it hangs past the field, so it reads as a layer resting on the
/// field instead of a panel inside it.
@MainActor
@Observable
final class GhosttyComposerAttachmentMenuModel {
    enum Item: CaseIterable {
        case camera
        case photos
        case files

        var title: String {
            switch self {
            case .camera: "Camera"
            case .photos: "Photos"
            case .files: "Files"
            }
        }

        var systemName: String {
            switch self {
            case .camera: "camera"
            case .photos: "photo.on.rectangle"
            case .files: "doc"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .camera: "terminal.composer.attachments.camera"
            case .photos: "terminal.composer.attachments.photos"
            case .files: "terminal.composer.attachments.files"
            }
        }
    }

    let items: [Item]
    /// How far the menu reaches below the bar.
    let overhang: CGFloat
    /// The `+` button's frame in the bar, which the menu grows out of and shrinks back into.
    let sourceFrame: CGRect
    /// False with Reduce Motion on: the menu then only fades.
    let growsFromSource: Bool
    private let onChoose: (Item) -> Void
    private let onClosed: (GhosttyComposerAttachmentMenuModel) -> Void

    private(set) var isExpanded = false
    private(set) var isVisible = false
    /// True from opening until the menu starts to close: the glass that grew out of the `+` stands in for it.
    private(set) var coversSource = true
    var highlightedItem: Item?

    init(
        items: [Item],
        overhang: CGFloat,
        sourceFrame: CGRect,
        growsFromSource: Bool,
        onChoose: @escaping (Item) -> Void,
        onClosed: @escaping (GhosttyComposerAttachmentMenuModel) -> Void
    ) {
        self.items = items
        self.overhang = overhang
        self.sourceFrame = sourceFrame
        self.growsFromSource = growsFromSource
        self.onChoose = onChoose
        self.onClosed = onClosed
    }

    var isFullSize: Bool {
        isExpanded || !growsFromSource
    }

    private static let openSpring = Animation.spring(duration: 0.35, bounce: 0.2)
    private static let closeSpring = Animation.spring(duration: 0.25)

    func open() {
        guard growsFromSource else {
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = true
                isVisible = true
            }
            return
        }
        withAnimation(.easeOut(duration: 0.08)) { isVisible = true }
        withAnimation(Self.openSpring) { isExpanded = true }
    }

    func close() {
        guard coversSource else { return }
        coversSource = false
        highlightedItem = nil
        guard growsFromSource else {
            withAnimation(.easeOut(duration: 0.12)) {
                isExpanded = false
                isVisible = false
            } completion: { [onClosed] in
                onClosed(self)
            }
            return
        }
        // Fades as it arrives, so the glass is seen shrinking into the + and nothing is left sitting on it.
        withAnimation(.easeIn(duration: 0.09).delay(0.07)) { isVisible = false }
        withAnimation(Self.closeSpring) {
            isExpanded = false
        } completion: { [onClosed] in
            onClosed(self)
        }
    }

    func choose(_ item: Item) {
        // The rows stay on screen while the menu closes; a touch then must not choose again.
        guard coversSource else { return }
        Haptic.chromeControlPress()
        onChoose(item)
        close()
    }
}

/// Where the attachment menu sits, in the bar's coordinate space.
enum GhosttyComposerAttachmentMenuLayout {
    static let barSpace = "terminal.composer.bar"
    static let width: CGFloat = 280
    static let wellDiameter: CGFloat = 40
    /// From the menu's edge to an icon's well on the left, top and bottom, and between two wells.
    static let inset: CGFloat = 24
    static let rowPitch = wellDiameter + inset
    /// The corner shares its centre with the well beside it.
    static let cornerRadius = inset + wellDiameter / 2
    /// The side of the square around the bar in which a tap closes the menu: more than any screen, so all of it.
    static let dismissReach: CGFloat = 4000

    /// Kept between the menu and the edge of the screen it would otherwise reach.
    static let screenMargin: CGFloat = 8

    /// How far the menu reaches below the bar. Over the keyboard it hangs its full padding past the bar, and further
    /// where the screen above the bar is too short for it, as on a small phone in landscape. Over the bottom of the
    /// screen it hangs only as far as the room there allows: nothing on an iPhone with a Home button.
    static func overhang(itemCount: Int, barFrameOnScreen: CGRect, screenHeight: CGFloat, isKeyboardUp: Bool) -> CGFloat {
        if isKeyboardUp {
            let height = frame(itemCount: itemCount, barSize: barFrameOnScreen.size, overhang: 0).height
            return max(inset, height + screenMargin - barFrameOnScreen.maxY)
        }
        return min(inset, max(0, screenHeight - barFrameOnScreen.maxY - screenMargin))
    }

    static func frame(itemCount: Int, barSize: CGSize, overhang: CGFloat) -> CGRect {
        let height = CGFloat(itemCount) * rowPitch + inset
        return CGRect(x: 0, y: barSize.height + overhang - height, width: width, height: height)
    }

    static func rowFrame(at index: Int, in menuFrame: CGRect) -> CGRect {
        CGRect(x: menuFrame.minX, y: menuFrame.minY + inset / 2 + CGFloat(index) * rowPitch, width: width, height: rowPitch)
    }
}

/// The open attachment menu: one piece of glass that grows out of the `+` button's circle into the menu and shrinks
/// back; a press that can slide across its rows and choose on release; and a tap anywhere else, which closes it.
@available(iOS 26.0, *)
struct GhosttyComposerAttachmentMenu: View {
    let model: GhosttyComposerAttachmentMenuModel
    let barSize: CGSize

    private typealias Layout = GhosttyComposerAttachmentMenuLayout
    /// The composer's own glass.
    private static let glass = Glass.regular.tint(GhosttyPhoneChromePalette.toolbarGlassTint.opacity(0.70))

    private var menuFrame: CGRect {
        Layout.frame(itemCount: model.items.count, barSize: barSize, overhang: model.overhang)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Over the keyboard a touch reaches the menu only where it draws, so this draws a color too faint to see.
            // Any touch outside closes the menu as it lands, a press or a drag as well as a tap, as Apple's menus do.
            Color.black.opacity(0.01)
                .frame(width: Layout.dismissReach, height: Layout.dismissReach)
                .position(x: barSize.width / 2, y: barSize.height / 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.close() })
                .accessibilityHidden(true)

            surface

            Color.clear
                .frame(width: menuFrame.width, height: menuFrame.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let item = item(at: value.location)
                            guard item != model.highlightedItem else { return }
                            if model.highlightedItem != nil, item != nil { Haptic.selection() }
                            model.highlightedItem = item
                        }
                        .onEnded { value in
                            model.highlightedItem = nil
                            guard let item = item(at: value.location) else { return }
                            model.choose(item)
                        }
                )
                .offset(x: menuFrame.minX, y: menuFrame.minY)
                .accessibilityHidden(true)

            ForEach(Array(model.items.enumerated()), id: \.element) { index, item in
                let rowFrame = Layout.rowFrame(at: index, in: menuFrame)
                Color.clear
                    .frame(width: rowFrame.width, height: rowFrame.height)
                    .offset(x: rowFrame.minX, y: rowFrame.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.choose(item) }
                    .accessibilityIdentifier(item.accessibilityIdentifier)
            }
        }
        .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { model.close() }
        .accessibilityIdentifier("terminal.composer.attachments.menu")
        .onAppear { model.open() }
    }

    // One piece of glass whose frame grows, rather than two joined by a glass effect ID: on iOS 27 the system swaps
    // those without a morph.
    private var surface: some View {
        let frame = model.isFullSize ? menuFrame : model.sourceFrame
        // One radius throughout: a rounded rectangle caps it at half its size, so the glass starts as the + button's
        // circle and stays as round as its size allows while it grows.
        let shape = RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            rows
                .frame(width: menuFrame.width, height: menuFrame.height)
                // The rows grow and sharpen with the glass instead of being uncovered by it.
                .scaleEffect(model.isFullSize ? 1 : model.sourceFrame.width / Layout.width, anchor: .bottomLeading)
                .blur(radius: model.isFullSize ? 0 : 6)
                .opacity(model.isExpanded ? 1 : 0)
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .frame(width: model.sourceFrame.width, height: model.sourceFrame.height)
                .opacity(model.isFullSize ? 0 : 1)
        }
        .frame(width: frame.width, height: frame.height, alignment: .bottomLeading)
        .clipShape(shape)
        .glassEffect(Self.glass, in: shape)
        .shadow(color: GhosttyPhoneChromePalette.toolbarGlassShadow.opacity(0.60), radius: 8, y: 4)
        .opacity(model.isVisible ? 1 : 0)
        .offset(x: frame.minX, y: frame.minY)
        .frame(width: barSize.width, height: barSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // VoiceOver reads the rows from the touch layer.
        .accessibilityHidden(true)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.items, id: \.self) { item in
                HStack(spacing: 16) {
                    Image(systemName: item.systemName)
                        .font(.system(size: 17, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: Layout.wellDiameter, height: Layout.wellDiameter)
                        .background(GhosttyPhoneChromePalette.toolbarButtonPressedFill, in: Circle())
                    Text(item.title)
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(GhosttyPhoneChromePalette.chromeForeground)
                .padding(.horizontal, Layout.inset)
                .frame(height: Layout.rowPitch)
                .background {
                    Capsule()
                        .fill(
                            model.highlightedItem == item
                                ? GhosttyPhoneChromePalette.toolbarButtonPressedFill
                                : Color.clear
                        )
                        .padding(Layout.inset / 2 - 4)
                }
                .animation(.easeOut(duration: 0.12), value: model.highlightedItem)
            }
        }
        .padding(.vertical, Layout.inset / 2)
        // The rows have a fixed height and width; larger text than this would not fit them.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// `location` is in the menu's own space.
    private func item(at location: CGPoint) -> GhosttyComposerAttachmentMenuModel.Item? {
        let menu = CGRect(origin: .zero, size: menuFrame.size)
        return model.items.indices
            .first { Layout.rowFrame(at: $0, in: menu).contains(location) }
            .map { model.items[$0] }
    }
}
