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
    let serverName: String
    let terminalTheme: TerminalTheme
    let toolbarKeys: TerminalToolbarKeys
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("terminal.preservesVerticalSafeAreas") private var preservesVerticalSafeAreas = true
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
    @State private var isFindPresented = false
    @State private var findQuery = ""
    @State private var findWantsKeyboard = false
    @State private var findSurfaceID: UUID?
    @State private var isReadingAfterFind = false
    /// The group whose windows the window sheet lists, when the backend groups them; nil is the group on
    /// screen.
    @State private var shownWindowGroupID: UUID?
    @State private var bottomChromeReservation = GhosttyBottomChromeReservation()
    @State private var verticalNavigationEdge: HorizontalEdge?
    @State private var keyboardWindowContext = GhosttyKeyboardWindowContext()
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
    private let onCloseSession: () -> Void
    private let onRestartSession: () -> Void
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
        onCloseSession: @escaping () -> Void,
        onRestartSession: @escaping () -> Void,
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
        self.onCloseSession = onCloseSession
        self.onRestartSession = onRestartSession
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
            let containerSize = keyboardWindowContext.window?.bounds.size ?? screenProxy.size
            let usesDuoRail = UIDevice.current.userInterfaceIdiom == .phone && verticalNavigationEdge != nil
            let isInnerPortrait = UIDevice.current.userInterfaceIdiom == .phone
                && horizontalSizeClass == .regular && containerSize.height >= containerSize.width
            let terminalTopSpacing = GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(
                preservesSafeAreas: preservesVerticalSafeAreas,
                hasVerticalControls: usesDuoRail,
                isCompact: horizontalSizeClass == .compact,
                isLandscape: containerSize.width > containerSize.height,
                topInset: screenProxy.safeAreaInsets.top,
                bottomInset: keyboardWindowContext.window?.safeAreaInsets.bottom ?? 0
            )
            let terminalSafeAreaEdges = GhosttyTerminalSafeAreaPolicy.ignoredEdges(
                preservesSafeAreas: preservesVerticalSafeAreas,
                hasVerticalControls: usesDuoRail,
                isCompact: horizontalSizeClass == .compact,
                isLandscape: containerSize.width > containerSize.height
            )
            let renderedKeyboardMode = inputCoordinator.keyboardMode
            let chrome = GhosttyPhoneChromeLayout(
                screenSize: screenProxy.size
            )
            let bottomChromeFallbackHeight = GhosttyKeyboardChromeSizing.baselineHeight
                + 4
                + chrome.bottomPadding
            let bottomChromeHeight = verticalNavigationEdge != nil && !isActiveComposerPresented && !isFindPresented ? 0 : bottomChromeReservation.layoutHeight(
                fallback: bottomChromeFallbackHeight
            )
            let screenProjection = model.terminalScreenPresentationProjection
            let readiness = screenProjection.readiness
            let interactionProjection = screenProjection.interaction
            let chromeStatus = GhosttyKeyboardChromeStatus(
                topLevelNoun: model.topLevelNoun, selectedWindowIndex: interactionProjection.selectedWindowIndex,
                windowCount: interactionProjection.windowCount, paneCount: interactionProjection.paneCount)
            let chromeNavigation = GhosttyKeyboardChromeNavigation(
                isEnabled: interactionProjection.isInputAvailable && !composer.isSubmitting,
                isHeldByPopup: screenProjection.viewport.popup != nil,
                windowCount: interactionProjection.windowCount, paneCount: interactionProjection.paneCount)

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

            let bottomControls = Group {
                if isFindPresented {
                    TerminalFindBar(query: $findQuery, wantsKeyboard: $findWantsKeyboard,
                        presentation: model.paneFindPresentation ?? TerminalFindPresentation(),
                        onQuery: model.updateFind, onNavigate: model.navigateFind, onClose: closeFind)
                        .frame(height: 46)
                } else {
                    GhosttyKeyboardChrome(
                        keyboardMode: renderedKeyboardMode,
                        isEnabled: interactionProjection.isInputAvailable,
                        isInteractionLocked: composer.isSubmitting,
                        isCompact: chrome.isCompact,
                        isControlArmed: terminalInputController.isControlArmed,
                        toolbarKeys: presentation.toolbarKeys,
                        topLevelNoun: model.topLevelNoun,
                        selectedWindowIndex: interactionProjection.selectedWindowIndex,
                        windowCount: interactionProjection.windowCount,
                        paneCount: interactionProjection.paneCount,
                        isNavigationHeldByPopup: screenProjection.viewport.popup != nil,
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
                        sendKey: performToolbarKey,
                        composerContent: { selectedComposerBar() },
                        allowsTerminalKeys: !isReadingAfterFind,
                        showsNavigationControls: verticalNavigationEdge == nil
                    )
                }
            }
            .padding(.horizontal, chrome.surfaceHorizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, chrome.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .bottom)

            let terminalContent = ZStack {
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
                                // The terminal trackpad steers the cursor, so a draft is finished first.
                                guard keyboardResponderHandoff.resolveTerminalComposition(
                                    for: .finish(preservingModifiers: true)
                                ) != .refused else { return false }
                                return model.sendKeyEvent(event, to: surfaceID).isAccepted
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
                            },
                            selectionSource: GhosttyTerminalSelectionSource(
                                readText: { surfaceID, reportResult in
                                    await model.selectedText(in: surfaceID, reportResult: reportResult)
                                },
                                completeLink: { surfaceID, point, selected in
                                    await model.completeLinkSelection(in: surfaceID, at: point, selected: selected)
                                }
                            )
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
                            inputSurface: {
                                model.focusedInputSurfaceID.flatMap {
                                    model.terminalManagedSurfaceLookup.managedSurface(for: $0)
                                }
                            },
                            sendText: { sendTerminalText($0) },
                            sendFinishedText: { sendTerminalText($0, appliesModifiers: false) },
                            sendPaste: sendTerminalPaste,
                            sendKeyEvent: sendTerminalKeyEvent,
                            isModifierArmed: { terminalInputController.isControlArmed },
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
                                isTerminalFirstResponder: isTerminalResponderFirstResponder,
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
                            sessionName: presentation.sessionName,
                            serverName: presentation.serverName,
                            onReconnect: onReconnect,
                            onCloseSession: onCloseSession,
                            onRestartSession: onRestartSession,
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
                        if isTerminalInputCovered {
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
                    .onChange(of: isTerminalInputCovered) { _, isCovered in
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
                .padding(.top, terminalTopSpacing)
                .ignoresSafeArea(.container, edges: GhosttyTerminalSafeAreaPolicy.contentEdges(
                    terminalSafeAreaEdges, hasBottomControls: isActiveComposerPresented || isFindPresented))
            }
            .overlay(alignment: .bottom) { shortcutPaletteLayer() }
            .overlay(alignment: .bottom) { attachmentNoticeLayer() }

            // AnyLayout preserves the terminal representable's structural
            // identity when rotating between the two layout arrangements.
            let terminalLayout: AnyLayout = isInnerPortrait
                ? AnyLayout(GhosttyTerminalControlsLayout(
                    cellPixelHeight: screenProjection.viewport.cellMetrics.map { CGFloat($0.pixelHeight) } ?? 0,
                    scale: screenProjection.viewport.cellMetrics.map { CGFloat($0.contentScale) } ?? displayScale,
                    centersControls: !isActiveComposerPresented && !isFindPresented))
                : AnyLayout(ZStackLayout())
            terminalLayout {
                terminalContent
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !isInnerPortrait && (verticalNavigationEdge == nil || isActiveComposerPresented || isFindPresented) {
                            Color.clear.frame(height: bottomChromeHeight)
                                .overlay(alignment: .bottom) {
                                    bottomControls.background {
                                        GeometryReader { chromeProxy in
                                            Color.clear.preference(
                                                key: GhosttyRenderedBottomChromeHeightPreferenceKey.self,
                                                value: chromeProxy.size.height)
                                        }
                                    }
                                }
                        }
                    }
                if isInnerPortrait {
                    bottomControls
                }
            }
            .background {
                presentation.terminalTheme.terminalSurfaceBackground
                    .ignoresSafeArea()
            }
            // Move the portrait bottom chrome into the container inset while
            // continuing to respect the keyboard's separate safe area.
            .ignoresSafeArea(.container, edges: isInnerPortrait ? .bottom : [])
            .background {
                if #available(iOS 27.1, *) {
                    GhosttyVerticalBarEdgeReader(insets: screenProxy.safeAreaInsets) { verticalNavigationEdge = $0 }
                }
            }
            .overlay {
                GeometryReader { railProxy in
                if #available(iOS 27.1, *), let edge = verticalNavigationEdge {
                    let inset = edge == .leading ? screenProxy.safeAreaInsets.leading : screenProxy.safeAreaInsets.trailing
                    let railWidth: CGFloat = 76
                    let railX = edge == .leading ? inset / 2 : railProxy.size.width - inset / 2
                    let viewport = railViewport(in: railProxy, centerX: railX, width: railWidth)
                    ScrollView(.vertical) {
                        VStack(spacing: 8) {
                            railGroup {
                                railButton("Sessions", icon: "rectangle.stack", identifier: "terminal.sessions", action: onShowSessions)
                                railButton(chromeStatus.windowAccessibilityLabel, icon: "rectangle.on.rectangle", identifier: "terminal.windows",
                                           badge: chromeStatus.windowBadge, hint: chromeNavigation.tabsHint,
                                           enabled: chromeNavigation.isTabsEnabled) {
                                    showWindows(availableSize: screenProxy.size)
                                }
                                railButton(chromeStatus.paneAccessibilityLabel, icon: "square.split.2x1", identifier: "terminal.panes",
                                           badge: chromeStatus.paneBadge, hint: chromeNavigation.panesHint,
                                           enabled: chromeNavigation.isPanesEnabled,
                                           action: showPanes)
                                if usesDuoRail && horizontalSizeClass == .regular && containerSize.width > containerSize.height {
                                    railButton("Safe area spacing", icon: "rectangle.inset.filled", identifier: "terminal.safe-area.toggle",
                                               isActive: preservesVerticalSafeAreas) {
                                        preservesVerticalSafeAreas.toggle()
                                    }
                                    .accessibilityValue(preservesVerticalSafeAreas ? "On" : "Off")
                                    .accessibilityHint("Reserve space at the screen edges, or extend the terminal into it.")
                                }
                            }
                            railGroup {
                                ForEach(Array(presentation.toolbarKeys.values.enumerated()), id: \.offset) { index, key in
                                    railKeyButton(key, index: index,
                                                  isEnabled: interactionProjection.isInputAvailable && !composer.isSubmitting && !isReadingAfterFind)
                                }
                            }
                            railGroup {
                                railButton("Home", icon: "house", identifier: "terminal.home", action: onShowLibrary)
                                railButton("Open composer", icon: "square.and.pencil", identifier: "terminal.composer.toggle", action: openComposer)
                                railButton(inputCoordinator.keyboardMode == .hidden ? "Show keyboard controls" : "Hide keyboard controls",
                                           icon: "keyboard", identifier: "terminal.keyboard",
                                           enabled: interactionProjection.isInputAvailable,
                                           isActive: inputCoordinator.keyboardMode != .hidden, action: toggleKeyboardChrome)
                            }
                        }
                        .padding(.vertical, 4)
                        // Start below the system controls while keeping native
                        // bottom anchoring when the keyboard makes the rail scroll.
                        .frame(minHeight: viewport.height, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("terminal.rail")
                    // Let the scroll view adjust both keyboard transitions as its viewport resizes.
                    .defaultScrollAnchor(.bottom)
                    .frame(width: railWidth, height: viewport.height)
                    .clipped()
                    .position(x: railX, y: viewport.midY)
                }
                }
                // Include the side inset in the overlay's layout AND hit-test bounds.
                // Drawing controls outside the GeometryReader made them untappable.
                .ignoresSafeArea(.container, edges: .horizontal)
            }
            .background {
                GhosttyKeyboardWindowReader(context: keyboardWindowContext) {
                    reconcileKeyboardWindowGeometry()
                }
                .allowsHitTesting(false)
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
            .onChange(of: presentation.toolbarKeys) { _, toolbarKeys in
                terminalInputController.reconcileToolbarKeys(toolbarKeys)
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
            .sheet(item: selectionSheetBinding, onDismiss: {
                if isFindPresented { findWantsKeyboard = true }
            }) { sheet in
                GeometryReader { sheetProxy in
                    let windowLayout = PanePreviewLayout.windowMetrics(
                        availableSize: CGSize(width: sheetProxy.size.width, height: screenProxy.size.height)
                    )
                    let navigationBarHeight = TerminalSelectionSheetLayout.nativeNavigationBarHeight(
                        width: sheetProxy.size.width
                    )
                    let windowProjection: GhosttyWindowSelectionSheetRenderProjection? = if case .windows = sheet {
                        model.windowSelectionSheetRenderProjection(group: shownWindowGroupID)
                    } else {
                        nil
                    }
                    let headerHeight = windowProjection?.grouping == nil
                        ? TerminalSelectionSheetLayout.contextHeight
                        : TerminalSelectionSheetLayout.groupPickerHeight
                    let desiredMaximumContentHeight = TerminalSelectionSheetLayout.maximumContentHeight(
                        availableHeight: screenProxy.size.height,
                        navigationBarHeight: navigationBarHeight,
                        headerHeight: headerHeight
                    )
                    let maximumContentHeight = min(desiredMaximumContentHeight,
                        TerminalSelectionSheetLayout.maximumContentHeight(
                            availableHeight: sheetProxy.size.height,
                            navigationBarHeight: navigationBarHeight, headerHeight: headerHeight))
                    let paneTopologySize = PaneTopologyLayout.size(
                        availableWidth: TerminalSelectionSheetLayout.contentWidth(
                            availableWidth: sheetProxy.size.width
                        ),
                        maximumHeight: maximumContentHeight
                    )
                    let contentHeight = selectionSheetContentHeight(
                        for: sheet,
                        windowProjection: windowProjection,
                        windowLayout: windowLayout,
                        paneTopologySize: paneTopologySize,
                        maximumContentHeight: maximumContentHeight
                    )
                    // The requested detent is independent of the current sheet
                    // height, so measuring the sheet cannot create a shrink loop.
                    let desiredPaneSize = PaneTopologyLayout.size(
                        availableWidth: TerminalSelectionSheetLayout.contentWidth(availableWidth: sheetProxy.size.width),
                        maximumHeight: desiredMaximumContentHeight)
                    let desiredContentHeight = selectionSheetContentHeight(
                        for: sheet, windowProjection: windowProjection, windowLayout: windowLayout,
                        paneTopologySize: desiredPaneSize, maximumContentHeight: desiredMaximumContentHeight)
                    selectionSheetContent(
                        sheet,
                        windowProjection: windowProjection,
                        windowLayout: windowLayout,
                        paneTopologySize: paneTopologySize,
                        contentHeight: contentHeight
                    )
                        .presentationDetents(
                            [.height(TerminalSelectionSheetLayout.sheetHeight(
                                contentHeight: desiredContentHeight,
                                navigationBarHeight: navigationBarHeight,
                                headerHeight: headerHeight
                            ))]
                        )
                        .presentationContentInteraction(.scrolls)
                        .presentationDragIndicator(.hidden)
                        .remuxSheetPresentationBackground()
                        .ghosttyTerminalChromePresentation(
                            presentation.terminalTheme.terminalChromeColorScheme,
                            chromeStyle: presentation.terminalTheme.terminalChromeStyle
                        )
                }
            }
            .ghosttyCloseConfirmationDialog(selectionSheet == nil ? askedCloseQuestion : nil)
            .sheet(isPresented: $isShortcutsSettingsPresented) {
                ShortcutsSettingsSheet(store: shortcutStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .remuxSheetPresentationBackground()
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
                .remuxSheetPresentationBackground()
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
                .remuxSheetPresentationBackground()
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
            .onChange(of: screenProjection.viewport.popup?.id) { _, popupID in
                // The Tabs and Panes sheets act on the tab a popup holds.
                guard popupID != nil, selectionSheet != nil else { return }
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
            .onChange(of: model.paneFindPresentation == nil) { _, ended in
                if ended, isFindPresented { closeFind() }
            }
            .onChange(of: isSelected) { _, selected in
                if !selected, isFindPresented { closeFind() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, isFindPresented { closeFind() }
            }
            .onDisappear { if isFindPresented { closeFind() } }
            .onChange(of: model.commandFailureEvent) { _, event in
                handleCommandFailureEvent(event)
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

    /// Something presented over the terminal: the app's sheets and previews, or this screen's own Tabs and
    /// Panes sheet. Under any of them the terminal gives up the keyboard, and it gets it back when the last
    /// one goes (`terminalCoverPhase`). UIKit only hides the keyboard of a responder under a sheet, and
    /// anything in the sheet that reloads input views, as a menu's list does, would bring it back over the
    /// sheet; with a menu open there, UIKit's keyboard and the sheet's layout then never settle.
    private var isTerminalInputCovered: Bool {
        isTerminalCovered || selectionSheet != nil
    }

    private var isTransientInputOwnerPresented: Bool {
        isAttachmentInputOwnerPresented
            || isShortcutsSettingsPresented
            || shortcutEditorRequest != nil
            || terminalCoverPhase.ownsTerminalInput
            || isFindPresented || isReadingAfterFind
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
                canSubmit: isTerminalInputAvailable,
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
        model.terminalInteractionProjection.isInputAvailable && !isFindPresented && !isReadingAfterFind
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
        if isFindPresented {
            if surfaceID != findSurfaceID { closeFind(); _ = model.focusPane(surfaceID) }
            else { findWantsKeyboard = false }
            return
        }
        if isReadingAfterFind { _ = model.focusPane(surfaceID); return }
        if surfaceID == model.terminalScreenPresentationProjection.viewport.popup?.id {
            handlePopupTap()
            return
        }
        GhosttyRuntimeTrace.flowBegin(
            "terminal.input",
            event: "ui.tap.surface",
            fields: [
                "surface": ghosttyDiagnosticShortID(surfaceID),
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        guard model.focusPane(surfaceID).isHandled else {
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

    /// A tap on the popup brings up the keyboard, as a tap on a pane does; the popup takes the input.
    private func handlePopupTap() {
        guard !isActiveComposerPresented else { return }
        showSystemKeyboard()
    }

    private func handleWindowSwipe(_ direction: GhosttyRuntimeSelectionDirection) {
        let traceStartedAt = GhosttyRuntimeTrace.flowTraceEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
        let didFocus = model.focusAdjacentTopLevel(direction).isHandled
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
        if isReadingAfterFind { isReadingAfterFind = false; model.resumeFindInput() }
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
        guard !isFindPresented, !composer.isSubmitting else { return }
        if isReadingAfterFind { isReadingAfterFind = false; model.resumeFindInput() }
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
        if phase == .background {
            keyboardResponderHandoff.resolveTerminalComposition(for: .cancel)
        }
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
              !isTerminalInputCovered,
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
              !isTerminalInputCovered,
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
        _ actionEffect: GhosttyTopologyActionInteractionEffect,
        action: () -> GhosttyTerminalActionOutcome
    ) -> GhosttyTerminalActionOutcome {
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

    private func handleCommandFailureEvent(_ event: GhosttyTerminalCommandFailureEvent?) {
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
        // A shortcut's sequence follows what was typed, so a draft is finished once before it.
        guard keyboardResponderHandoff.resolveTerminalComposition(
            for: .finish(preservingModifiers: true)
        ) != .refused else { return }
        Task { @MainActor in
            let executor = ShortcutExecutor(
                sendText: { sendTerminalText($0) },
                sendKey: sendTerminalKeyEvent
            )
            if await executor.execute(shortcut) {
                isShortcutPalettePresented = false
            }
        }
    }

    private func toggleControlModifier() {
        // Ctrl arms for what comes next, so a draft typed before it is finished first.
        if !terminalInputController.isControlArmed,
           keyboardResponderHandoff.resolveTerminalComposition(
               for: .finish(preservingModifiers: true)
           ) == .refused {
            return
        }
        terminalInputController.toggleControl()
        if terminalInputController.isControlArmed, inputCoordinator.keyboardMode == .hidden {
            showSystemKeyboard()
        }
    }

    /// A toolbar key settles the keyboard's draft first: Return confirms it and Escape cancels it,
    /// either without reaching the terminal; Backspace and Delete do nothing while it is open; any
    /// other key finishes it, keeping an armed Ctrl for the key itself. Without a draft the key goes
    /// to the terminal.
    private func performToolbarKey(_ event: GhosttySurfaceKeyEvent) -> Bool {
        let (action, consumesDraft): (GhosttyTerminalCompositionAction, Bool) = switch event.keyCode {
        case .enter: (.finish(preservingModifiers: false), true)
        case .escape: (.cancel, true)
        case .backspace, .delete: (.delete, true)
        default: (.finish(preservingModifiers: true), false)
        }
        switch keyboardResponderHandoff.resolveTerminalComposition(for: action) {
        case .refused:
            return false
        case .noDraft:
            return sendTerminalKeyEvent(event)
        case .canceled:
            // Ctrl was armed for the draft that is gone, not for whatever comes next.
            terminalInputController.clearControl()
        case .finished, .kept:
            break
        }
        return consumesDraft || sendTerminalKeyEvent(event)
    }

    private func showWindows(availableSize: CGSize) {
        guard !composer.isSubmitting, model.terminalScreenPresentationProjection.viewport.popup == nil else { return }
        model.claimActiveTmuxViewportIfNeeded()
        guard let projection = model.windowSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.newWindow", event: "ui.showWindows")
        let layout = PanePreviewLayout.windowMetrics(availableSize: availableSize)
        let session = makeWindowPreviewSession(
            leafIDs: projection.previewLeafIDs,
            layout: layout
        )
        shownWindowGroupID = nil
        applySelectionSheetPresentation(.windows(session))
        session?.startRefreshing()
    }

    private func makeWindowPreviewSession(
        leafIDs: [UUID],
        layout: PanePreviewLayout.Metrics
    ) -> GhosttyPanePreviewSession? {
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
            session?.cancelAll()
        case .panes, .none:
            break
        }
    }

    private func showPanes() {
        guard !composer.isSubmitting, model.terminalScreenPresentationProjection.viewport.popup == nil else { return }
        model.claimActiveTmuxViewportIfNeeded()
        guard let projection = model.selectedPaneSheetPresentationProjection() else { return }
        GhosttyRuntimeTrace.flowEventIfActive("tmux.splitPane", event: "ui.showPanes")

        applySelectionSheetPresentation(
            .panes(topLevelID: projection.topLevelID)
        )
        model.refreshPaneMetadata(inTopLevel: projection.topLevelID)
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

    private func sendTerminalText(_ text: String, appliesModifiers: Bool = true) -> Bool {
        guard !isFindPresented, !isReadingAfterFind else { return false }
        return terminalInputController.performTextInput(
            text,
            holdsTmuxPrefix: model.holdsTmuxPrefixKey,
            appliesModifiers: appliesModifiers,
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
        guard !isFindPresented, !isReadingAfterFind else { return false }
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
        guard !isFindPresented, !isReadingAfterFind else { return false }
        return terminalInputController.performPaste(
            text,
            submitPendingPrefix: submitTerminalText(_:),
            sendPaste: { model.sendPasteToFocusedSurface($0).isAccepted }
        )
    }

    /// The message goes where it was written, captured now: the popup over the tab when one is shown, which
    /// takes the tab's input, else the selected pane.
    private func submitComposer() {
        let interaction = model.terminalInteractionProjection
        guard isTerminalInputAvailable,
              let surfaceID = model.terminalScreenPresentationProjection.viewport.popup?.id ?? interaction.selectedActiveLeafID else {
            composer.statusMessage = "Couldn’t send. Message kept."
            return
        }

        attachmentPreviewRequest = nil
        attachmentNotice = nil
        let selectedWindowName = model.windowSelectionSheetRenderProjection(group: nil)
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
        guard !isFindPresented, !isReadingAfterFind else { return false }
        return terminalInputController.performKeyEvent(
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

    @available(iOS 27.1, *)
    private func railGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 2, content: content)
            .padding(4)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }

    @available(iOS 27.1, *)
    private func railViewport(in proxy: GeometryProxy, centerX: CGFloat, width: CGFloat) -> CGRect {
        // Query the overlay, which includes the side rail. The terminal's proxy
        // excludes it and can therefore omit the system regions we need to avoid.
        var obstacles = proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed).map { region in
            CGRect(x: region.frame.minX - region.margins.leading,
                   y: region.frame.minY - region.margins.top,
                   width: region.frame.width + region.margins.leading + region.margins.trailing,
                   height: region.frame.height + region.margins.top + region.margins.bottom)
        }
        if let window = keyboardWindowContext.window {
            let origin = proxy.frame(in: .global).origin
            let keyboard = window.keyboardLayoutGuide.layoutFrame
            obstacles.append(keyboard.offsetBy(dx: -origin.x, dy: -origin.y))
            if let scene = window.windowScene, let status = scene.statusBarManager?.statusBarFrame {
                let frame = window.convert(status, from: scene.coordinateSpace)
                // Some configurations report the whole side strip as the status
                // bar. Its individual occlusions are supplied by reservedRegions.
                if frame.height < window.bounds.height / 2 {
                    obstacles.append(frame.offsetBy(dx: -origin.x, dy: -origin.y))
                }
            }
        }
        // SwiftUI has already shortened this overlay for the keyboard, but its
        // safeAreaInsets.bottom still includes the keyboard's full inset. Do not
        // subtract that inset from the shortened height a second time. Intersect
        // with the window's container safe area using absolute vertical edges.
        let originY = proxy.frame(in: .global).minY
        let window = keyboardWindowContext.window
        let top = max(0, (window.map { $0.bounds.minY + $0.safeAreaInsets.top } ?? originY) - originY)
        let bottom = min(proxy.size.height,
                         (window.map { $0.bounds.maxY - $0.safeAreaInsets.bottom } ?? (originY + proxy.size.height)) - originY)
        let bounds = CGRect(x: centerX - width / 2, y: top, width: width, height: max(0, bottom - top))
        return GhosttyRailViewport.availableFrame(in: bounds, avoiding: obstacles, spacing: 12)
    }

    private func railKeyButton(_ key: TerminalToolbarKey, index: Int, isEnabled: Bool) -> some View {
        let isActive = key == .control && terminalInputController.isControlArmed
        let onLongPress: (() -> Void)? = index == 0 ? { showShortcutPalette() } : nil
        return GhosttyKeyboardKeyButton(
            title: key.toolbarTitle,
            accessibilityLabel: key.settingsTitle,
            accessibilityHint: index == 0 ? "Hold to open shortcuts." : nil,
            accessibilityIdentifier: "terminal.toolbar-key.\(index)",
            accessibilityValue: isActive ? "Armed" : nil,
            chromeStyle: presentation.terminalTheme.terminalChromeStyle,
            fontSize: 12,
            width: 34,
            height: 40,
            isActive: isActive,
            isEnabled: isEnabled,
            onLongPress: onLongPress,
            hapticsOnActivation: true
        ) {
            if key == .control {
                toggleControlModifier()
                return true
            }
            guard let keyCode = key.shortcutKey?.ghosttyKeyCode else { return false }
            return performToolbarKey(.init(keyCode: keyCode))
        }
    }

    private func railButton(_ title: String, icon: String, identifier: String,
                            badge: String? = nil, hint: String? = nil,
                            enabled: Bool = true, isActive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        GhosttyKeyboardChromeDockButton(
            systemName: icon,
            badge: badge,
            chromeStyle: presentation.terminalTheme.terminalChromeStyle,
            width: 34,
            height: 40,
            accessibilityLabel: title,
            accessibilityHint: hint,
            accessibilityIdentifier: identifier,
            isActive: isActive,
            isEnabled: enabled && !composer.isSubmitting,
            hapticsOnActivation: true,
            action: action
        )
    }

    private func reconcileKeyboardWindowGeometry() {
        guard shouldHandleTerminalKeyboardNotification,
              let window = keyboardWindowContext.window else { return }
        // A resize is not a new keyboard appearance. Read the live layout guide
        // instead of replaying a notification from a previous display geometry.
        let overlap = GhosttyKeyboardWindowGeometry.dockedOverlapHeight(
            layoutFrame: window.keyboardLayoutGuide.layoutFrame,
            windowBounds: window.bounds,
            bottomSafeAreaInset: window.safeAreaInsets.bottom
        )
        if softwareKeyboardOverlapHeight != overlap {
            softwareKeyboardOverlapHeight = overlap
        }
        if overlap > 0, lastSoftwareKeyboardOverlapHeight != overlap {
            lastSoftwareKeyboardOverlapHeight = overlap
        }
    }

    private func updateKeyboardVisibility(with notification: Notification) {
        guard let window = keyboardWindowContext.window,
              let screen = window.windowScene?.screen else { return }
        if let sourceScreen = notification.object as? UIScreen, sourceScreen !== screen {
            return
        }
        // Keyboard notifications use screen coordinates; the terminal may occupy
        // only part of that display, and its window changes size while folding.
        let frameEnd = GhosttyKeyboardWindowGeometry.frameEnd(
            notification: notification,
            window: window,
            coordinateSpace: screen.coordinateSpace
        )

        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: frameEnd,
            screenBounds: window.bounds,
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
            updatedCoordinator.updateSoftwareKeyboardVisibility(
                projection.isVisible,
                isInputCovered: isTerminalInputCovered || isFindPresented || isReadingAfterFind
            )
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

    private func createTopLevelFromSelectionSheet() {
        GhosttyRuntimeTrace.flowBegin(
            "tmux.newWindow",
            event: "ui.tap.newWindow",
            fields: [
                "topLevelsBefore": "\(model.terminalInteractionProjection.windowCount)",
                "workspaceID": presentation.workspaceID.uuidString,
            ]
        )
        let effect = model.createTopLevelInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.createTopLevel(inGroup: shownWindowGroupID)
        }
    }

    private func createTopLevelGroupFromSelectionSheet() {
        let effect = model.createTopLevelInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.createTopLevelGroup(from: shownWindowGroupID)
        }
    }

    private func selectTopLevelFromSelectionSheet(_ id: UUID) {
        guard model.focusTopLevel(id).isHandled else { return }
        dismissSelectionSheet()
        refocusSystemKeyboardIfActive()
    }

    private func closeTopLevelFromSelectionSheet(_ id: UUID) {
        let effect = model.closeTopLevelInteractionEffect(id)
        performTopologyActionInteraction(effect) {
            model.closeTopLevel(id)
        }
    }

    private func splitFocusedPaneFromSelectionSheet(
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
        let effect = model.splitFocusedPaneInteractionEffect()
        performTopologyActionInteraction(effect) {
            model.splitFocusedPane(direction)
        }
    }

    private var findPaneAction: ((UUID) -> Void)? {
        guard model.canFindInPane else { return nil }
        return { id in beginFind(id) }
    }

    private func beginFind(_ surfaceID: UUID) {
        guard !composer.isSubmitting, model.beginFind(in: surfaceID) else { return }
        isReadingAfterFind = true
        isFindPresented = true; findSurfaceID = surfaceID
        findQuery = ""; findWantsKeyboard = false
        terminalInputController.clearControl()
        _ = terminalInputController.flushPendingTmuxPrefixInput()
        inputCoordinator.dismissKeyboard()
        if let effect = topologyActionInputRefocusCoordinator.cancelForCommandFailure() {
            _ = applyTopologyInputRefocusEffect(effect)
        }
        if terminalCoverPhase.ownsTerminalInput { terminalCoverPhase = .covered(restoreKeyboard: false) }
        dismissSelectionSheet()
    }

    private func closeFind() {
        findWantsKeyboard = false; isFindPresented = false; findSurfaceID = nil
        isReadingAfterFind = true
        inputCoordinator.dismissKeyboard()
        model.endFind()
    }

    private func selectPaneFromSelectionSheet(_ id: UUID) {
        GhosttyRuntimeTrace.flowBegin(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "ui.tap.pane",
            fields: [
                "target_uuid": id.uuidString,
                "wall_ns": "\(GhosttyRuntimeTrace.wallNanos())",
                "workspace_id": presentation.workspaceID.uuidString,
            ]
        )
        guard model.focusPane(id).isHandled else {
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

    private func closePaneFromSelectionSheet(_ id: UUID, topLevelID: UUID) {
        let effect = model.closePaneInteractionEffect(id, inTopLevel: topLevelID)
        performTopologyActionInteraction(effect) {
            model.closePane(id)
        }
    }

    private func setFocusedPaneZoomedFromSelectionSheet(_ zoomed: Bool) {
        _ = model.setFocusedPaneZoomed(zoomed)
    }

    /// A sheet listing one group's windows is as tall as the largest group needs, so it keeps its height
    /// as the group changes.
    private func selectionSheetContentHeight(
        for sheet: GhosttySurfaceSelectionSheet,
        windowProjection: GhosttyWindowSelectionSheetRenderProjection?,
        windowLayout: PanePreviewLayout.Metrics,
        paneTopologySize: CGSize,
        maximumContentHeight: CGFloat
    ) -> CGFloat {
        switch sheet {
        case .windows(let session):
            let count = windowProjection.map { $0.grouping?.largestWindowCount ?? $0.windows.count } ?? 0
            guard session != nil else {
                return GhosttyWindowRowList.idealHeight(rowCount: count, maximumContentHeight: maximumContentHeight)
            }
            return PanePreviewLayout.gridIdealHeight(
                itemCount: count,
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
        windowProjection: GhosttyWindowSelectionSheetRenderProjection?,
        windowLayout: PanePreviewLayout.Metrics,
        paneTopologySize: CGSize,
        contentHeight: CGFloat
    ) -> some View {
        switch sheet {
        case .windows(let session):
            if let windowProjection {
                GhosttyWindowSelectionSheet(
                    session: session,
                    projection: windowProjection,
                    topLevelNoun: model.topLevelNoun,
                    sessionName: presentation.sessionName,
                    layout: windowLayout,
                    contentHeight: contentHeight,
                    commandFailureMessage: selectionSheetCommandFailureMessage,
                    askedCloseQuestion: askedCloseQuestion,
                    onCreateWindow: createTopLevelFromSelectionSheet,
                    onSelect: selectTopLevelFromSelectionSheet,
                    onRemoveWindow: closeTopLevelFromSelectionSheet,
                    onRenameWindow: { id, name in model.renameTopLevel(id, to: name) },
                    onShowGroup: { shownWindowGroupID = $0 },
                    onCreateGroup: createTopLevelGroupFromSelectionSheet
                )
            }

        case .panes(let topLevelID):
            GhosttyPaneSelectionSheet(
                projection: model.paneSelectionSheetRenderProjection(topLevelID: topLevelID),
                topologySize: paneTopologySize,
                commandFailureMessage: selectionSheetCommandFailureMessage,
                askedCloseQuestion: askedCloseQuestion,
                onSplitPane: {
                    splitFocusedPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        event: "ui.tap.splitPane"
                    )
                },
                onStackPane: {
                    splitFocusedPaneFromSelectionSheet(
                        topLevelID: topLevelID,
                        direction: GHOSTTY_SPLIT_DIRECTION_DOWN,
                        event: "ui.tap.stackPane"
                    )
                },
                onSetZoomed: setFocusedPaneZoomedFromSelectionSheet,
                onSelect: selectPaneFromSelectionSheet,
                onRemovePane: { id in
                    closePaneFromSelectionSheet(id, topLevelID: topLevelID)
                },
                onRenamePane: { id, name in model.renamePane(id, to: name) },
                onFindPane: findPaneAction
            )
        }
    }

    /// The close the backend's server asked about: the open selection sheet asks it, else the screen.
    private var askedCloseQuestion: GhosttyCloseQuestion? {
        model.askedCloseConfirmation.map {
            GhosttyCloseQuestion(
                confirmation: $0,
                confirmIdentifier: "terminal.close.asked.confirm",
                answer: model.answerAskedCloseConfirmation(agreed:)
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
/// DEBUG probe, on under REMUX_UI_TESTING or REMUX_TRACE_COMPOSER_PERF:
/// counts body evaluations of the selected terminal screen and the
/// main-thread time of each composer-driven update pass, from invalidation to
/// the end of that run-loop iteration.
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
    let isTerminalFirstResponder: Bool
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
                "owner=\(ownerLabel);firstResponder=\(isTerminalFirstResponder);willHide=\(keyboardWillHideCount);"
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
        guard !overlap.isNull, overlap.width > 0, overlap.height.isFinite, overlap.height > 0 else {
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

/// Holds the owning window weakly without publishing UIKit layout callbacks into SwiftUI.
@MainActor
private final class GhosttyKeyboardWindowContext {
    weak var window: UIWindow?
}

@MainActor
private struct GhosttyKeyboardWindowReader: UIViewRepresentable {
    let context: GhosttyKeyboardWindowContext
    let onWindowGeometryChanged: () -> Void

    func makeUIView(context: Context) -> Probe {
        Probe(windowContext: self.context, onWindowGeometryChanged: onWindowGeometryChanged)
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onWindowGeometryChanged = onWindowGeometryChanged
    }

    final class Probe: UIView {
        let windowContext: GhosttyKeyboardWindowContext
        var onWindowGeometryChanged: () -> Void
        private var previousBounds: CGRect?
        private var previousKeyboardFrame: CGRect?
        private var previousBottomSafeAreaInset: CGFloat?
        private weak var previousWindow: UIWindow?

        init(windowContext: GhosttyKeyboardWindowContext, onWindowGeometryChanged: @escaping () -> Void) {
            self.windowContext = windowContext
            self.onWindowGeometryChanged = onWindowGeometryChanged
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowContext.window = window
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let keyboardFrame = window.keyboardLayoutGuide.layoutFrame
            let bottomInset = window.safeAreaInsets.bottom
            guard window !== previousWindow || window.bounds != previousBounds
                || keyboardFrame != previousKeyboardFrame
                || bottomInset != previousBottomSafeAreaInset else { return }
            previousWindow = window
            previousBounds = window.bounds
            previousKeyboardFrame = keyboardFrame
            previousBottomSafeAreaInset = bottomInset
            // Updating SwiftUI state during layout would trigger a recursive update.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                self.onWindowGeometryChanged()
            }
        }
    }
}

@available(iOS 27.1, *)
private struct GhosttyVerticalBarEdgeReader: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let insets: EdgeInsets
    let onChange: (HorizontalEdge?) -> Void

    private var usableEdge: HorizontalEdge? {
        guard let edge else { return nil }
        let width = edge == .leading ? insets.leading : insets.trailing
        return width >= 44 ? edge : nil
    }

    var body: some View {
        Color.clear
            .onAppear { onChange(usableEdge) }
            .onChange(of: usableEdge) { _, value in onChange(value) }
    }
}

// Work in one coordinate space and subtract every obstruction, including ones
// at the bottom. Keeping the largest contiguous gap gives the scroll view an
// explicit viewport without guessing whether an occlusion is a top status pill.
enum GhosttyRailViewport {
    static func availableFrame(in bounds: CGRect, avoiding obstacles: [CGRect], spacing: CGFloat) -> CGRect {
        var gaps = [bounds.minY...bounds.maxY]
        for obstacle in obstacles where obstacle.maxX > bounds.minX && obstacle.minX < bounds.maxX {
            let lower = obstacle.minY - spacing
            let upper = obstacle.maxY + spacing
            gaps = gaps.flatMap { gap -> [ClosedRange<CGFloat>] in
                guard upper > gap.lowerBound && lower < gap.upperBound else { return [gap] }
                var remaining: [ClosedRange<CGFloat>] = []
                if lower > gap.lowerBound { remaining.append(gap.lowerBound...min(lower, gap.upperBound)) }
                if upper < gap.upperBound { remaining.append(max(upper, gap.lowerBound)...gap.upperBound) }
                return remaining
            }
        }
        guard let gap = gaps.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else {
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 0)
        }
        let top = max(gap.lowerBound, bounds.minY + spacing)
        let bottom = min(gap.upperBound, bounds.maxY - spacing)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
    }
}

// Compact layouts use the outer display's bottom inset. Regular landscape
// layouts can extend at both vertical edges; portrait keeps its existing layout.
enum GhosttyTerminalSafeAreaPolicy {
    // A bottom safe-area inset also carries the app's Compose/Find reservation.
    // Extending through it would put terminal rows underneath those controls.
    static func contentEdges(_ edges: Edge.Set, hasBottomControls: Bool) -> Edge.Set {
        hasBottomControls ? edges.subtracting(.bottom) : edges
    }

    static func additionalTopSpacing(preservesSafeAreas: Bool, hasVerticalControls: Bool,
                                     isCompact: Bool, isLandscape: Bool,
                                     topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        guard preservesSafeAreas, hasVerticalControls, !isCompact, isLandscape else { return 0 }
        // With status controls on the side, the system may report no top inset.
        // Match the bottom container band without doubling an existing top inset.
        return max(0, bottomInset - topInset)
    }

    static func ignoredEdges(preservesSafeAreas: Bool, hasVerticalControls: Bool,
                             isCompact: Bool, isLandscape: Bool) -> Edge.Set {
        guard hasVerticalControls else { return [] }
        // Outer layouts always use the bottom area; only inner landscape has
        // a user-selectable safe-area band.
        if isCompact { return .bottom }
        return !preservesSafeAreas && isLandscape ? [.top, .bottom] : []
    }
}

// Transfer only the fraction that cannot hold a complete character row to the
// controls area. This depends on local layout, never delayed remote topology.
enum GhosttyWholeRowLayout {
    static func viewportHeight(availableHeight: CGFloat, cellPixelHeight: CGFloat, scale: CGFloat) -> CGFloat {
        guard availableHeight.isFinite, availableHeight > 0,
              cellPixelHeight.isFinite, cellPixelHeight > 0, scale.isFinite, scale > 0 else { return availableHeight }
        let pixels = (availableHeight * scale).rounded()
        let rows = floor(pixels / cellPixelHeight)
        guard rows >= 1 else { return availableHeight }
        return rows * cellPixelHeight / scale
    }


}

/// Measures the controls and terminal together, with no asynchronous height
/// preference or keyboard estimate. The keyboard changes the proposal itself.
private struct GhosttyTerminalControlsLayout: Layout {
    let cellPixelHeight: CGFloat
    let scale: CGFloat
    let centersControls: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let controls = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let frames = GhosttyTerminalControlsGeometry.frames(
            bounds: bounds, controlsHeight: controls.height,
            cellPixelHeight: cellPixelHeight, scale: scale, centersControls: centersControls)
        subviews[0].place(at: frames.terminal.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(frames.terminal.size))
        subviews[1].place(at: frames.controls.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(frames.controls.size))
    }
}

enum GhosttyTerminalControlsGeometry {
    static func frames(bounds: CGRect, controlsHeight: CGFloat, cellPixelHeight: CGFloat,
                       scale: CGFloat, centersControls: Bool) -> (terminal: CGRect, controls: CGRect) {
        let height = min(max(0, controlsHeight), bounds.height)
        let available = max(0, bounds.height - height)
        let terminalHeight = GhosttyWholeRowLayout.viewportHeight(
            availableHeight: available, cellPixelHeight: cellPixelHeight, scale: scale)
        let remainder = max(0, available - terminalHeight)
        let terminal = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: terminalHeight)
        let controls = CGRect(x: bounds.minX, y: terminal.maxY + (centersControls ? remainder / 2 : 0),
                              width: bounds.width, height: height)
        return (terminal, controls)
    }
}
