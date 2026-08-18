import Combine
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
    private struct AttachmentPreviewRequest: Identifiable {
        let attachmentID: GhosttyPendingAttachment.ID

        var id: GhosttyPendingAttachment.ID {
            attachmentID
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var model: Model
    private let composer: GhosttyComposerModel
    private let presentation: GhosttySurfaceScreenPresentation
    private let isSelected: Bool
    private let isTerminalCovered: Bool
    private let shortcutStore: ShortcutStore
    @State private var inputCoordinator = GhosttyTerminalInputCoordinator()
    @State private var terminalInputController = GhosttyTerminalInputController()
    @State private var keyboardResponderHandoff = GhosttyKeyboardResponderHandoff()
    @State private var selectionSheet: GhosttySurfaceSelectionSheet?
    @State private var bottomChromeReservation = GhosttyBottomChromeReservation()
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
    @State private var isAttachmentPhotosPickerPresented = false
    @State private var isAttachmentFileImporterPresented = false
    @State private var attachmentPhotoSelections: [PhotosPickerItem] = []
    @State private var attachmentPreviewRequest: AttachmentPreviewRequest?
    @State private var attachmentNotice: GhosttyAttachmentNotice?
    @State private var composerRevision: UInt64 = 0
#if DEBUG
    @State private var uiTestKeyboardWillHideCount = 0
#endif

    private let onReconnect: () -> Void
    private let onShowSessions: () -> Void
    private let onShowLibrary: () -> Void
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
        composer: GhosttyComposerModel,
        isTerminalCovered: Bool = false,
        shortcutStore: ShortcutStore,
        attachmentTransferServiceFactory: @escaping @Sendable () -> any GhosttyAttachmentTransferService,
        onPreviewSelection: ((UUID, TerminalPreviewCandidate) -> Void)? = nil,
        onReconnect: @escaping () -> Void,
        onShowSessions: @escaping () -> Void,
        onShowLibrary: @escaping () -> Void,
        onUpdateCredentials: @escaping () -> Void,
        onEditServer: @escaping () -> Void,
        onTrustHostKey: @escaping () -> Void
    ) {
        self.model = model
        self.composer = composer
        self.presentation = presentation
        self.isSelected = isSelected
        self.isTerminalCovered = isTerminalCovered
        self.shortcutStore = shortcutStore
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
        self.onPreviewSelection = onPreviewSelection
        self.onReconnect = onReconnect
        self.onShowSessions = onShowSessions
        self.onShowLibrary = onShowLibrary
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

    private var composerUpdates: AnyPublisher<Void, Never> {
        guard isSelected else {
            return Empty(completeImmediately: false).eraseToAnyPublisher()
        }
        // Draft keystrokes and dictation updates re-render only the compose
        // bar, which observes the composer directly. The screen re-evaluates
        // solely for composer state its own chrome and sheets render. Each
        // branch drops the value replayed on (re)subscription so body
        // evaluations don't feed back into new invalidations.
        let presented = composer.$isPresented
            .removeDuplicates().dropFirst()
            .map { _ in () }.eraseToAnyPublisher()
        let submitting = composer.$isSubmitting
            .removeDuplicates().dropFirst()
            .map { _ in () }.eraseToAnyPublisher()
        let attachments = composer.$attachments
            .removeDuplicates().dropFirst()
            .map { _ in () }.eraseToAnyPublisher()
        return Publishers.MergeMany([presented, submitting, attachments])
            .eraseToAnyPublisher()
    }

    private var isActiveComposerPresented: Bool {
        isSelected && composer.isPresented
    }

    private var isComposerChromeHeightTransient: Bool {
        isActiveComposerPresented && composer.dictationController.phase.isActive
    }

    private var composerAttachmentsBinding: Binding<[GhosttyPendingAttachment]> {
        Binding(
            get: { composer.attachments },
            set: { composer.attachments = $0 }
        )
    }

    var body: some View {
        let _ = composerRevision
#if DEBUG
        let _ = GhosttySurfaceScreenPerfProbe.recordBodyEval()
#endif
        GeometryReader { screenProxy in
            let renderedKeyboardMode = inputCoordinator.keyboardMode
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size
            )
            let bottomChromeFallbackHeight = GhosttyKeyboardChromeSizing.baselineHeight
                + 4
                + chrome.bottomPadding
            let bottomChromeHeight = bottomChromeReservation.layoutHeight(
                fallback: bottomChromeFallbackHeight
            )
            let screenProjection = model.terminalScreenPresentationProjection
            let readiness = screenProjection.readiness
            let interactionProjection = screenProjection.interaction
            let terminalResponderFocusPolicy = GhosttyTerminalResponderFocusPolicy(
                isSelected: isSelected,
                keyboardMode: inputCoordinator.keyboardMode,
                keyboardOwner: inputCoordinator.keyboardOwner,
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
                        GhosttyCompositeViewportView(
                            surfaceLookup: model.terminalManagedSurfaceLookup,
                            projection: screenProjection.viewport,
                            terminalTheme: presentation.terminalTheme,
                            trackpadDriver: trackpadDriver,
                            onSurfaceTap: handleSurfaceTap,
                            onPreviewSelection: onPreviewSelection,
                            onWindowSwipe: handleWindowSwipe,
                            sendKeyEventToSurface: { event, surfaceID in
                                model.sendKeyEvent(event, to: surfaceID).isAccepted
                            },
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
                            responderHandoff: keyboardResponderHandoff,
                            trackpadDriver: trackpadDriver,
                            keyboardAppearance: presentation.terminalTheme.terminalKeyboardAppearance,
                            sendText: sendTerminalText,
                            sendPaste: sendTerminalPaste,
                            sendKeyEvent: sendTerminalKeyEvent,
                            onTrackpadFeedbackChange: { trackpadFeedback = $0 },
                            onFirstResponderChange: { isTerminalResponderFirstResponder = $0 }
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

#if DEBUG
                        if GhosttySurfaceScreenPerfProbe.isEnabled {
                            GhosttySurfaceScreenBodyEvalMarker(
                                value: GhosttySurfaceScreenPerfProbe.markerValue
                            )
                            .frame(width: 1, height: 1, alignment: .topLeading)
                            .allowsHitTesting(false)

                            GhosttyKeyboardContinuityAccessibilityMarker(
                                owner: inputCoordinator.keyboardOwner,
                                keyboardWillHideCount: uiTestKeyboardWillHideCount,
                                liveViewportSize: liveTerminalViewportSize,
                                effectiveViewportSize: terminalViewportSize,
                                bottomChromeHeight: bottomChromeHeight,
                                screenSafeAreaBottom: screenProxy.safeAreaInsets.bottom,
                                isKeyboardTransitionActive: terminalViewportCoordinator.isKeyboardTransitionActive,
                                isAwaitingSystemKeyboard: isAwaitingSystemKeyboardPresentation
                            )
                            .frame(width: 1, height: 1, alignment: .topLeading)
                            .allowsHitTesting(false)
                        }
#endif
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay {
                        GhosttySurfaceStatusOverlay(
                            projection: screenProjection.statusOverlay,
                            loadingTitle: presentation.loadingTitle,
                            onReconnect: onReconnect,
                            onUpdateCredentials: onUpdateCredentials,
                            onEditServer: onEditServer,
                            onCancel: onShowLibrary,
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
                attachmentNoticeLayer()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: bottomChromeHeight)
                    .overlay(alignment: .bottom) {
                        GhosttyKeyboardChrome(
                            keyboardMode: renderedKeyboardMode,
                            isEnabled: interactionProjection.isInputAvailable,
                            isInteractionLocked: composer.isSubmitting,
                            isCompact: chrome.isCompact,
                            isControlArmed: terminalInputController.isControlArmed,
                            selectedWindowIndex: interactionProjection.selectedWindowIndex,
                            windowCount: interactionProjection.windowCount,
                            paneCount: interactionProjection.paneCount,
                            isComposerPresented: isActiveComposerPresented,
                            onShowSessions: onShowSessions,
                            onShowLibrary: onShowLibrary,
                            onShowWindows: {
                                showWindows(availableSize: screenProxy.size)
                            },
                            onShowPanes: showPanes,
                            onOpenComposer: openComposer,
                            onToggleKeyboard: toggleKeyboardChrome,
                            onToggleControl: toggleControlModifier,
                            onShowShortcuts: showShortcutPalette,
                            sendKey: sendTerminalKeyEvent
                        ) {
                            selectedComposerBar()
                        }
                        .padding(.horizontal, chrome.surfaceHorizontalPadding)
                        .padding(.top, 4)
                        .padding(.bottom, chrome.bottomPadding)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .background {
                            GeometryReader { chromeProxy in
                                Color.clear.preference(
                                    key: GhosttyRenderedBottomChromeHeightPreferenceKey.self,
                                    value: chromeProxy.size.height
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
            .onPreferenceChange(GhosttyRenderedBottomChromeHeightPreferenceKey.self) { renderedHeight in
                let previousHeight = bottomChromeReservation.settledHeight
                guard bottomChromeReservation.observe(
                    renderedHeight: renderedHeight,
                    isTransient: isComposerChromeHeightTransient
                ) else { return }
                GhosttyRuntimeTrace.tmuxViewport(
                    "viewport.bottomChrome old=\(previousHeight.traceLabel) new=\(bottomChromeReservation.settledHeight.traceLabel) rendered=\(renderedHeight.traceLabel) keyboardMode=\(inputCoordinator.keyboardMode.traceLabel) renderedMode=\(renderedKeyboardMode.traceLabel) softwareKeyboardVisible=\(inputCoordinator.isSoftwareKeyboardVisible) overlap=\(softwareKeyboardOverlapHeight.traceLabel)"
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                guard shouldHandleTerminalKeyboardNotification else { return }
                GhosttyRuntimeTrace.perf("kbd.willChangeFrame")
                updateKeyboardVisibility(with: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                guard shouldHandleTerminalKeyboardNotification else { return }
#if DEBUG
                if ProcessInfo.processInfo.environment["REMUX_UI_TESTING"] == "1" {
                    uiTestKeyboardWillHideCount += 1
                }
#endif
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
                let windowLayout = PanePreviewLayout.windowMetrics(
                    availableSize: screenProxy.size
                )
                let navigationBarHeight = TerminalSelectionSheetLayout.nativeNavigationBarHeight(
                    width: screenProxy.size.width
                )
                let maximumContentHeight = TerminalSelectionSheetLayout.maximumContentHeight(
                    availableHeight: screenProxy.size.height,
                    navigationBarHeight: navigationBarHeight
                )
                let paneTopologySize = PaneTopologyLayout.size(
                    availableWidth: TerminalSelectionSheetLayout.contentWidth(
                        availableWidth: screenProxy.size.width
                    ),
                    maximumHeight: maximumContentHeight
                )
                let contentHeight = selectionSheetContentHeight(
                    for: sheet,
                    windowLayout: windowLayout,
                    paneTopologySize: paneTopologySize,
                    maximumContentHeight: maximumContentHeight
                )
                selectionSheetContent(
                    sheet,
                    windowLayout: windowLayout,
                    paneTopologySize: paneTopologySize,
                    contentHeight: contentHeight
                )
                    .presentationDetents(
                        [.height(TerminalSelectionSheetLayout.sheetHeight(
                            contentHeight: contentHeight,
                            navigationBarHeight: navigationBarHeight
                        ))]
                    )
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.hidden)
                    .terminalSelectionSheetPresentationBackground()
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
            .sheet(item: $attachmentPreviewRequest) { request in
                GhosttyAttachmentPreviewSheet(
                    attachments: composerAttachmentsBinding,
                    initiallySelectedAttachmentID: request.attachmentID
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .terminalSelectionSheetPresentationBackground()
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
            .onChange(of: composer.attachments) { _, attachments in
                guard isSelected else { return }
                composer.clearStatusMessage()
                if attachments.isEmpty {
                    attachmentPreviewRequest = nil
                }
            }
            .onChange(of: interactionProjection.selectedActiveLeafID) { _, activeLeafID in
                handleActiveLeafChange(activeLeafID)
            }
            .onReceive(composerUpdates) { _ in
                composerRevision &+= 1
#if DEBUG
                GhosttySurfaceScreenPerfProbe.beginComposerUpdatePassIfNeeded()
#endif
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
            && attachmentPreviewRequest == nil
    }

    private var isAttachmentInputOwnerPresented: Bool {
        GhosttyAttachmentInputOwnerProjection(
            isPhotosPickerPresented: isAttachmentPhotosPickerPresented,
            isFileImporterPresented: isAttachmentFileImporterPresented,
            isPreviewPresented: attachmentPreviewRequest != nil
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

    @ViewBuilder
    private func selectedComposerBar() -> some View {
        if isSelected {
            GhosttyComposeBar(
                composer: composer,
                isTerminalInputAvailable: isTerminalInputAvailable,
                wantsKeyboardFocus: inputCoordinator.keyboardMode == .system
                    && inputCoordinator.keyboardOwner == .composer,
                isSoftwareKeyboardVisible: inputCoordinator.keyboardMode == .system
                    && inputCoordinator.keyboardOwner == .composer
                    && softwareKeyboardOverlapHeight > 0,
                isKeyboardDismissalActive: terminalViewportCoordinator.isKeyboardTransitionActive
                    && terminalViewportCoordinator.keyboardTransitionTarget == .hidden,
                keyboardActivationToken: inputCoordinator.composerActivationToken,
                keyboardResponderHandoff: keyboardResponderHandoff,
                onKeyboardFocusRequest: handleComposerKeyboardFocusRequest,
                onKeyboardResponderAttached: handleComposerKeyboardResponderAttached,
                onDismissKeyboard: dismissComposerKeyboard,
                onClose: closeComposer,
                onChoosePhotos: openAttachmentPhotosPicker,
                onChooseFiles: openAttachmentFilePicker,
                onOpenAttachment: showPendingAttachmentPreview,
                onRetryAttachment: retryPendingAttachment,
                onRemoveAttachment: removePendingAttachment,
                onPasteAttachment: handleComposerAttachmentPaste,
                onStartDictation: startComposerDictation,
                onCancelDictation: cancelComposerDictation,
                onFinishDictation: finishComposerDictation,
                onSend: submitComposer
            )
        }
    }

    private var isTerminalInputAvailable: Bool {
        model.terminalInteractionProjection.isInputAvailable
    }

    private var isTerminalViewportFrozen: Bool {
        terminalViewportCoordinator.isFrozen
    }

    private var pendingAttachmentInteractionProjection: GhosttyPendingAttachmentInteractionProjection {
        GhosttyPendingAttachmentInteractionProjection(
            hasPreviewableAttachments: composer.attachments.contains(where: \.isPreviewable),
            isTransferInProgress: composer.isSubmitting
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

    private func handleSurfaceTap(
        _ surfaceID: UUID,
        shouldShowKeyboard: Bool
    ) {
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.surface",
            fields: [
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        guard model.focusTmuxPane(surfaceID).isHandled else {
            GhosttyRuntimeTrace.flowEndIfActive(
                "terminal.input",
                event: "ui.tap.surface.rejected",
                fields: ["surface": ghosttyDiagnosticShortID(surfaceID)]
            )
            return
        }
        let isInputAvailable = isTerminalInputAvailable
        if !isActiveComposerPresented {
            if shouldShowKeyboard {
                showSystemKeyboard()
            } else {
                refocusSystemKeyboardIfActive()
            }
        }
        GhosttyRuntimeTrace.flowEvent(
            "terminal.input",
            event: "ui.tap.surface.end",
            fields: [
                "activated": "\(isInputAvailable)",
                "keyboard_requested": "\(shouldShowKeyboard)",
            ]
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
                    inputCoordinator.toggleKeyboard(
                        owner: .terminal,
                        isOwnerAvailable: projection.isInputAvailable
                    )
                    return inputCoordinator.keyboardMode
                },
                completeTransition: completeKeyboardViewportTransition
            )
        }
    }

    private func openComposer() {
        guard !composer.isSubmitting else { return }
        withAnimation(GhosttyKeyboardChromeAnimation.composerTransition) {
            composer.open()
        }
    }

    private func closeComposer() {
        if inputCoordinator.keyboardMode == .system,
           inputCoordinator.keyboardOwner == .composer {
            if isTerminalInputAvailable,
               keyboardResponderHandoff.transfer(to: .terminal) {
                inputCoordinator.transferKeyboardOwnerIfActive(
                    to: .terminal,
                    isOwnerAvailable: true
                )
            } else {
                GhosttyRuntimeTrace.perf(
                    "composer.toggle close fallback=dismissKeyboard terminalResponderUnavailable"
                )
                dismissComposerKeyboard()
            }
        }

        withAnimation(GhosttyKeyboardChromeAnimation.composerTransition) {
            composer.close()
        }
    }

    private func handleComposerKeyboardResponderAttached() {
        guard isActiveComposerPresented,
              inputCoordinator.keyboardMode == .system,
              inputCoordinator.keyboardOwner == .terminal else { return }
        guard keyboardResponderHandoff.transfer(to: .composer) else {
            GhosttyRuntimeTrace.perf(
                "composer.toggle open handoff deferred composerResponderUnavailable"
            )
            return
        }
        if inputCoordinator.keyboardOwner != .composer {
            inputCoordinator.transferKeyboardOwnerIfActive(
                to: .composer,
                isOwnerAvailable: true
            )
        }
    }

    private func startComposerDictation() {
        composer.startDictation()
    }

    private func cancelComposerDictation() {
        composer.cancelDictation()
    }

    private func finishComposerDictation() {
        composer.finishDictation()
    }

    private func handleComposerKeyboardFocusRequest() {
        guard isActiveComposerPresented else { return }
        guard inputCoordinator.keyboardMode != .system
                || inputCoordinator.keyboardOwner != .composer else { return }
        showComposerKeyboard()
    }

    private func dismissComposerKeyboard() {
        guard isActiveComposerPresented,
              inputCoordinator.keyboardMode == .system,
              inputCoordinator.keyboardOwner == .composer else { return }

        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: inputCoordinator.keyboardMode,
            isInputAvailable: true
        )
        performKeyboardChromeStateChange {
            keyboardViewportTransitionCoordinator.performKeyboardToggleTransition(
                projection: projection,
                beginTransition: { request in
                    _ = beginKeyboardViewportTransition(request)
                },
                applyKeyboardToggle: {
                    inputCoordinator.dismissKeyboard()
                    return inputCoordinator.keyboardMode
                },
                completeTransition: completeKeyboardViewportTransition
            )
        }
    }

    private func showComposerKeyboard() {
        performKeyboardChromeStateChange {
            if inputCoordinator.keyboardMode == .hidden {
                let projection = GhosttyKeyboardToggleProjection(
                    keyboardMode: inputCoordinator.keyboardMode,
                    isInputAvailable: true
                )
                if let request = keyboardViewportTransitionCoordinator.transitionRequest(
                    forToggle: projection
                ) {
                    _ = beginKeyboardViewportTransition(request)
                }
            }
            inputCoordinator.showSystemKeyboard(
                owner: .composer,
                isOwnerAvailable: true
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
        if selected, scenePhase == .active {
            model.reclaimActiveTmuxViewport()
        }
        guard terminalCoverPhase.isRestoringKeyboard else { return }
        guard selected else {
            cancelTerminalCoverKeyboardRestoration(reason: "selection")
            return
        }
        resumeTerminalCoverKeyboardRestorationIfPossible()
    }

    private func handleTerminalCoverInputAvailabilityChange(_ isInputAvailable: Bool) {
        if !isInputAvailable {
            composer.clearStatusMessage()
        }
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
            keyboardOwner: inputCoordinator.keyboardOwner,
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
    private func attachmentNoticeLayer() -> some View {
        if let attachmentNotice {
            GhosttyAttachmentNoticeBanner(notice: attachmentNotice)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
        }
    }

    private func removePendingAttachment(_ id: GhosttyPendingAttachment.ID) {
        _ = withAnimation(.easeOut(duration: 0.14)) {
            composer.removeAttachment(id)
        }
    }

    private func showPendingAttachmentPreview(_ attachmentID: GhosttyPendingAttachment.ID) {
        guard pendingAttachmentInteractionProjection.canOpenPreview,
              composer.attachments.contains(where: {
                  $0.id == attachmentID && $0.isPreviewable
              }) else {
            return
        }

        attachmentPreviewRequest = AttachmentPreviewRequest(attachmentID: attachmentID)
    }

    private func retryPendingAttachment(_ attachmentID: GhosttyPendingAttachment.ID) {
        composer.retryAttachment(attachmentID)
    }

    private func openAttachmentPhotosPicker() {
        isAttachmentPhotosPickerPresented = true
    }

    private func openAttachmentFilePicker() {
        isAttachmentFileImporterPresented = true
    }

    private func handleAttachmentPhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else {
            presentAttachmentNotice("Couldn’t add the photos.")
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            guard composer.addPhotoSelections(items) else {
                presentAttachmentNotice("Couldn’t add the photos.")
                return
            }
            attachmentNotice = nil
        }
    }

    private func handleAttachmentFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                presentAttachmentNotice("Couldn’t add the file.")
                return
            }

            Task {
                do {
                    let didAdd = try await composer.addSecurityScopedFiles(urls)
                    await MainActor.run {
                        guard didAdd else {
                            presentAttachmentNotice("Couldn’t add the file.")
                            return
                        }

                        withAnimation(.easeOut(duration: 0.16)) {
                            attachmentNotice = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        presentAttachmentNotice("Couldn’t add the file.")
                    }
                }
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }
            presentAttachmentNotice("Couldn’t add the file.")
        }
    }

    private func handleComposerAttachmentPaste() -> Bool {
        let pasteboard = UIPasteboard.general

        if pasteboard.hasImages {
            guard let request = GhosttyAttachmentPasteboardSnapshot.currentImageProviderRequest()
            else {
                presentAttachmentNotice("Couldn’t paste the image.")
                return false
            }
            withAnimation(.easeOut(duration: 0.16)) {
                composer.addPastedImage(request)
                attachmentNotice = nil
            }
            return true
        }

        if let url = pasteboard.url, url.isFileURL {
            stagePastedFile(url)
            return true
        }

        return false
    }

    private func stagePastedFile(_ url: URL) {
        withAnimation(.easeOut(duration: 0.16)) {
            composer.addPastedFile(url)
            attachmentNotice = nil
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
        isShortcutPalettePresented = true
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

    private func showWindows(availableSize: CGSize) {
        guard !composer.isSubmitting else { return }
        model.claimActiveTmuxViewportIfNeeded()
        guard let projection = model.windowSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
        let layout = PanePreviewLayout.windowMetrics(availableSize: availableSize)
        let session = makeWindowPreviewSession(
            leafIDs: projection.previewLeafIDs,
            layout: layout
        )
        applySelectionSheetPresentation(.windows(session))
        session.startRefreshing()
    }

    private func makeWindowPreviewSession(
        leafIDs: [UUID],
        layout: PanePreviewLayout.Metrics
    ) -> GhosttyPanePreviewSession {
        let dimensions = PanePreviewLayout.windowPhysicalPixelBudget(
            metrics: layout,
            scale: displayScale
        )
        return model.makePanePreviewSession(
            leafIDs: leafIDs,
            pixelBudget: .init(width: dimensions.width, height: dimensions.height)
        )
    }

    private func dismissSelectionSheet() {
        applySelectionSheetPresentation(nil)
    }

    private func applySelectionSheetPresentation(_ newValue: GhosttySurfaceSelectionSheet?) {
        if selectionSheet != nil, newValue == nil {
            cancelSelectionSheetPreviewSession(selectionSheet)
        }

        selectionSheet = newValue
    }

    private func cancelSelectionSheetPreviewSession(_ sheet: GhosttySurfaceSelectionSheet?) {
        switch sheet {
        case .windows(let session):
            session.cancelAll()
        case .panes, .none:
            break
        }
    }

    private func showPanes() {
        guard !composer.isSubmitting else { return }
        model.claimActiveTmuxViewportIfNeeded()
        guard let projection = model.selectedPaneSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.splitPane", event: "ui.showPanes")

        applySelectionSheetPresentation(
            .panes(topLevelID: projection.topLevelID)
        )
        model.refreshTmuxPaneMetadata(inTopLevel: projection.topLevelID)
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

    private func submitComposer() {
        let interaction = model.terminalInteractionProjection
        guard interaction.isInputAvailable,
              let surfaceID = interaction.selectedActiveLeafID else {
            composer.statusMessage = "Couldn’t send. Message kept."
            return
        }

        attachmentPreviewRequest = nil
        attachmentNotice = nil
        let selectedWindowName = model.windowSelectionSheetRenderProjection()
            .windows.first(where: \.isSelected)?.displayName
        composer.submit(
            to: GhosttyComposerSubmissionDestination(
                workspaceID: presentation.workspaceID,
                surfaceID: surfaceID,
                destinationLabel: GhosttyComposerSubmissionDestination.label(
                    sessionName: presentation.sessionName,
                    windowName: selectedWindowName
                ),
                makeAttachmentTransferService: attachmentTransferServiceFactory,
                prepareTerminalInput: {
                    terminalInputController.clearControl()
                    scrollComposerDestinationToBottom(surfaceID)
                },
                sendPaste: { text in
                    await sendTerminalPaste(text, to: surfaceID)
                },
                sendEnter: {
                    await sendComposerEnter(to: surfaceID)
                }
            )
        )
    }

    private func sendTerminalPaste(_ text: String, to surfaceID: UUID) async -> Bool {
        let action = terminalInputController.receivePaste(text)
        if let pendingPrefixInput = action.pendingPrefixInput {
            _ = submitTerminalText(pendingPrefixInput)
        }
        return await model.sendPasteAwaitingCommandCompletion(
            action.text,
            to: surfaceID
        )
    }

    private func sendComposerEnter(to surfaceID: UUID) async -> Bool {
        let keyCode = GhosttySurfaceKeyEvent.KeyCode.enter
        let start = GhosttyRuntimeTrace.nowNanos()
        let pressDelivered = await model.sendKeyEventAwaitingCommandCompletion(
            GhosttySurfaceKeyEvent(action: .press, keyCode: keyCode),
            to: surfaceID
        )
        guard pressDelivered else {
            GhosttyRuntimeTrace.perf(
                "composer.sendEnter delivered=false elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return false
        }

        _ = model.sendKeyEvent(
            GhosttySurfaceKeyEvent(action: .release, keyCode: keyCode),
            to: surfaceID
        )
        GhosttyRuntimeTrace.perf(
            "composer.sendEnter delivered=true elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        return true
    }

    private func scrollComposerDestinationToBottom(_ surfaceID: UUID) {
        guard let surface = model.terminalManagedSurfaceLookup.managedSurface(for: surfaceID) else {
            return
        }
        surface.refreshInteractionState()
        guard surface.scrollRoute == .viewport else { return }
        _ = surface.scrollToPosition(
            row: surface.scrollState.maxRow,
            cellOffset: 0
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
            scale: displayScale,
            claimActiveViewport: isSelected && scenePhase == .active
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
            model.prepareInitialViewport(
                size: nextEffectiveSize,
                scale: displayScale,
                claimActiveViewport: isSelected && scenePhase == .active
            )
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
                "panesBefore": "\(model.paneCount(topLevelID: topLevelID))",
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

    private func setFocusedTmuxPaneZoomedFromSelectionSheet(_ zoomed: Bool) {
        _ = model.setFocusedTmuxPaneZoomed(zoomed)
    }

    private func selectionSheetContentHeight(
        for sheet: GhosttySurfaceSelectionSheet,
        windowLayout: PanePreviewLayout.Metrics,
        paneTopologySize: CGSize,
        maximumContentHeight: CGFloat
    ) -> CGFloat {
        switch sheet {
        case .windows:
            return PanePreviewLayout.gridIdealHeight(
                itemCount: model.windowSelectionSheetRenderProjection().windows.count,
                metrics: windowLayout,
                maximumContentHeight: maximumContentHeight
            )
        case .panes:
            return paneTopologySize.height
        }
    }

    @ViewBuilder
    private func selectionSheetContent(
        _ sheet: GhosttySurfaceSelectionSheet,
        windowLayout: PanePreviewLayout.Metrics,
        paneTopologySize: CGSize,
        contentHeight: CGFloat
    ) -> some View {
        switch sheet {
        case .windows(let session):
            GhosttyWindowSelectionSheet(
                session: session,
                projection: model.windowSelectionSheetRenderProjection(),
                sessionName: presentation.sessionName,
                layout: windowLayout,
                contentHeight: contentHeight,
                commandFailureMessage: selectionSheetCommandFailureMessage,
                onCreateWindow: createTmuxWindowFromSelectionSheet,
                onSelect: selectTmuxWindowFromSelectionSheet,
                onRemoveWindow: closeTmuxWindowFromSelectionSheet
            )

        case .panes(let topLevelID):
            GhosttyPaneSelectionSheet(
                projection: model.paneSelectionSheetRenderProjection(topLevelID: topLevelID),
                topologySize: paneTopologySize,
                commandFailureMessage: selectionSheetCommandFailureMessage,
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
                onSetZoomed: setFocusedTmuxPaneZoomedFromSelectionSheet,
                onSelect: selectTmuxPaneFromSelectionSheet,
                onRemovePane: { id in
                    closeTmuxPaneFromSelectionSheet(id, topLevelID: topLevelID)
                }
            )
        }
    }

    private var selectionSheetCommandFailureMessage: String? {
        guard case .commandFailure(let message) = model
            .terminalScreenPresentationProjection.statusOverlay
        else { return nil }
        return message
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

#if DEBUG
/// UI-test-only probe quantifying how often the selected terminal screen's
/// body re-evaluates and how much main-thread time each composer-driven
/// update pass consumes (invalidation through the end of the run-loop
/// iteration, which covers every body evaluation plus commit for that pass).
@MainActor
enum GhosttySurfaceScreenPerfProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["REMUX_UI_TESTING"] == "1" ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_COMPOSER_PERF"] == "1"

    private(set) static var bodyEvalCount: UInt64 = 0
    private(set) static var barEvalCount: UInt64 = 0
    private(set) static var updatePassCount: UInt64 = 0
    private(set) static var updatePassTotalNanos: UInt64 = 0
    private static var pendingPass: (startedAt: UInt64, evalsAtStart: UInt64)?

    static func recordBodyEval() {
        guard isEnabled else { return }
        bodyEvalCount &+= 1
    }

    static func recordBarEval() {
        guard isEnabled else { return }
        barEvalCount &+= 1
    }

    static func beginComposerUpdatePassIfNeeded() {
        guard isEnabled, pendingPass == nil else { return }
        pendingPass = (GhosttyRuntimeTrace.nowNanos(), bodyEvalCount)
        DispatchQueue.main.async {
            finishComposerUpdatePass()
        }
    }

    private static func finishComposerUpdatePass() {
        guard let pass = pendingPass else { return }
        pendingPass = nil
        let elapsedNanos = GhosttyRuntimeTrace.nowNanos() - pass.startedAt
        updatePassCount &+= 1
        updatePassTotalNanos &+= elapsedNanos
        GhosttyRuntimeTrace.perf(
            "composer.updatePass evals=\(bodyEvalCount - pass.evalsAtStart) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: pass.startedAt))"
        )
    }

    static var markerValue: String {
        let totalMs = Double(updatePassTotalNanos) / 1_000_000
        return "evals=\(bodyEvalCount);barEvals=\(barEvalCount);"
            + "passes=\(updatePassCount);"
            + "passMs=\(String(format: "%.3f", totalMs))"
    }
}

private struct GhosttySurfaceScreenBodyEvalMarker: View {
    let value: String

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Body eval probe")
            .accessibilityValue(value)
            .accessibilityIdentifier("terminal.perf.bodyEvals")
    }
}

private struct GhosttyKeyboardContinuityAccessibilityMarker: View {
    let owner: GhosttyKeyboardOwner
    let keyboardWillHideCount: Int
    let liveViewportSize: CGSize
    let effectiveViewportSize: CGSize
    let bottomChromeHeight: CGFloat
    let screenSafeAreaBottom: CGFloat
    let isKeyboardTransitionActive: Bool
    let isAwaitingSystemKeyboard: Bool

    private var ownerLabel: String {
        switch owner {
        case .none: "none"
        case .terminal: "terminal"
        case .composer: "composer"
        }
    }

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("Keyboard continuity")
            .accessibilityValue(
                "owner=\(ownerLabel);willHide=\(keyboardWillHideCount);"
                    + "liveViewport=\(liveViewportSize.traceLabel);"
                    + "effectiveViewport=\(effectiveViewportSize.traceLabel);"
                    + "bottomChrome=\(bottomChromeHeight.traceLabel);"
                    + "safeAreaBottom=\(screenSafeAreaBottom.traceLabel);"
                    + "transitionActive=\(isKeyboardTransitionActive);"
                    + "awaitingSystemKeyboard=\(isAwaitingSystemKeyboard)"
            )
            .accessibilityIdentifier("terminal.keyboard.continuity")
    }
}
#endif

private struct GhosttyRenderedBottomChromeHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum GhosttyViewportSizing {
    static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return ceil(height)
    }
}

private extension Optional where Wrapped == GhosttySurfaceSelectionSheet {
    var traceLabel: String {
        switch self {
        case .some(.windows):
            return "windows"
        case .some(.panes):
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
        isLandscape || screenSize.width < 420
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
