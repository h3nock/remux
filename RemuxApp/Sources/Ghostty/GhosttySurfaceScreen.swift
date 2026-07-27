import SwiftUI
import UIKit
import CoreTransferable
import GhosttyKit
import PhotosUI
import UniformTypeIdentifiers

struct GhosttySurfaceScreenPresentation: Equatable {
    let workspaceID: SavedWorkspace.ID
    let sessionName: String
    let terminalTheme: TerminalTheme
    let loadingTitle: String
}

struct GhosttyAttachmentInputOwnerProjection: Equatable {
    let isTrayPresented: Bool
    let isPhotosPickerPresented: Bool
    let isFileImporterPresented: Bool
    let isPreviewPresented: Bool

    var isTransientInputOwnerPresented: Bool {
        isPhotosPickerPresented
            || isFileImporterPresented
            || isPreviewPresented
    }
}

struct GhosttyPendingAttachmentInteractionProjection: Equatable {
    let hasPreviewableAttachments: Bool
    let isTransferInProgress: Bool

    var canOpenPreview: Bool {
        hasPreviewableAttachments && !isTransferInProgress
    }
}

enum GhosttyTerminalCoverPhase: Equatable {
    case visible
    case covered(restoreKeyboard: Bool)
    case restoringKeyboard

    var ownsTerminalInput: Bool {
        if case .covered = self { return true }
        return false
    }

    var isRestoringKeyboard: Bool {
        self == .restoringKeyboard
    }
}

struct GhosttySurfaceScreen<Model: GhosttyTerminalScreenModeling>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var model: Model
    private let presentation: GhosttySurfaceScreenPresentation
    private let isSelected: Bool
    private let isTerminalCovered: Bool
    private let shortcutStore: ShortcutStore
    private let keyboardSettings: KeyboardSettings
    private let isPhysicalKeyboardConnected: Bool
    private let onAppKeyboardCommand: (AppKeyboardCommand) -> Void
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var terminalInputController = GhosttyTerminalInputController()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?
    @State private var selectionSheetPresentationState = GhosttySelectionSheetPresentationState()
    @State private var bottomChromeHeight: CGFloat = 0
    @State private var softwareKeyboardOverlapHeight: CGFloat = 0
    @State private var lastSoftwareKeyboardOverlapHeight: CGFloat = 0
    @State private var terminalViewportCoordinator = GhosttyTerminalViewportCoordinator()
    @State private var terminalCoverPhase = GhosttyTerminalCoverPhase.visible
    @State private var isTerminalResponderFirstResponder = false
    @State private var keyboardViewportTransitionCoordinator = GhosttyKeyboardViewportTransitionCoordinator()
    @State private var topologyActionInputRefocusCoordinator = GhosttyTopologyActionInputRefocusCoordinator()
    @State private var trackpadDriver = GhosttyKeyboardCursorTrackpadDriver()
    @State private var trackpadFeedback = GhosttyKeyboardCursorTrackpad.FeedbackState.hidden
    @State private var isShortcutPalettePresented = false
    @State private var isShortcutsSettingsPresented = false
    @State private var shortcutEditorRequest: ShortcutEditorRequest?
    @State private var isAttachmentTrayPresented = false
    @State private var isAttachmentPhotosPickerPresented = false
    @State private var isAttachmentFileImporterPresented = false
    @State private var attachmentPhotoSelections: [PhotosPickerItem] = []
    @State private var isAttachmentPreviewPresented = false
    @State private var attachmentPreviewDetent: PresentationDetent = .medium
    @State private var pendingAttachments: [GhosttyPendingAttachment] = []
    @State private var isAttachmentTransferInProgress = false
    @State private var attachmentTransferUploadCount = 0
    @State private var attachmentTransferProgress: GhosttyAttachmentTransferProgress?
    @State private var attachmentNotice: GhosttyAttachmentNotice?
    @State private var physicalKeyboardChromeState: PhysicalKeyboardChromeState

    private let onReconnect: () -> Void
    private let onEditConnection: () -> Void
    private let onUpdateCredentials: () -> Void
    private let onEditServer: () -> Void
    private let onTrustHostKey: () -> Void
    private let attachmentTransferServiceFactory: @Sendable () -> any GhosttyAttachmentTransferService
    private let onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)?
    private static var maxAttachmentPhotoSelectionCount: Int { 10 }
    private static var tmuxPrefixFlushDelay: Duration { .milliseconds(750) }

    init(
        model: Model,
        presentation: GhosttySurfaceScreenPresentation,
        isSelected: Bool,
        isTerminalCovered: Bool = false,
        shortcutStore: ShortcutStore,
        keyboardSettings: KeyboardSettings = .default,
        isPhysicalKeyboardConnected: Bool = false,
        onAppKeyboardCommand: @escaping (AppKeyboardCommand) -> Void = { _ in },
        attachmentTransferServiceFactory: @escaping @Sendable () -> any GhosttyAttachmentTransferService,
        onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)? = nil,
        onReconnect: @escaping () -> Void,
        onEditConnection: @escaping () -> Void,
        onUpdateCredentials: @escaping () -> Void,
        onEditServer: @escaping () -> Void,
        onTrustHostKey: @escaping () -> Void
    ) {
        self.model = model
        self.presentation = presentation
        self.isSelected = isSelected
        self.isTerminalCovered = isTerminalCovered
        self.shortcutStore = shortcutStore
        self.keyboardSettings = keyboardSettings
        self.isPhysicalKeyboardConnected = isPhysicalKeyboardConnected
        self.onAppKeyboardCommand = onAppKeyboardCommand
        _physicalKeyboardChromeState = State(
            initialValue: PhysicalKeyboardChromeState(
                isPhysicalKeyboardConnected: isPhysicalKeyboardConnected,
                hidesChrome: keyboardSettings.hideButtonBarWhenPhysicalKeyboardConnected
            )
        )
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
        self.onPreviewSelection = onPreviewSelection
        self.onReconnect = onReconnect
        self.onEditConnection = onEditConnection
        self.onUpdateCredentials = onUpdateCredentials
        self.onEditServer = onEditServer
        self.onTrustHostKey = onTrustHostKey
        // First struct init marks when SwiftUI starts building the
        // pushed screen (SwiftUI re-inits view values repeatedly;
        // only the first is the milestone).
        GhosttyRuntimeTrace.flowEventOnce(
            "session.open.\(presentation.workspaceID.uuidString)",
            event: "ui.terminalScreen.init"
        )
    }

    private var isAwaitingSystemKeyboardPresentation: Bool {
        keyboardViewportTransitionCoordinator.isAwaitingSystemKeyboardPresentation
    }

    var body: some View {
        GeometryReader { screenProxy in
            let renderedKeyboardMode = inputCoordinator.keyboardMode
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size
            )
            let screenProjection = model.terminalScreenPresentationProjection
            let readiness = screenProjection.readiness
            let interactionProjection = screenProjection.interaction
            let terminalResponderFocusPolicy = GhosttyTerminalResponderFocusPolicy(
                isSelected: isSelected,
                keyboardMode: inputCoordinator.keyboardMode,
                isInputAvailable: interactionProjection.isInputAvailable,
                isTransientInputOwnerPresented: isTransientInputOwnerPresented
            )
            let paneSelectionSheetTopologyProjection = model.paneSelectionSheetTopologyProjection(
                topLevelID: selectionSheet?.paneTopLevelIDForTopologyValidation
            )

            ZStack {
                presentation.terminalTheme.terminalSurfaceBackground
                    .ignoresSafeArea(.all, edges: .all)

                GeometryReader { proxy in
                    let liveTerminalViewportSize = GhosttyTerminalViewportCoordinator.normalized(proxy.size)
                    let terminalViewportSize = terminalViewportCoordinator.effectiveSize(
                        liveSize: liveTerminalViewportSize
                    )
                    let viewportTraceContext = GhosttyTerminalViewportTraceLayoutContext(
                        screenSize: screenProxy.size,
                        safeAreaInsets: screenProxy.safeAreaInsets,
                        keyboardMode: inputCoordinator.keyboardMode,
                        renderedKeyboardMode: renderedKeyboardMode,
                        bottomChromeHeight: bottomChromeHeight,
                        softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight,
                        lastSoftwareKeyboardOverlapHeight: lastSoftwareKeyboardOverlapHeight,
                        selectionSheet: selectionSheet,
                        isViewportFrozen: isTerminalViewportFrozen,
                        transitionActive: terminalViewportCoordinator.isKeyboardTransitionActive,
                        transitionTarget: terminalViewportCoordinator.keyboardTransitionTarget,
                        awaitingSystemKeyboard: isAwaitingSystemKeyboardPresentation
                    )

                    ZStack(alignment: .topLeading) {
                        GhosttySingleViewportView(
                            surfaceLookup: model.terminalManagedSurfaceLookup,
                            projection: screenProjection.viewport,
                            terminalTheme: presentation.terminalTheme,
                            trackpadDriver: trackpadDriver,
                            onSurfaceTap: handleSurfaceTap,
                            onPreviewSelection: onPreviewSelection,
                            onWindowSwipe: handleWindowSwipe,
                            sendKeyEvent: sendTerminalKeyEvent,
                            onTrackpadFeedbackChange: { trackpadFeedback = $0 },
                            isMouseCaptured: { surfaceID in
                                model.isMouseCaptured(for: surfaceID)
                            },
                            submitMouseButton: { surfaceID, event in
                                model.sendMouseButton(to: surfaceID, event)
                            },
                            submitMousePosition: { surfaceID, position, mods in
                                model.sendMousePosition(to: surfaceID, position, mods: mods)
                            },
                            submitMouseScroll: { surfaceID, event in
                                model.sendMouseScroll(to: surfaceID, event)
                            }
                        )
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .background(presentation.terminalTheme.terminalSurfaceBackground)

                        GhosttyTerminalResponderRepresentable(
                            isEnabled: terminalResponderFocusPolicy.isResponderEnabled,
                            wantsFirstResponder: terminalResponderFocusPolicy.wantsFirstResponder,
                            activationToken: inputCoordinator.terminalActivationToken,
                            trackpadDriver: trackpadDriver,
                            keyboardAppearance: presentation.terminalTheme.terminalKeyboardAppearance,
                            keyboardSettings: keyboardSettings,
                            sendText: sendTerminalText,
                            sendPaste: sendTerminalPaste,
                            sendKeyEvent: sendTerminalKeyEvent,
                            onTrackpadFeedbackChange: { trackpadFeedback = $0 },
                            onFirstResponderChange: { isTerminalResponderFirstResponder = $0 },
                            onAppKeyboardCommand: performAppKeyboardCommand
                        )
                        .frame(
                            width: terminalViewportSize.width,
                            height: terminalViewportSize.height,
                            alignment: .topLeading
                        )
                        .opacity(0.01)
                        .allowsHitTesting(false)

                        GhosttyTerminalScreenAccessibilityMarker()
                            .frame(
                                width: terminalViewportSize.width,
                                height: terminalViewportSize.height,
                                alignment: .topLeading
                            )
                            .allowsHitTesting(false)

                        GhosttyTerminalInputReadyAccessibilityMarker(
                            isReady: TerminalReadinessProjector.uiTestInputReady(readiness)
                        )
                        .frame(width: 1, height: 1, alignment: .topLeading)
                        .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay {
                        GhosttySurfaceStatusOverlay(
                            projection: screenProjection.statusOverlay,
                            loadingTitle: presentation.loadingTitle,
                            onReconnect: onReconnect,
                            onUpdateCredentials: onUpdateCredentials,
                            onEditServer: onEditServer,
                            onCancel: onEditConnection,
                            onTrustHostKey: onTrustHostKey
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        GhosttyKeyboardCursorTrackpadHUD(state: trackpadFeedback)
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                    .onAppear {
                        traceTerminalViewportSnapshot(
                            event: "viewport.appear",
                            liveSize: liveTerminalViewportSize,
                            effectiveSize: terminalViewportSize,
                            context: viewportTraceContext
                        )
                        if isTerminalCovered {
                            updateTerminalCoverPresentation(
                                isCovered: true,
                                liveSize: liveTerminalViewportSize
                            )
                        }
                        updateTerminalViewportLiveSize(
                            liveTerminalViewportSize,
                            context: viewportTraceContext
                        )
                    }
                    .onChange(of: liveTerminalViewportSize) { _, newValue in
                        updateTerminalViewportLiveSize(
                            newValue,
                            context: viewportTraceContext
                        )
                        finishTerminalCoverRestorationIfSettled(liveSize: newValue)
                    }
                    .onChange(of: isTerminalCovered) { _, isCovered in
                        updateTerminalCoverPresentation(
                            isCovered: isCovered,
                            liveSize: liveTerminalViewportSize
                        )
                    }
                    .onChange(of: isTerminalResponderFirstResponder) { _, _ in
                        finishTerminalCoverRestorationIfSettled(
                            liveSize: liveTerminalViewportSize
                        )
                    }
                    .onChange(of: inputCoordinator.isSoftwareKeyboardVisible) { _, _ in
                        finishTerminalCoverRestorationIfSettled(
                            liveSize: liveTerminalViewportSize
                        )
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        updateTerminalViewportLiveSize(
                            liveTerminalViewportSize,
                            context: viewportTraceContext,
                            reconcileStoredSize: true
                        )
                    }
                    .onChange(of: selectionSheet?.id) { _, newValue in
                        traceTerminalViewportSnapshot(
                            event: "selectionSheet.changed",
                            liveSize: liveTerminalViewportSize,
                            effectiveSize: terminalViewportSize,
                            context: viewportTraceContext,
                            extra: ["isPresented": "\(newValue != nil)"]
                        )
                        updateSelectionSheetViewportHold(
                            isPresented: newValue != nil,
                            liveSize: liveTerminalViewportSize
                        )
                    }
                }
            }
            .overlay(alignment: .bottom) {
                shortcutPaletteLayer()
            }
            .overlay(alignment: .bottom) {
                attachmentTrayLayer()
            }
            .overlay(alignment: .bottom) {
                pendingAttachmentLayer()
            }
            .overlay(alignment: .bottom) {
                attachmentNoticeLayer()
            }
            .overlay(alignment: .bottom) {
                if physicalKeyboardChromeState.usesFloatingChrome,
                   physicalKeyboardChromeState.isChromeVisible {
                    keyboardChrome(
                        renderedKeyboardMode: renderedKeyboardMode,
                        interactionProjection: interactionProjection,
                        chrome: chrome
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !physicalKeyboardChromeState.usesFloatingChrome {
                    keyboardChrome(
                        renderedKeyboardMode: renderedKeyboardMode,
                        interactionProjection: interactionProjection,
                        chrome: chrome
                    )
                    .background {
                        GeometryReader { chromeProxy in
                            Color.clear.preference(
                                key: GhosttyBottomChromeHeightPreferenceKey.self,
                                value: chromeProxy.size.height
                            )
                        }
                    }
                }
            }
            .onPreferenceChange(GhosttyBottomChromeHeightPreferenceKey.self) { newHeight in
                let normalizedHeight = GhosttySelectionSheetSizing.normalizedHeight(newHeight)
                guard bottomChromeHeight != normalizedHeight else { return }
                GhosttyRuntimeTrace.tmuxViewport(
                    "viewport.bottomChrome old=\(bottomChromeHeight.traceLabel) new=\(normalizedHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel) renderedMode=\(renderedKeyboardMode.traceLabel) softwareKeyboardVisible=\(inputCoordinator.isSoftwareKeyboardVisible) overlap=\(softwareKeyboardOverlapHeight.traceLabel)"
                )
                bottomChromeHeight = normalizedHeight
            }
            .onChange(of: isPhysicalKeyboardConnected) { _, connected in
                physicalKeyboardChromeState.keyboardConnectionChanged(
                    isConnected: connected,
                    hidesChrome: keyboardSettings.hideButtonBarWhenPhysicalKeyboardConnected
                )
                if connected {
                    bottomChromeHeight = 0
                }
            }
            .onChange(of: keyboardSettings.hideButtonBarWhenPhysicalKeyboardConnected) { _, hides in
                physicalKeyboardChromeState.keyboardConnectionChanged(
                    isConnected: isPhysicalKeyboardConnected,
                    hidesChrome: hides
                )
            }
            .task(id: physicalKeyboardChromeState.autoHideToken) {
                guard let token = physicalKeyboardChromeState.autoHideToken else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                physicalKeyboardChromeState.autoHideElapsed(token: token)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.willChangeFrame")
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.willHide")
                updateKeyboardVisibility(with: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.didShow")
                completeKeyboardDidShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.didHide")
                completeKeyboardDidHide()
            }
            .sheet(item: selectionSheetBinding) { sheet in
                selectionSheetContent(sheet)
                    .presentationDetents(selectionSheetDetents(for: sheet))
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
                    .ghosttySelectionSheetPresentationBackground()
                    .ghosttyTerminalChromePresentation(
                        presentation.terminalTheme.terminalChromeColorScheme,
                        chromeStyle: presentation.terminalTheme.terminalChromeStyle
                    )
            }
            .sheet(isPresented: $isShortcutsSettingsPresented) {
                ShortcutsSettingsSheet(store: shortcutStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationCornerRadius(28)
                    .ghosttyTerminalChromePresentation(
                        presentation.terminalTheme.terminalChromeColorScheme,
                        chromeStyle: presentation.terminalTheme.terminalChromeStyle
                    )
            }
            .sheet(item: $shortcutEditorRequest) { request in
                ShortcutEditorSheet(request: request) { shortcut, favorite in
                    shortcutStore.update {
                        $0.upsertShortcut(shortcut)
                        if favorite {
                            $0.setFavorite(true, shortcutID: shortcut.id)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
                .ghosttyTerminalChromePresentation(
                    presentation.terminalTheme.terminalChromeColorScheme,
                    chromeStyle: presentation.terminalTheme.terminalChromeStyle
                )
            }
            .sheet(isPresented: $isAttachmentPreviewPresented) {
                GhosttyAttachmentPreviewSheet(
                    attachments: $pendingAttachments
                )
                .presentationDetents([.medium, .large], selection: $attachmentPreviewDetent)
                .presentationDragIndicator(.visible)
                .ghosttySelectionSheetPresentationBackground()
                .ghosttyTerminalChromePresentation(
                    presentation.terminalTheme.terminalChromeColorScheme,
                    chromeStyle: presentation.terminalTheme.terminalChromeStyle
                )
            }
            .photosPicker(
                isPresented: $isAttachmentPhotosPickerPresented,
                selection: $attachmentPhotoSelections,
                maxSelectionCount: Self.maxAttachmentPhotoSelectionCount,
                selectionBehavior: .ordered,
                matching: .images
            )
            .fileImporter(
                isPresented: $isAttachmentFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: handleAttachmentFileSelection
            )
            .onChange(of: paneSelectionSheetTopologyProjection) { _, projection in
                guard projection.shouldDismissPaneSheet else { return }
                dismissSelectionSheet()
            }
            .onChange(of: attachmentPhotoSelections) { _, items in
                guard !items.isEmpty else { return }
                attachmentPhotoSelections = []
                handleAttachmentPhotoSelection(items)
            }
            .onChange(of: pendingAttachments) { _, attachments in
                guard attachments.isEmpty else { return }
                isAttachmentPreviewPresented = false
            }
            .onChange(of: isAttachmentPreviewPresented) { _, isPresented in
                guard !isPresented else { return }
                attachmentPreviewDetent = .medium
            }
            .onChange(of: interactionProjection.selectedActiveLeafID) { _, activeLeafID in
                handleActiveLeafChange(activeLeafID)
            }
            .onChange(of: interactionProjection.isInputAvailable) { _, isInputAvailable in
                handleTerminalCoverInputAvailabilityChange(isInputAvailable)
            }
            .onChange(of: inputCoordinator.keyboardMode) { _, mode in
                // Sizes reported while the software keyboard is up are
                // transient; flag them so reconnects carry the settled
                // viewport (the mode flips before the layout changes,
                // so the hint always precedes the affected report).
                model.setViewportStabilityHint(stable: mode == .hidden)
                if mode == .hidden, terminalCoverPhase.isRestoringKeyboard {
                    cancelTerminalCoverKeyboardRestoration(reason: "keyboardHidden")
                }
            }
            .onChange(of: model.commandFailureEvent) { _, event in
                handleTmuxCommandFailureEvent(event)
            }
#if DEBUG
            .task {
                if CommandLine.arguments.contains("--open-panes-after-warmup") {
                    for _ in 0..<60 {
                        if model.terminalInteractionProjection.paneCount > 0 {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            showPanes()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
#endif
        }
        .preferredColorScheme(presentation.terminalTheme.terminalChromeColorScheme)
        .environment(\.ghosttyTerminalChromeStyle, presentation.terminalTheme.terminalChromeStyle)
        .onAppear {
            GhosttyRuntimeTrace.flowEvent(
                sessionOpenFlowID,
                event: "ui.terminalScreen.appear",
                fields: [
                    "session": presentation.sessionName,
                    "workspaceID": presentation.workspaceID.uuidString,
                ]
            )
            handleScenePhaseChange(scenePhase)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: isSelected) { _, selected in
            handleTerminalCoverSelectionChange(selected)
        }
    }

    private var shouldHandleTerminalKeyboardNotification: Bool {
        isSelected
            && !isShortcutsSettingsPresented
            && shortcutEditorRequest == nil
            && !isAttachmentPreviewPresented
    }

    private var isAttachmentInputOwnerPresented: Bool {
        GhosttyAttachmentInputOwnerProjection(
            isTrayPresented: isAttachmentTrayPresented,
            isPhotosPickerPresented: isAttachmentPhotosPickerPresented,
            isFileImporterPresented: isAttachmentFileImporterPresented,
            isPreviewPresented: isAttachmentPreviewPresented
        ).isTransientInputOwnerPresented
    }

    private var isTransientInputOwnerPresented: Bool {
        isAttachmentInputOwnerPresented || terminalCoverPhase.ownsTerminalInput
    }

    private var selectionSheetBinding: Binding<GhosttySurfaceSelectionSheet?> {
        Binding(
            get: { selectionSheet },
            set: { applySelectionSheetPresentation($0) }
        )
    }

    private var isTerminalInputAvailable: Bool {
        model.terminalInteractionProjection.isInputAvailable
    }

    private var isTerminalViewportFrozen: Bool {
        terminalViewportCoordinator.isFrozen
    }

    private var hasPendingAttachments: Bool {
        !pendingAttachments.isEmpty
    }

    private var canSendPendingAttachments: Bool {
        !isAttachmentTransferInProgress
            && !pendingAttachments.isEmpty
            && pendingAttachments.allSatisfy { $0.transferSource != nil }
    }

    private var pendingAttachmentInteractionProjection: GhosttyPendingAttachmentInteractionProjection {
        GhosttyPendingAttachmentInteractionProjection(
            hasPreviewableAttachments: pendingAttachments.contains(where: \.isPreviewable),
            isTransferInProgress: isAttachmentTransferInProgress
        )
    }

    private func showSystemKeyboard() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.showSystemKeyboard")
        let isInputAvailable = isTerminalInputAvailable
        guard isInputAvailable else { return }

        performKeyboardChromeStateChange {
            if inputCoordinator.keyboardMode == .hidden {
                let projection = GhosttyKeyboardToggleProjection(
                    keyboardMode: inputCoordinator.keyboardMode,
                    isInputAvailable: isInputAvailable
                )
                if let request = keyboardViewportTransitionCoordinator.transitionRequest(
                    forToggle: projection
                ) {
                    _ = beginKeyboardViewportTransition(request)
                }
            }
            inputCoordinator.showSystemKeyboard(isInputAvailable: isInputAvailable)
        }
    }

    private func handleSurfaceTap(_ surfaceID: UUID) {
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.surface",
            fields: [
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let isInputAvailable = isTerminalInputAvailable
        if physicalKeyboardChromeState.usesFloatingChrome {
            withAnimation(.easeOut(duration: 0.18)) {
                physicalKeyboardChromeState.terminalTapped()
            }
            GhosttyRuntimeTrace.flowEvent(
                "terminal.input",
                event: "ui.tap.surface.end",
                fields: ["activated": "\(isInputAvailable)"]
            )
            return
        }
        showSystemKeyboard()
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.tap.surface.end",
            fields: ["activated": "\(isInputAvailable)"]
        )
    }

    private func handleWindowSwipe(_ direction: GhosttyRuntimeSelectionDirection) {
        let traceStartedAt = GhosttyRuntimeTrace.flowTraceEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        let didFocus = model.focusAdjacentTmuxTopLevel(direction).isHandled
        if let traceStartedAt {
            GhosttyRuntimeTrace.flowEventIfActive(
                "tmux.windowSwipe",
                event: "ui.swipe.modelReturned",
                fields: [
                    "direction": "\(direction)",
                    "focused": "\(didFocus)",
                    "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: traceStartedAt),
                ]
            )
        }
        if !didFocus, traceStartedAt != nil {
            GhosttyRuntimeTrace.flowEndIfActive(
                "tmux.windowSwipe",
                event: "ui.swipe.rejected",
                fields: ["direction": "\(direction)"]
            )
        }
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
    }

    private func performAppKeyboardCommand(_ command: AppKeyboardCommand) {
        switch command {
        case .previousWindow:
            handleWindowSwipe(.previous)
        case .nextWindow:
            handleWindowSwipe(.next)
        case .windows:
            showWindows()
        case .panes:
            showPanes()
        case .attachments:
            toggleAttachmentTray()
        case .previousSession, .nextSession, .home, .commandPalette:
            onAppKeyboardCommand(command)
        }
    }

    private func keyboardChrome(
        renderedKeyboardMode: GhosttyKeyboardChromeMode,
        interactionProjection: GhosttyTerminalInteractionProjection,
        chrome: GhosttyPhoneChromeLayout
    ) -> some View {
        GhosttyKeyboardChrome(
            keyboardMode: renderedKeyboardMode,
            isEnabled: interactionProjection.isInputAvailable,
            isCompact: chrome.isCompact,
            isControlArmed: terminalInputController.isControlArmed,
            selectedWindowIndex: interactionProjection.selectedWindowIndex,
            windowCount: interactionProjection.windowCount,
            selectedPaneIndex: interactionProjection.selectedPaneIndex,
            paneCount: interactionProjection.paneCount,
            isAttachmentControlActive: isAttachmentTrayPresented,
            isAttachmentControlEnabled: !hasPendingAttachments,
            pendingAttachmentCount: pendingAttachments.count,
            onShowHome: { performChromeInteraction(onEditConnection) },
            onShowWindows: { performChromeInteraction(showWindows) },
            onShowPanes: { performChromeInteraction(showPanes) },
            onShowAttachments: { performChromeInteraction(toggleAttachmentTray) },
            onToggleKeyboard: { performChromeInteraction(toggleKeyboardChrome) },
            onToggleControl: { performChromeInteraction(toggleControlModifier) },
            onShowShortcuts: { performChromeInteraction(showShortcutPalette) },
            sendKey: { event in
                physicalKeyboardChromeState.chromeInteracted()
                return sendTerminalKeyEvent(event)
            }
        )
        .padding(.horizontal, chrome.surfaceHorizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, chrome.bottomPadding)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private func performChromeInteraction(_ action: () -> Void) {
        physicalKeyboardChromeState.chromeInteracted()
        action()
    }

    private func toggleKeyboardChrome() {
        let isInputAvailable = isTerminalInputAvailable
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.keyboardToggle",
            fields: [
                "inputAvailable": "\(isInputAvailable)",
                "mode": "\(inputCoordinator.keyboardMode)",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: inputCoordinator.keyboardMode,
            isInputAvailable: isInputAvailable
        )
        GhosttyRuntimeTrace.perf(
            "kbd.toggleKeyboard from=\(projection.previousMode.traceLabel) to=\(projection.expectedMode.traceLabel) inputAvailable=\(projection.isInputAvailable) startsSystemTransition=\(projection.startsSystemKeyboardTransition)"
        )

        performKeyboardChromeStateChange {
            keyboardViewportTransitionCoordinator.performKeyboardToggleTransition(
                projection: projection,
                beginTransition: { request in
                    _ = beginKeyboardViewportTransition(request)
                },
                applyKeyboardToggle: {
                    inputCoordinator.toggleKeyboard(isInputAvailable: projection.isInputAvailable)
                    return inputCoordinator.keyboardMode
                },
                completeTransition: completeKeyboardViewportTransition
            )
        }
    }

    private func refocusSystemKeyboardIfActive() {
        inputCoordinator.refocusSystemKeyboardIfActive(isInputAvailable: isTerminalInputAvailable)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if terminalCoverPhase.isRestoringKeyboard {
            guard phase == .active else { return }
            resumeTerminalCoverKeyboardRestorationIfPossible()
            return
        }

        guard !terminalCoverPhase.ownsTerminalInput else { return }
        let projection = GhosttySurfaceScreenLifecycleProjection(
            scenePhase: phase,
            isSelected: isSelected
        )

        guard projection.shouldRefocusSystemKeyboard else { return }
        refocusSystemKeyboardIfActive()
    }

    private func updateTerminalCoverPresentation(
        isCovered: Bool,
        liveSize: CGSize
    ) {
        if isCovered {
            guard !terminalCoverPhase.ownsTerminalInput else { return }
            let effect = terminalViewportCoordinator.setCoveredPresentation(
                true,
                liveSize: liveSize
            )
            let restoreKeyboard = inputCoordinator.keyboardMode == .system
                && inputCoordinator.isSoftwareKeyboardVisible
            terminalCoverPhase = .covered(restoreKeyboard: restoreKeyboard)
            if case .hold(let effectiveSize) = effect {
                GhosttyRuntimeTrace.perf(
                    "viewport.freeze begin reason=coveredPresentation effective=\(effectiveSize.traceLabel) live=\(liveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
                )
            }
            return
        }

        guard case .covered(let restoreKeyboard) = terminalCoverPhase else { return }
        guard restoreKeyboard else {
            finishTerminalCoverPresentation(
                liveSize: liveSize,
                releaseKind: "coveredPresentationHiddenKeyboard"
            )
            return
        }
        guard isSelected, isTerminalInputAvailable else {
            finishTerminalCoverPresentation(
                liveSize: liveSize,
                releaseKind: "coveredPresentationCancelled"
            )
            return
        }

        terminalCoverPhase = .restoringKeyboard
        if finishTerminalCoverRestorationIfSettled(liveSize: liveSize) {
            return
        }
        resumeTerminalCoverKeyboardRestorationIfPossible()
    }

    @discardableResult
    private func finishTerminalCoverRestorationIfSettled(liveSize: CGSize) -> Bool {
        guard terminalCoverPhase.isRestoringKeyboard,
              !isTerminalCovered,
              scenePhase == .active,
              isSelected,
              isTerminalInputAvailable,
              inputCoordinator.keyboardMode == .system,
              isTerminalResponderFirstResponder,
              inputCoordinator.isSoftwareKeyboardVisible else {
            return false
        }

        let normalizedLiveSize = GhosttyTerminalViewportCoordinator.normalized(liveSize)
        let heldSize = terminalViewportCoordinator.effectiveSize(liveSize: liveSize)
        guard normalizedLiveSize == heldSize else { return false }

        finishTerminalCoverPresentation(
            liveSize: liveSize,
            releaseKind: "coveredPresentationAlreadySettled"
        )
        return true
    }

    private func resumeTerminalCoverKeyboardRestorationIfPossible() {
        guard terminalCoverPhase.isRestoringKeyboard,
              !isTerminalCovered,
              scenePhase == .active,
              isSelected,
              isTerminalInputAvailable else {
            return
        }

        refocusSystemKeyboardIfActive()
    }

    private func handleTerminalCoverSelectionChange(_ selected: Bool) {
        guard terminalCoverPhase.isRestoringKeyboard else { return }
        guard selected else {
            cancelTerminalCoverKeyboardRestoration(reason: "selection")
            return
        }
        resumeTerminalCoverKeyboardRestorationIfPossible()
    }

    private func handleTerminalCoverInputAvailabilityChange(_ isInputAvailable: Bool) {
        guard terminalCoverPhase.isRestoringKeyboard else { return }
        guard isInputAvailable else {
            cancelTerminalCoverKeyboardRestoration(reason: "inputUnavailable")
            return
        }
        resumeTerminalCoverKeyboardRestorationIfPossible()
    }

    private func cancelTerminalCoverKeyboardRestoration(reason: String) {
        finishTerminalCoverPresentation(
            liveSize: terminalViewportCoordinator.latestLiveSize,
            releaseKind: "coveredPresentationCancel.\(reason)"
        )
    }

    private func applyTopologyInputRefocusEffect(
        _ effect: GhosttyTopologyActionInputRefocusCoordinator.Effect
    ) -> GhosttyTopologyActionInputRefocusCoordinator.EffectApplicationFeedback {
        switch effect {
        case .requestRefocus:
            _ = terminalViewportCoordinator.requestTopologyRefocus(
                liveSize: terminalViewportCoordinator.latestLiveSize
            )
            let didStartKeyboardTransition = beginKeyboardViewportTransition(
                GhosttyKeyboardViewportTransitionRequest(
                    target: .shown,
                    allowsTargetOverride: true
                )
            )
            if didStartKeyboardTransition {
                return .refocusKeyboardTransitionStarted
            }
            return .none

        case .dismissSelectionSheet:
            dismissSelectionSheet()
            return .none

        case .cancelRefocus(let ownsKeyboardTransition):
            cancelTopologyInputRefocus(ownsKeyboardTransition: ownsKeyboardTransition)
            return .none

        case .completeRefocus:
            completeTopologyInputRefocus()
            return .none
        }
    }

    private func cancelTopologyInputRefocus(ownsKeyboardTransition: Bool) {
        let effect = terminalViewportCoordinator.cancelTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        guard case .release(let previousEffectiveSize) = effect else { return }
        if ownsKeyboardTransition, terminalViewportCoordinator.isKeyboardTransitionActive {
            completeKeyboardViewportTransition()
        }
        completeTerminalViewportHoldRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: "topologyCancel"
        )
    }

    @discardableResult
    private func performTopologyActionInteraction(
        _ actionEffect: GhosttyTmuxTopologyActionInteractionEffect,
        action: () -> GhosttyTmuxModelActionOutcome
    ) -> GhosttyTmuxModelActionOutcome {
        topologyActionInputRefocusCoordinator.perform(
            actionEffect: actionEffect,
            activeLeafID: model.terminalInteractionProjection.selectedActiveLeafID,
            keyboardMode: inputCoordinator.keyboardMode,
            apply: applyTopologyInputRefocusEffect,
            action: action
        )
    }

    private func handleActiveLeafChange(_ activeLeafID: UUID?) {
        guard let effect = topologyActionInputRefocusCoordinator.consumeActiveLeafChange(to: activeLeafID) else {
            return
        }

        _ = applyTopologyInputRefocusEffect(effect)
    }

    private func completeTopologyInputRefocus() {
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.topologySelectionRefocus",
            fields: terminalInputTraceFields()
        )
        inputCoordinator.handleSelectionChange(isInputAvailable: isTerminalInputAvailable)
        let effect = terminalViewportCoordinator.completeTopologyRefocus(
            liveSize: terminalViewportCoordinator.latestLiveSize,
            releasePolicy: .preserveCurrentEffective
        )
        guard case .release(let previousEffectiveSize) = effect else { return }
        completeTerminalViewportHoldRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: "topologyRefocus"
        )
    }

    private func handleTmuxCommandFailureEvent(_ event: GhosttyTmuxCommandFailureEvent?) {
        guard let event else { return }
        guard let effect = topologyActionInputRefocusCoordinator.cancelForCommandFailure() else { return }

        GhosttyRuntimeTrace.perf(
            "topology.refocus cancel reason=tmuxCommandFailure token=\(event.token)"
        )
        _ = applyTopologyInputRefocusEffect(effect)
    }

    @ViewBuilder
    private func shortcutPaletteLayer() -> some View {
        if isShortcutPalettePresented {
            ZStack(alignment: .bottom) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isShortcutPalettePresented = false
                    }

                ShortcutPalette(
                    store: shortcutStore,
                    executeShortcut: executeShortcut,
                    onAddShortcut: {
                        isShortcutPalettePresented = false
                        guard let defaultCollection = shortcutStore.snapshot.defaultShortcutCollectionID else {
                            isShortcutsSettingsPresented = true
                            return
                        }
                        shortcutEditorRequest = .new(
                            defaultCollection: defaultCollection,
                            favoriteOnSave: true,
                            snapshot: shortcutStore.snapshot
                        )
                    },
                    onEditShortcut: {
                        isShortcutPalettePresented = false
                        shortcutEditorRequest = .edit($0, snapshot: shortcutStore.snapshot)
                    },
                    onOpenSettings: {
                        isShortcutPalettePresented = false
                        isShortcutsSettingsPresented = true
                    }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func attachmentTrayLayer() -> some View {
        if isAttachmentTrayPresented {
            ZStack(alignment: .bottom) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissAttachmentTray()
                    }

                GhosttyAttachmentTray(
                    onPhotosSelected: openAttachmentPhotosPicker,
                    onFilesSelected: openAttachmentFilePicker,
                    onPasteSelected: handleAttachmentPasteSelection
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    @ViewBuilder
    private func pendingAttachmentLayer() -> some View {
        if hasPendingAttachments, !isAttachmentTrayPresented {
            GhosttyPendingAttachmentPreview(
                attachments: pendingAttachments,
                canSend: canSendPendingAttachments,
                isSending: isAttachmentTransferInProgress,
                sendUploadCount: attachmentTransferUploadCount,
                sendProgress: attachmentTransferProgress,
                onOpen: showPendingAttachmentPreview,
                onSend: sendPendingAttachments,
                onRemove: clearPendingAttachments
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(2)
        }
    }

    @ViewBuilder
    private func attachmentNoticeLayer() -> some View {
        if let attachmentNotice {
            GhosttyAttachmentNoticeBanner(notice: attachmentNotice)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
        }
    }

    private func clearPendingAttachments() {
        guard hasPendingAttachments, !isAttachmentTransferInProgress else { return }
        let attachments = pendingAttachments
        withAnimation(.easeOut(duration: 0.14)) {
            pendingAttachments.removeAll()
        }
        GhosttyAttachmentStagingStore.cleanup(attachments)
    }

    private func showPendingAttachmentPreview() {
        guard pendingAttachmentInteractionProjection.canOpenPreview else { return }
        attachmentPreviewDetent = .medium
        isAttachmentPreviewPresented = true
    }

    private func sendPendingAttachments() {
        guard canSendPendingAttachments else {
            presentAttachmentNotice("Attachment is still loading.")
            return
        }

        guard isTerminalInputAvailable else {
            presentAttachmentNotice("Terminal is not ready.")
            return
        }

        guard let targetSurfaceID = model.terminalInteractionProjection.selectedActiveLeafID else {
            presentAttachmentNotice("Terminal is not ready.")
            return
        }

        let attachments = pendingAttachments
        let job: GhosttyAttachmentTransferJob
        do {
            job = try GhosttyAttachmentTransferJobBuilder.job(
                workspaceID: presentation.workspaceID,
                attachments: attachments
            )
        } catch {
            presentAttachmentNotice("Attachment is still loading.")
            return
        }

        isAttachmentTransferInProgress = true
        attachmentTransferUploadCount = job.uploadSourceCount
        attachmentTransferProgress = nil
        isAttachmentPreviewPresented = false
        attachmentNotice = nil

        Task {
            let service = attachmentTransferServiceFactory()
            do {
                let result = try await service.transfer(job) { progress in
                    await MainActor.run {
                        attachmentTransferProgress = progress
                    }
                }
                let insertionText = GhosttyAttachmentTerminalInsertionFormatter.insertionText(for: result)
                await MainActor.run {
                    completePendingAttachmentSend(
                        insertionText: insertionText,
                        attachments: attachments,
                        targetSurfaceID: targetSurfaceID
                    )
                }
            } catch {
                await MainActor.run {
                    handlePendingAttachmentSendFailure(error)
                }
            }
        }
    }

    private func completePendingAttachmentSend(
        insertionText: String,
        attachments: [GhosttyPendingAttachment],
        targetSurfaceID: UUID
    ) {
        isAttachmentTransferInProgress = false
        attachmentTransferUploadCount = 0
        attachmentTransferProgress = nil

        guard !insertionText.isEmpty else {
            presentAttachmentNotice("No attachment content to insert.")
            return
        }

        guard sendTerminalPaste(insertionText, to: targetSurfaceID) else {
            presentAttachmentNotice("Could not insert attachment.")
            return
        }

        withAnimation(.easeOut(duration: 0.14)) {
            pendingAttachments.removeAll()
            isAttachmentPreviewPresented = false
        }
        GhosttyAttachmentStagingStore.cleanup(attachments)
    }

    private func handlePendingAttachmentSendFailure(_ error: Error) {
        isAttachmentTransferInProgress = false
        attachmentTransferUploadCount = 0
        attachmentTransferProgress = nil
        presentAttachmentNotice(pendingAttachmentSendFailureMessage(for: error))
    }

    private func pendingAttachmentSendFailureMessage(for error: Error) -> String {
        guard let transferError = error as? GhosttyAttachmentTransferError else {
            return "Attachment send failed."
        }

        switch transferError {
        case .noSources, .localSourceUnavailable:
            return "Attachment is not ready."
        case .securityScopedSourceUnavailable:
            return "File needs to be selected again."
        case .remoteDirectoryCreationFailed:
            return "Server could not create the upload folder."
        case .uploadFailed, .remoteRenameFailed:
            return "Server could not save the attachment."
        case .remoteOperationTimedOut:
            return "Connection stalled while uploading. Check network or VPN."
        case .remotePathResolutionFailed:
            return "Remux could not start the upload. Try again."
        case .cancelled:
            return "Attachment send cancelled."
        case .terminalInsertionFailed:
            return "Could not insert attachment."
        }
    }

    private func openAttachmentPhotosPicker() {
        dismissAttachmentTray()
        isAttachmentPhotosPickerPresented = true
    }

    private func openAttachmentFilePicker() {
        dismissAttachmentTray()
        isAttachmentFileImporterPresented = true
    }

    private func handleAttachmentPhotoSelection(_ items: [PhotosPickerItem]) {
        let attachments = GhosttyPendingAttachment.mediaSelections(
            contentTypes: items.map(\.supportedContentTypes)
        )

        guard !attachments.isEmpty else {
            presentAttachmentNotice("No media selected.")
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            replacePendingAttachments(attachments)
            attachmentNotice = nil
        }

        for (item, attachment) in zip(items, attachments) {
            loadPhotoPreview(item, for: attachment)
        }
    }

    private func loadPhotoPreview(_ item: PhotosPickerItem, for attachment: GhosttyPendingAttachment) {
        let attachmentID = attachment.id

        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) else {
            updatePendingAttachment(
                id: attachmentID,
                detail: "Preview unavailable"
            )
            return
        }

        Task {
            do {
                guard let transfer = try await item.loadTransferable(
                    type: GhosttyPhotoPickerTransfer.self
                ) else {
                    await MainActor.run {
                        updatePendingAttachment(
                            id: attachmentID,
                            detail: "Preview unavailable"
                        )
                    }
                    return
                }

                let stagedURL = try await GhosttyAttachmentStagingStore.renameStagedFile(
                    transfer.stagedURL,
                    filename: GhosttyAttachmentStagingStore.imageFilename(
                        title: attachment.title,
                        contentTypes: item.supportedContentTypes,
                        uniqueID: attachment.id
                    )
                )
                guard let photo = await GhosttyPendingAttachment.photo(
                    title: attachment.title,
                    stagedFileURL: stagedURL
                ) else {
                    await MainActor.run {
                        updatePendingAttachment(
                            id: attachmentID,
                            detail: "Preview unavailable"
                        )
                    }
                    return
                }

                let didApply = await MainActor.run { () -> Bool in
                    guard pendingAttachments.contains(where: { $0.id == attachmentID }) else {
                        return false
                    }
                    updatePendingAttachment(
                        id: attachmentID,
                        payload: photo.payload,
                        previewPayload: photo.previewPayload,
                        detail: photo.detail
                    )
                    return true
                }
                if !didApply {
                    GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
                }
            } catch {
                await MainActor.run {
                    updatePendingAttachment(
                        id: attachmentID,
                        detail: "Preview unavailable"
                    )
                }
            }
        }
    }

    private func updatePendingAttachment(
        id: UUID,
        payload: GhosttyAttachmentPayload? = nil,
        previewPayload: GhosttyAttachmentPreviewPayload? = nil,
        detail: String
    ) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index] = pendingAttachments[index].updating(
            payload: payload,
            previewPayload: previewPayload,
            detail: detail
        )
    }

    private func handleAttachmentFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                presentAttachmentNotice("No file selected.")
                return
            }

            Task {
                do {
                    let attachments = try await Task.detached(priority: .utility) {
                        try GhosttyPendingAttachment.securityScopedFiles(urls: urls)
                    }.value
                    await MainActor.run {
                        guard !attachments.isEmpty else {
                            presentAttachmentNotice("No file selected.")
                            return
                        }

                        withAnimation(.easeOut(duration: 0.16)) {
                            replacePendingAttachments(attachments)
                            attachmentNotice = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        presentAttachmentNotice("File selection failed.")
                    }
                }
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }
            presentAttachmentNotice("File selection failed.")
        }
    }

    private func handleAttachmentPasteSelection() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot.current()
        if snapshot.hasImages {
            let attachment = GhosttyPendingAttachment.pasteboardImagePlaceholder()
            withAnimation(.easeOut(duration: 0.16)) {
                replacePendingAttachments([attachment])
                isAttachmentTrayPresented = false
                attachmentNotice = nil
            }
            loadPasteboardImageAttachment(for: attachment.id)
            return
        }

        let attachments = snapshot.pendingAttachments
        guard !attachments.isEmpty else {
            dismissAttachmentTray()
            presentAttachmentNotice(snapshot.emptyPasteMessage)
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            replacePendingAttachments(attachments)
            isAttachmentTrayPresented = false
            attachmentNotice = nil
        }
    }

    private func replacePendingAttachments(_ attachments: [GhosttyPendingAttachment]) {
        let oldAttachments = pendingAttachments
        pendingAttachments = attachments
        GhosttyAttachmentStagingStore.cleanup(oldAttachments)
    }

    private func loadPasteboardImageAttachment(for attachmentID: UUID) {
        Task {
            let attachment = await GhosttyAttachmentPasteboardSnapshot.currentImageAttachment()

            let didApply = await MainActor.run { () -> Bool in
                guard pendingAttachments.contains(where: { $0.id == attachmentID }) else {
                    return false
                }
                guard let attachment else {
                    updatePendingAttachment(
                        id: attachmentID,
                        detail: "Preview unavailable"
                    )
                    return true
                }

                updatePendingAttachment(
                    id: attachmentID,
                    payload: attachment.payload,
                    previewPayload: attachment.previewPayload,
                    detail: "Image"
                )
                return true
            }
            if !didApply, let attachment {
                GhosttyAttachmentStagingStore.cleanup([attachment])
            }
        }
    }

    private func presentAttachmentNotice(_ message: String) {
        let notice = GhosttyAttachmentNotice(message: message)
        withAnimation(.easeOut(duration: 0.16)) {
            attachmentNotice = notice
        }

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard attachmentNotice?.id == notice.id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                attachmentNotice = nil
            }
        }
    }

    private func showShortcutPalette() {
        terminalInputController.clearControl()
        dismissAttachmentTray()
        isShortcutPalettePresented = true
    }

    private func toggleAttachmentTray() {
        terminalInputController.clearControl()
        isShortcutPalettePresented = false

        if isAttachmentTrayPresented {
            dismissAttachmentTray()
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                isAttachmentTrayPresented = true
            }
        }
    }

    private func dismissAttachmentTray() {
        guard isAttachmentTrayPresented else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            isAttachmentTrayPresented = false
        }
    }

    private func executeShortcut(_ shortcut: Shortcut) {
        Task { @MainActor in
            let executor = ShortcutExecutor(
                sendText: sendTerminalText,
                sendKey: sendTerminalKeyEvent
            )
            if await executor.execute(shortcut) {
                isShortcutPalettePresented = false
            }
        }
    }

    private func toggleControlModifier() {
        terminalInputController.toggleControl()
        if terminalInputController.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    private func showWindows() {
        guard let projection = model.windowSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
        captureSelectionSheetBottomReplacementHeight()
        applySelectionSheetPresentation(
            .windows(
                makeWindowPreviewSession(leafIDs: projection.previewLeafIDs)
            )
        )
    }

    private func makeWindowPreviewSession(leafIDs: [UUID]) -> GhosttyPanePreviewSession {
        model.makePanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: .windowGridForCurrentScreen
        )
    }

    private func dismissSelectionSheet() {
        applySelectionSheetPresentation(nil)
    }

    private func applySelectionSheetPresentation(_ newValue: GhosttySurfaceSelectionSheet?) {
        let change = selectionSheetPresentationState.apply(nextKind: newValue?.presentationKind)
        if change.shouldCancelCurrentPreviewSession {
            cancelSelectionSheetPreviewSession(selectionSheet)
        }

        selectionSheet = newValue
    }

    private func cancelSelectionSheetPreviewSession(_ sheet: GhosttySurfaceSelectionSheet?) {
        switch sheet {
        case .windows(let session), .panes(_, let session):
            session.cancelAll()
        case .none:
            break
        }
    }

    private func selectionSheetDetents(
        for sheet: GhosttySurfaceSelectionSheet
    ) -> Set<PresentationDetent> {
        switch sheet {
        case .windows(_):
            let cellCount = model.windowSheetDetentCellCount()
            switch PanePreviewLayout.windowMetricsForCurrentScreen(cellCount: cellCount).sheetDetent {
            case .fixed(let height):
                return [
                    .height(
                        GhosttySelectionSheetSizing.fixedDetentHeight(
                            preferredHeight: height,
                            bottomReplacementHeight: selectionSheetPresentationState.bottomReplacementHeight
                        )
                    ),
                ]
            case .large:
                return [.large]
            }

        case .panes(let topLevelID, _):
            let paneCount = model.paneSheetDetentPaneCount(topLevelID: topLevelID)
            switch PanePreviewLayout.metricsForCurrentScreen(for: paneCount).sheetDetent {
            case .fixed(let height):
                return [
                    .height(
                        GhosttySelectionSheetSizing.fixedDetentHeight(
                            preferredHeight: height,
                            bottomReplacementHeight: selectionSheetPresentationState.bottomReplacementHeight
                        )
                    ),
                ]
            case .large:
                return [.large]
            }
        }
    }

    private func showPanes() {
        guard let projection = model.selectedPaneSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.splitPane", event: "ui.showPanes")

        // Carry the preview session in the sheet payload itself so the pane
        // sheet never renders against a separate optional state that may lag
        // the presentation transaction.
        captureSelectionSheetBottomReplacementHeight()
        applySelectionSheetPresentation(
            .panes(
                topLevelID: projection.topLevelID,
                previews: model.makePanePreviewSession(
                    leafIDs: projection.previewLeafIDs,
                    previewSizing: .paneGridForCurrentScreen
                )
            )
        )
    }

    private func updateSelectionSheetViewportHold(
        isPresented: Bool,
        liveSize: CGSize
    ) {
        let effect = terminalViewportCoordinator.setSheetPresented(isPresented, liveSize: liveSize)
        switch effect {
        case .hold(let effectiveSize):
            GhosttyRuntimeTrace.perf(
                "viewport.freeze begin reason=sheet effective=\(effectiveSize.traceLabel) live=\(liveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
        case .release(let previousEffectiveSize):
            completeTerminalViewportHoldRelease(
                previousEffectiveSize: previousEffectiveSize,
                releaseKind: "sheet"
            )
        }
    }

    private func sendTerminalText(_ text: String) -> Bool {
        terminalInputController.performTextInput(
            text,
            submit: submitTerminalText(_:),
            schedulePrefixFlush: scheduleTmuxPrefixInputFlush(token:),
            enterCopyMode: {
                let outcome = model.enterFocusedTmuxCopyMode()
                if outcome.isQueued {
                    GhosttyRuntimeTrace.flowEventIfActive(
                        "terminal.input",
                        event: "ui.tmuxPrefix.copyMode.queued"
                    )
                    return true
                }
                return false
            }
        )
    }

    private func submitTerminalText(_ outbound: String) -> Bool {
        let start = GhosttyRuntimeTrace.nowNanos()
        let submittedAt = GhosttyRuntimeTrace.latencyEnabled ? start : nil
        if let submittedAt {
            GhosttyRuntimeTrace.registerLatencyMarkers(
                in: outbound,
                label: "typed-input",
                submittedAt: submittedAt
            )
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.sendTerminalText.begin",
            fields: terminalInputTraceFields(
                extra: ["bytes": "\(outbound.lengthOfBytes(using: .utf8))"]
            ),
            at: submittedAt
        )
        let result = model.sendInputToFocusedSurface(outbound)
        GhosttyRuntimeTrace.perf(
            "input.sendText bytes=\(outbound.lengthOfBytes(using: .utf8)) result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.sendTerminalText.end",
            fields: terminalInputTraceFields(extra: [
                "accepted": "\(result.isAccepted)",
                "result": result.description,
            ])
        )
        if !result.isAccepted {
            GhosttyRuntimeTrace.flowEventIfActive(
                "terminal.input",
                event: "ui.sendTerminalText.rejected",
                fields: terminalInputTraceFields(extra: ["result": result.description])
            )
        }
        return result.isAccepted
    }

    private func scheduleTmuxPrefixInputFlush(token: UInt64) {
        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.tmuxPrefixFlushDelay)
            } catch {
                return
            }

            flushPendingTmuxPrefixInputIfNeeded(matching: token)
        }
    }

    private func flushPendingTmuxPrefixInputIfNeeded() {
        guard let input = terminalInputController.flushPendingTmuxPrefixInput() else { return }
        _ = submitTerminalText(input)
    }

    private func flushPendingTmuxPrefixInputIfNeeded(matching token: UInt64) {
        guard let input = terminalInputController.flushPendingTmuxPrefixInput(matching: token) else { return }
        _ = submitTerminalText(input)
    }

    private func sendTerminalPaste(_ text: String) -> Bool {
        terminalInputController.performPaste(
            text,
            submitPendingPrefix: submitTerminalText(_:),
            sendPaste: { model.sendPasteToFocusedSurface($0).isAccepted }
        )
    }

    private func sendTerminalPaste(_ text: String, to surfaceID: UUID) -> Bool {
        terminalInputController.performPaste(
            text,
            submitPendingPrefix: submitTerminalText(_:),
            sendPaste: { model.sendPaste($0, to: surfaceID).isAccepted }
        )
    }

    private func sendTerminalKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        terminalInputController.performKeyEvent(
            event,
            submitPendingPrefix: submitTerminalText(_:),
            sendKey: { event in
                let start = GhosttyRuntimeTrace.nowNanos()
                let result = model.sendKeyEventToFocusedSurface(event)
                GhosttyRuntimeTrace.perf(
                    "input.sendKey result=\(result) accepted=\(result.isAccepted) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
                )
                return result.isAccepted
            }
        )
    }

    private func updateKeyboardVisibility(with notification: Notification) {
        let frameEnd = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
            .cgRectValue
            ?? CGRect(
                x: 0,
                y: UIScreen.main.bounds.maxY,
                width: UIScreen.main.bounds.width,
                height: 0
            )

        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: frameEnd,
            screenBounds: UIScreen.main.bounds,
            animationDuration: (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
                .doubleValue,
            keyboardMode: inputCoordinator.keyboardMode,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            "terminal.input",
            event: "ui.keyboard.notification",
            fields: [
                "name": notification.name.rawValue,
                "visible": "\(projection.isVisible)",
                "height": "\(Int(frameEnd.height))",
                "beginTransition": "\(projection.shouldBeginViewportTransition)",
            ]
        )
        GhosttyRuntimeTrace.perf(
            "kbd.visibility visible=\(projection.isVisible) overlap=\(projection.overlapHeight) duration_ms=\(String(format: "%.3f", projection.animationDuration * 1000)) fallback_ms=\(String(format: "%.3f", projection.fallbackDelay * 1000)) beginTransition=\(projection.shouldBeginViewportTransition) awaitingSystem=\(isAwaitingSystemKeyboardPresentation) frame=\(Int(frameEnd.origin.x)),\(Int(frameEnd.origin.y)),\(Int(frameEnd.width)),\(Int(frameEnd.height))"
        )

        performKeyboardChromeStateChange {
            if let request = projection.transitionRequest {
                beginKeyboardViewportTransition(request)
            } else {
                GhosttyRuntimeTrace.perf(
                    "kbd.visibility skipTransition target=\(projection.transitionTarget.traceLabel) mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
            }

            if softwareKeyboardOverlapHeight != projection.overlapHeight {
                softwareKeyboardOverlapHeight = projection.overlapHeight
            }
            if projection.overlapHeight > 0, lastSoftwareKeyboardOverlapHeight != projection.overlapHeight {
                lastSoftwareKeyboardOverlapHeight = projection.overlapHeight
            }
            keyboardViewportTransitionCoordinator.observeKeyboardVisibility(isVisible: projection.isVisible)

            var updatedCoordinator = inputCoordinator
            updatedCoordinator.updateSoftwareKeyboardVisibility(projection.isVisible)
            if updatedCoordinator != inputCoordinator {
                inputCoordinator = updatedCoordinator
            }
        }
    }

    private func updateTerminalViewportLiveSize(
        _ size: CGSize,
        context: GhosttyTerminalViewportTraceLayoutContext,
        reconcileStoredSize: Bool = false
    ) {
        let observation: GhosttyTerminalViewportLiveSizeObservation
        if reconcileStoredSize {
            observation = terminalViewportCoordinator.reconcileLiveSize(size)
        } else {
            observation = terminalViewportCoordinator.observeLiveSize(size)
        }

        if observation.didChangeLiveSize || reconcileStoredSize {
            GhosttyRuntimeTrace.perf(
                "viewport.\(reconcileStoredSize ? "reconcile" : "live") size=\(observation.liveSize.traceLabel) previous=\(observation.previousLiveSize.traceLabel) frozen=\(observation.wasFrozen) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel) transitionActive=\(terminalViewportCoordinator.isKeyboardTransitionActive) transitionTarget=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
            )
            traceTerminalViewportSnapshot(
                event: reconcileStoredSize ? "viewport.reconcile" : "viewport.live",
                liveSize: observation.liveSize,
                effectiveSize: observation.effectiveSize,
                context: context,
                extra: [
                    "previousLive": observation.previousLiveSize.traceLabel,
                    "previousEffective": observation.previousEffectiveSize.traceLabel,
                ]
            )
        }
        guard observation.didApplyStableSize else { return }

        GhosttyRuntimeTrace.perf(
            "viewport.\(reconcileStoredSize ? "reconcile" : "live") applied size=\(observation.liveSize.traceLabel)"
        )
        model.prepareInitialViewport(
            size: observation.effectiveSize,
            scale: displayScale
        )
    }

    private func finishTerminalCoverPresentation(
        liveSize: CGSize,
        releaseKind: String
    ) {
        let effect = terminalViewportCoordinator.setCoveredPresentation(false, liveSize: liveSize)
        terminalCoverPhase = .visible
        guard case .release(let previousEffectiveSize) = effect else { return }
        completeTerminalViewportHoldRelease(
            previousEffectiveSize: previousEffectiveSize,
            releaseKind: releaseKind
        )
    }

    private func traceTerminalViewportSnapshot(
        event: String,
        liveSize: CGSize,
        effectiveSize: CGSize,
        context: GhosttyTerminalViewportTraceLayoutContext,
        extra: [String: String] = [:]
    ) {
        guard GhosttyRuntimeTrace.tmuxViewportEnabled else { return }

        var fields = context.traceFields()
        fields["live"] = liveSize.traceLabel
        fields["effective"] = effectiveSize.traceLabel
        for (key, value) in extra {
            fields[key] = value
        }
        GhosttyRuntimeTrace.tmuxViewport(
            "viewport.snapshot event=\(event) \(GhosttyRuntimeTrace.formatTraceFields(fields))"
        )
    }

    @discardableResult
    private func beginKeyboardViewportTransition(
        _ request: GhosttyKeyboardViewportTransitionRequest
    ) -> Bool {
        let result = keyboardViewportTransitionCoordinator.beginTransition(
            request,
            viewportCoordinator: &terminalViewportCoordinator,
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        if !result.didStart {
            GhosttyRuntimeTrace.perf(
                "kbd.transition alreadyActive target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel) fallback_ms=\(String(format: "%.3f", request.fallbackDelay * 1000)) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
            )
            scheduleKeyboardViewportTransitionFallback(
                token: result.fallbackToken,
                after: result.fallbackDelay
            )
            return false
        }

        GhosttyRuntimeTrace.perf(
            "kbd.transition begin target=\(request.target.traceLabel) live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
        )
        scheduleKeyboardViewportTransitionFallback(
            token: result.fallbackToken,
            after: result.fallbackDelay
        )
        return true
    }

    private func completeKeyboardDidShow() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didShow")
        performKeyboardChromeStateChange {
            let projection = keyboardViewportCompletionProjection(for: .shown)
            switch projection.action {
            case .complete:
                keyboardViewportTransitionCoordinator.clearAwaitingSystemKeyboardPresentation()
                completeKeyboardViewportTransition()
                finishTerminalCoverRestorationIfSettled(
                    liveSize: terminalViewportCoordinator.latestLiveSize
                )

            case .ignoreTargetMismatch:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )

            case .ignorePolicy, .recoverUnexpectedHide:
                assertionFailure("didShow completion projection returned hidden-keyboard action")
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidShow target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )
            }
        }
    }

    private func completeKeyboardDidHide() {
        GhosttyRuntimeTrace.flowEventIfActive("terminal.input", event: "ui.keyboard.didHide")
        performKeyboardChromeStateChange {
            let projection = keyboardViewportCompletionProjection(for: .hidden)
            switch projection.action {
            case .complete:
                keyboardViewportTransitionCoordinator.clearAwaitingSystemKeyboardPresentation()
                completeKeyboardViewportTransition()

            case .ignoreTargetMismatch:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHide target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
                )

            case .ignorePolicy:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )

            case .recoverUnexpectedHide:
                GhosttyRuntimeTrace.perf(
                    "kbd.transition ignoreDidHideByPolicy mode=\(inputCoordinator.keyboardMode.traceLabel) awaitingSystem=\(isAwaitingSystemKeyboardPresentation)"
                )
                recoverSystemKeyboardAfterUnexpectedHide()
            }
        }
    }

    private func completeKeyboardViewportTransition() {
        guard keyboardViewportTransitionCoordinator.completeTransition(
            viewportCoordinator: &terminalViewportCoordinator,
            liveSize: terminalViewportCoordinator.latestLiveSize
        ) != nil else {
            traceViewportFreezeHoldIfNeeded()
            return
        }

        traceKeyboardViewportTransitionCompletion()
    }

    private func completeKeyboardViewportTransitionFromFallback(token: UInt64) {
        guard let completion = keyboardViewportTransitionCoordinator.completeTransitionFromFallback(
            token: token,
            viewportCoordinator: &terminalViewportCoordinator,
            liveSize: terminalViewportCoordinator.latestLiveSize
        ) else {
            return
        }

        GhosttyRuntimeTrace.perf(
            "kbd.transition fallbackComplete target=\(completion.target.traceLabel)"
        )
        traceKeyboardViewportTransitionCompletion()
    }

    private func scheduleKeyboardViewportTransitionFallback(token: UInt64, after delay: TimeInterval) {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        GhosttyRuntimeTrace.perf(
            "kbd.transition scheduleFallback token=\(token) delay_ms=\(String(format: "%.3f", max(0, delay) * 1000))"
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            completeKeyboardViewportTransitionFromFallback(token: token)
        }
    }

    private func traceKeyboardViewportTransitionCompletion() {
        GhosttyRuntimeTrace.perf(
            "kbd.transition complete live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) holdReasons=\(terminalViewportCoordinator.holdReasonTraceLabel)"
        )
        traceViewportFreezeHoldIfNeeded()
    }

    private func keyboardViewportCompletionProjection(
        for eventTarget: GhosttyKeyboardViewportTransitionTarget
    ) -> GhosttyKeyboardViewportCompletionProjection {
        GhosttyKeyboardViewportCompletionProjection(
            eventTarget: eventTarget,
            activeTransitionTarget: terminalViewportCoordinator.keyboardTransitionTarget,
            keyboardMode: inputCoordinator.keyboardMode,
            isDismissSystemKeyboardRequested: inputCoordinator.isDismissSystemKeyboardRequested,
            isInputAvailable: isTerminalInputAvailable,
            isSelectionSheetPresented: selectionSheet != nil,
            isTransientInputOwnerPresented: isTransientInputOwnerPresented,
            isAwaitingSystemKeyboardPresentation: isAwaitingSystemKeyboardPresentation,
            isSceneActive: scenePhase == .active
        )
    }

    private func recoverSystemKeyboardAfterUnexpectedHide() {
        let request = keyboardViewportTransitionCoordinator.prepareUnexpectedHideRecovery()
        beginKeyboardViewportTransition(request)
        refocusSystemKeyboardIfActive()
        GhosttyRuntimeTrace.perf(
            "kbd.transition recoverUnexpectedHide mode=\(inputCoordinator.keyboardMode.traceLabel) token=\(inputCoordinator.terminalActivationToken)"
        )
    }

    private func traceViewportFreezeHoldIfNeeded() {
        guard terminalViewportCoordinator.isFrozen else { return }
        GhosttyRuntimeTrace.perf(
            "viewport.freeze hold reason=\(terminalViewportCoordinator.holdReasonTraceLabel) target=\(terminalViewportCoordinator.keyboardTransitionTarget.traceLabel)"
        )
    }

    private func completeTerminalViewportHoldRelease(
        previousEffectiveSize: CGSize,
        releaseKind: String
    ) {
        guard !terminalViewportCoordinator.isFrozen else {
            traceViewportFreezeHoldIfNeeded()
            return
        }

        let nextEffectiveSize = terminalViewportCoordinator.effectiveSize(
            liveSize: terminalViewportCoordinator.latestLiveSize
        )
        if nextEffectiveSize != previousEffectiveSize {
            model.prepareInitialViewport(size: nextEffectiveSize, scale: displayScale)
        }
        GhosttyRuntimeTrace.perf(
            "viewport.freeze release kind=\(releaseKind) live=\(terminalViewportCoordinator.latestLiveSize.traceLabel) previousEffective=\(previousEffectiveSize.traceLabel) nextEffective=\(nextEffectiveSize.traceLabel)"
        )
    }

    private func performKeyboardChromeStateChange(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func captureSelectionSheetBottomReplacementHeight() {
        let replacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: bottomChromeHeight,
            softwareKeyboardOverlapHeight: softwareKeyboardOverlapHeight
        )
        selectionSheetPresentationState.captureBottomReplacementHeight(replacementHeight)
        GhosttyRuntimeTrace.tmuxViewport(
            "selectionSheet.captureBottomReplacement bottomChrome=\(bottomChromeHeight.traceLabel) keyboardOverlap=\(softwareKeyboardOverlapHeight.traceLabel) replacement=\(selectionSheetPresentationState.bottomReplacementHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel)"
        )
    }

    private var sessionOpenFlowID: String {
        "session.open.\(presentation.workspaceID.uuidString)"
    }

    private func terminalInputTraceFields(extra: [String: String] = [:]) -> [String: String] {
        let interactionProjection = model.terminalInteractionProjection
        var fields = [
            "activeLeaf": ghosttyDiagnosticShortID(interactionProjection.selectedActiveLeafID),
            "inputAvailable": "\(interactionProjection.isInputAvailable)",
            "keyboardMode": "\(inputCoordinator.keyboardMode)",
            "state": model.stateTraceLabel,
            "topLevels": "\(interactionProjection.windowCount)",
            "workspaceID": presentation.workspaceID.uuidString,
        ]
        for (key, value) in extra {
            fields[key] = value
        }
        return fields
    }

    private func createTmuxWindowFromSelectionSheet() {
        GhosttyRuntimeTrace.flowBegin(
            "tmux.newWindow",
            event: "ui.tap.newWindow",
            fields: [
                "topLevelsBefore": "\(model.terminalInteractionProjection.windowCount)",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let effect = model.createTmuxWindowInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.createTmuxWindow()
        }
    }

    private func selectTmuxWindowFromSelectionSheet(_ id: UUID) {
        guard model.focusTmuxTopLevel(id).isHandled else { return }
        dismissSelectionSheet()
        refocusSystemKeyboardIfActive()
    }

    private func closeTmuxWindowFromSelectionSheet(_ id: UUID) {
        let effect = model.closeTmuxWindowInteractionEffect(id)
        performTopologyActionInteraction(effect) {
            model.closeTmuxWindow(id)
        }
    }

    private func splitFocusedTmuxPaneFromSelectionSheet(
        topLevelID: UUID,
        direction: ghostty_action_split_direction_e,
        event: String
    ) {
        GhosttyRuntimeTrace.flowBegin(
            "tmux.splitPane",
            event: event,
            fields: [
                "panesBefore": "\(model.paneSheetDetentPaneCount(topLevelID: topLevelID))",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let effect = model.splitFocusedTmuxPaneInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.splitFocusedTmuxPane(direction)
        }
    }

    private func selectTmuxPaneFromSelectionSheet(_ id: UUID) {
        GhosttyRuntimeTrace.flowBegin(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "ui.tap.pane",
            fields: [
                "target_uuid": id.uuidString,
                "wall_ns": "\(GhosttyRuntimeTrace.wallNanos())",
                "workspace_id": presentation.workspaceID.uuidString,
            ]
        )
        guard model.focusTmuxPane(id).isHandled else {
            GhosttyRuntimeTrace.flowEndIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "ui.select.rejected",
                fields: ["target_uuid": id.uuidString]
            )
            return
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "ui.select.queued",
            fields: ["target_uuid": id.uuidString]
        )
        dismissSelectionSheet()
        refocusSystemKeyboardIfActive()
    }

    private func closeTmuxPaneFromSelectionSheet(_ id: UUID, topLevelID: UUID) {
        let effect = model.closeTmuxPaneInteractionEffect(id, inTopLevel: topLevelID)
        performTopologyActionInteraction(effect) {
            model.closeTmuxPane(id)
        }
    }

    @ViewBuilder
    private func selectionSheetContent(_ sheet: GhosttySurfaceSelectionSheet) -> some View {
        switch sheet {
        case .windows(let session):
            GhosttyWindowSelectionSheet(
                session: session,
                projection: model.windowSelectionSheetRenderProjection(),
                sessionName: presentation.sessionName,
                onCreateWindow: createTmuxWindowFromSelectionSheet,
                onSelect: selectTmuxWindowFromSelectionSheet,
                onRemoveWindow: closeTmuxWindowFromSelectionSheet
            )

        case .panes(let topLevelID, let session):
            GhosttyPaneSelectionSheet(
                session: session,
                projection: model.paneSelectionSheetRenderProjection(topLevelID: topLevelID),
                onSplitPane: {
                    splitFocusedTmuxPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        event: "ui.tap.splitPane"
                    )
                },
                onStackPane: {
                    splitFocusedTmuxPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_DOWN,
                        event: "ui.tap.stackPane"
                    )
                },
                onSelect: selectTmuxPaneFromSelectionSheet,
                onRemovePane: { id in
                    closeTmuxPaneFromSelectionSheet(id, topLevelID: topLevelID)
                }
            )
        }
    }
}

private struct GhosttyPhotoPickerTransfer: Transferable, Sendable {
    let stagedURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { receivedFile in
            let stagedURL = try await GhosttyAttachmentStagingStore.stageFileURL(
                receivedFile.file
            )
            return GhosttyPhotoPickerTransfer(stagedURL: stagedURL)
        }
    }
}

private struct GhosttyTerminalScreenAccessibilityMarker: View {
    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Terminal")
            .accessibilityIdentifier("terminal.screen")
    }
}

private struct GhosttyTerminalInputReadyAccessibilityMarker: View {
    let isReady: Bool

    @ViewBuilder
    var body: some View {
        if isReady {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Terminal input ready")
                .accessibilityIdentifier("terminal.input.ready")
        }
    }
}

private struct GhosttyBottomChromeHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GhosttySelectionSheetSizing {
    static let windowPreferredHeight: CGFloat = 310

    static func fixedDetentHeight(
        preferredHeight: CGFloat,
        bottomReplacementHeight: CGFloat
    ) -> CGFloat {
        max(normalizedHeight(preferredHeight), normalizedHeight(bottomReplacementHeight))
    }

    static func bottomReplacementHeight(
        bottomChromeHeight: CGFloat,
        softwareKeyboardOverlapHeight: CGFloat
    ) -> CGFloat {
        normalizedHeight(bottomChromeHeight) + normalizedHeight(softwareKeyboardOverlapHeight)
    }

    static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return ceil(height)
    }
}

private extension Optional where Wrapped == GhosttySurfaceSelectionSheet {
    var traceLabel: String {
        switch self {
        case .some(.windows(_)):
            return "windows"
        case .some(.panes(_, _)):
            return "panes"
        case .none:
            return "none"
        }
    }
}

private extension GhosttyKeyboardChromeMode {
    var traceLabel: String {
        switch self {
        case .hidden:
            return "hidden"
        case .system:
            return "system"
        }
    }
}

private extension CGSize {
    var traceLabel: String {
        "\(width.traceLabel)x\(height.traceLabel)"
    }
}

private extension CGFloat {
    var traceLabel: String {
        guard isFinite else { return "\(self)" }
        return String(format: "%.1f", Double(self))
    }
}

struct GhosttyTerminalViewportTraceLayoutContext: Equatable {
    let screenSize: CGSize
    let safeAreaInsets: EdgeInsets
    let keyboardMode: GhosttyKeyboardChromeMode
    let renderedKeyboardMode: GhosttyKeyboardChromeMode
    let bottomChromeHeight: CGFloat
    let softwareKeyboardOverlapHeight: CGFloat
    let lastSoftwareKeyboardOverlapHeight: CGFloat
    let selectionSheetKind: String
    let isViewportFrozen: Bool
    let transitionActive: Bool
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget?
    let awaitingSystemKeyboard: Bool

    init(
        screenSize: CGSize,
        safeAreaInsets: EdgeInsets,
        keyboardMode: GhosttyKeyboardChromeMode,
        renderedKeyboardMode: GhosttyKeyboardChromeMode,
        bottomChromeHeight: CGFloat,
        softwareKeyboardOverlapHeight: CGFloat,
        lastSoftwareKeyboardOverlapHeight: CGFloat,
        selectionSheet: GhosttySurfaceSelectionSheet?,
        isViewportFrozen: Bool,
        transitionActive: Bool,
        transitionTarget: GhosttyKeyboardViewportTransitionTarget?,
        awaitingSystemKeyboard: Bool
    ) {
        self.screenSize = screenSize
        self.safeAreaInsets = safeAreaInsets
        self.keyboardMode = keyboardMode
        self.renderedKeyboardMode = renderedKeyboardMode
        self.bottomChromeHeight = bottomChromeHeight
        self.softwareKeyboardOverlapHeight = softwareKeyboardOverlapHeight
        self.lastSoftwareKeyboardOverlapHeight = lastSoftwareKeyboardOverlapHeight
        self.selectionSheetKind = selectionSheet.traceLabel
        self.isViewportFrozen = isViewportFrozen
        self.transitionActive = transitionActive
        self.transitionTarget = transitionTarget
        self.awaitingSystemKeyboard = awaitingSystemKeyboard
    }

    func traceFields() -> [String: String] {
        [
            "screen": screenSize.traceLabel,
            "safeTop": safeAreaInsets.top.traceLabel,
            "safeBottom": safeAreaInsets.bottom.traceLabel,
            "keyboardMode": keyboardMode.traceLabel,
            "renderedMode": renderedKeyboardMode.traceLabel,
            "bottomChrome": bottomChromeHeight.traceLabel,
            "keyboardOverlap": softwareKeyboardOverlapHeight.traceLabel,
            "lastKeyboardOverlap": lastSoftwareKeyboardOverlapHeight.traceLabel,
            "sheet": selectionSheetKind,
            "frozen": "\(isViewportFrozen)",
            "transitionActive": "\(transitionActive)",
            "transitionTarget": transitionTarget.traceLabel,
            "awaitingSystem": "\(awaitingSystemKeyboard)",
        ]
    }
}

struct GhosttyPhoneChromeLayout: Equatable {
    let screenSize: CGSize

    var isLandscape: Bool {
        screenSize.width > screenSize.height
    }

    var isCompact: Bool {
        isLandscape
    }

    var surfaceHorizontalPadding: CGFloat {
        isCompact ? 8 : 12
    }

    var bottomPadding: CGFloat {
        isCompact ? 2 : 4
    }
}

struct GhosttySoftwareKeyboardVisibility {
    static func isVisible(
        frameEnd: CGRect,
        screenBounds: CGRect
    ) -> Bool {
        visibleOverlapHeight(frameEnd: frameEnd, screenBounds: screenBounds) > 0
    }

    static func visibleOverlapHeight(
        frameEnd: CGRect,
        screenBounds: CGRect
    ) -> CGFloat {
        guard frameEnd.width > 0, frameEnd.height > 0 else { return 0 }
        guard frameEnd.minY < screenBounds.maxY - 1 else { return 0 }

        let overlap = frameEnd.intersection(screenBounds)
        guard !overlap.isNull, overlap.height.isFinite, overlap.height > 0 else {
            return 0
        }
        return overlap.height
    }
}

extension TerminalTheme {
    var terminalSurfaceBackground: Color {
        Color(uiColor: terminalBackgroundUIColor)
    }

    var terminalChromeColorScheme: ColorScheme {
        switch self {
        case .remuxLight:
            .light
        case .ghosttyDefault, .remuxDark:
            .dark
        }
    }

    var terminalKeyboardAppearance: UIKeyboardAppearance {
        switch terminalChromeColorScheme {
        case .light:
            .light
        case .dark:
            .dark
        @unknown default:
            .default
        }
    }
}

private extension View {
    @ViewBuilder
    func ghosttySelectionSheetPresentationBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.presentationBackground(.regularMaterial)
        }
    }
}

struct GhosttySurfaceScreenLifecycleProjection: Equatable {
    let scenePhase: ScenePhase
    let isSelected: Bool
    let shouldRefocusSystemKeyboard: Bool

    init(scenePhase: ScenePhase, isSelected: Bool) {
        self.scenePhase = scenePhase
        self.isSelected = isSelected
        switch scenePhase {
        case .active:
            self.shouldRefocusSystemKeyboard = isSelected
        case .inactive:
            self.shouldRefocusSystemKeyboard = false
        case .background:
            self.shouldRefocusSystemKeyboard = false
        @unknown default:
            self.shouldRefocusSystemKeyboard = false
        }
    }
}
