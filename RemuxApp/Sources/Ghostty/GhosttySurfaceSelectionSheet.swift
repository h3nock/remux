import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    case windows(GhosttyPanePreviewSession)
    case panes(topLevelID: UUID)

    var id: String {
        switch self {
        case .windows:
            "windows"
        case .panes(let topLevelID):
            "panes-\(topLevelID.uuidString)"
        }
    }

    var paneTopLevelIDForTopologyValidation: UUID? {
        switch self {
        case .windows:
            nil
        case .panes(let topLevelID):
            topLevelID
        }
    }
}

struct GhosttyWindowSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession
    @State private var pendingRemoval: GhosttyWindowRemovalRequest?
    @State private var pendingContextAction: GhosttyWindowRemovalRequest?

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let sessionName: String
    let layout: PanePreviewLayout.Metrics
    let contentHeight: CGFloat
    let commandFailureMessage: String?
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void

    var body: some View {
        NavigationStack {
            TerminalSelectionSheetContent(
                context: "\(sessionName) · \(projection.windows.count) \(projection.windows.count == 1 ? "window" : "windows")"
            ) {
                ScrollView(showsIndicators: false) {
                    windowGrid(
                        windows: projection.windows,
                        layout: layout
                    )
                }
                .frame(height: contentHeight)
                .accessibilityIdentifier("terminal.windows.scroll")
                .contentMargins(
                    .horizontal,
                    TerminalSelectionSheetLayout.horizontalContentPadding,
                    for: .scrollContent
                )
            } actions: {
                TerminalSelectionSheetActionButton(
                    title: "New Window",
                    systemName: "plus",
                    accessibilityIdentifier: "terminal.window.new",
                    action: onCreateWindow
                )
            }
            .navigationTitle("Windows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptic.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Windows")
                    .accessibilityIdentifier("terminal.windows.close")
                }
            }
        }
        .onAppear {
            session.reconcile(leafIDs: projection.previewLeafIDs)
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=windows")
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
        .onChange(of: projection.windows.map(\.id)) { _, newValue in
            if let pendingContextAction, !newValue.contains(pendingContextAction.id) {
                self.pendingContextAction = nil
            }
        }
        .confirmationDialog(
            "Remove Window?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Window \(request.displayIndex)", role: .destructive) {
                onRemoveWindow(request.id)
                pendingRemoval = nil
            }
            .accessibilityIdentifier("terminal.window.remove.confirm.\(request.displayIndex)")
        } message: { request in
            Text(windowRemovalMessage(for: request))
        }
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.windows.sheet")
    }

    private func windowGrid(
        windows: [GhosttyWindowSelectionSheetRenderProjection.Window],
        layout: PanePreviewLayout.Metrics
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(windows) { window in
                let request = GhosttyWindowRemovalRequest(
                    id: window.id,
                    displayIndex: window.displayIndex,
                    paneCount: window.paneCount
                )

                ZStack(alignment: .topTrailing) {
                    Button {
                        pendingContextAction = nil
                        Haptic.selection()
                        onSelect(window.id)
                    } label: {
                        GhosttyWindowSelectionTile(
                            displayIndex: window.displayIndex,
                            displayName: window.displayName,
                            totalCount: window.totalCount,
                            paneCount: window.paneCount,
                            isSelected: window.isSelected,
                            previewState: window.focusedPreviewPaneID
                                .flatMap { session.imagesByPaneID[$0] },
                            chromeStyle: chromeStyle,
                            layout: layout
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("terminal.window.tile.\(window.displayIndex)")
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                            .onEnded { _ in
                                Haptic.warning()
                                pendingContextAction = request
                            }
                    )
                    .allowsHitTesting(pendingContextAction?.id != window.id)

                    if pendingContextAction?.id == window.id {
                        GhosttySelectionContextActionButton(
                            title: "Remove Window \(window.displayIndex)",
                            accessibilityIdentifier: "terminal.window.remove.\(window.displayIndex)",
                            action: confirmPendingContextAction
                        )
                        .padding(4)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: pendingContextAction?.id)
                .accessibilityAction(named: Text("Remove Window \(window.displayIndex)")) {
                    Haptic.warning()
                    pendingRemoval = request
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                    pendingContextAction = nil
                }
            }
        )
    }

    private func confirmPendingContextAction() {
        pendingRemoval = pendingContextAction
        pendingContextAction = nil
    }

    private func windowRemovalMessage(for request: GhosttyWindowRemovalRequest) -> String {
        "This will close Window \(request.displayIndex) and \(request.paneCount) \(request.paneCount == 1 ? "pane" : "panes")."
    }
}

struct GhosttyPaneSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var pendingRemoval: GhosttyPaneRemovalRequest?
    @State private var pendingContextAction: GhosttyPaneRemovalRequest?

    let projection: GhosttyPaneSelectionSheetRenderProjection
    let topologySize: CGSize
    let commandFailureMessage: String?
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSetZoomed: (Bool) -> Void
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void

    var body: some View {
        NavigationStack {
            TerminalSelectionSheetContent(
                context: "\(projection.paneCount) \(projection.paneCount == 1 ? "pane" : "panes")"
            ) {
                panePicker
                    .padding(
                        .horizontal,
                        TerminalSelectionSheetLayout.horizontalContentPadding
                    )
            } actions: {
                HStack(spacing: 0) {
                    GhosttyPaneSheetActionButton(
                        title: "Split",
                        systemName: "arrow.right",
                        accessibilityLabel: "Split right",
                        accessibilityIdentifier: "terminal.pane.split.right",
                        action: onSplitPane
                    )

                    GhosttyPaneSheetControlDivider()

                    GhosttyPaneSheetActionButton(
                        title: "Split",
                        systemName: "arrow.down",
                        accessibilityLabel: "Split down",
                        accessibilityIdentifier: "terminal.pane.split.down",
                        action: onStackPane
                    )

                    if projection.paneCount > 1 {
                        GhosttyPaneSheetControlDivider()

                        GhosttyPaneSheetZoomControl(
                            isOn: Binding(
                                get: { projection.isServerZoomed },
                                set: { zoomed in onSetZoomed(zoomed) }
                            ),
                            accent: chromeStyle.accent
                        )
                    }
                }
                .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
                .terminalSelectionSheetControlGroupSurface()
            }
            .navigationTitle("Panes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptic.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Panes")
                    .accessibilityIdentifier("terminal.panes.close")
                }
            }
        }
        .onChange(of: projection.panes.map(\.id)) { _, newValue in
            if let pendingContextAction, !newValue.contains(pendingContextAction.id) {
                self.pendingContextAction = nil
            }
        }
        .confirmationDialog(
            "Remove Pane?",
            isPresented: pendingRemovalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button("Remove Pane", role: .destructive) {
                onRemovePane(request.id)
                pendingRemoval = nil
                pendingContextAction = nil
            }
            .accessibilityIdentifier("terminal.pane.remove.confirm")
        } message: { request in
            Text(paneRemovalMessage(for: request))
        }
        .overlay(alignment: .bottom) {
            if let commandFailureMessage {
                GhosttySelectionSheetFailureBanner(message: commandFailureMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, TerminalSelectionSheetLayout.actionBarHeight + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: commandFailureMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.panes.sheet")
    }

    private var panePicker: some View {
        GhosttyPaneTopologyDiagram(
            panes: projection.panes,
            selectedPaneID: projection.selectedPaneID,
            size: topologySize,
            accent: chromeStyle.selectedStroke,
            pendingRemovalPaneID: pendingContextAction?.id,
            onSelect: { paneID in
                Haptic.selection()
                pendingContextAction = nil
                onSelect(paneID)
            },
            onLongPress: { pane in
                Haptic.warning()
                pendingContextAction = removalRequest(for: pane)
            },
            onRemove: { pane in
                performRemoval(removalRequest(for: pane))
            }
        )
        .frame(height: topologySize.height, alignment: .top)
    }

    private func removalRequest(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> GhosttyPaneRemovalRequest {
        GhosttyPaneRemovalRequest(
            id: pane.id,
            isOnlyPane: projection.paneCount == 1
        )
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                    pendingContextAction = nil
                }
            }
        )
    }

    private func performRemoval(_ request: GhosttyPaneRemovalRequest) {
        if request.isOnlyPane {
            pendingRemoval = request
        } else {
            onRemovePane(request.id)
            pendingContextAction = nil
        }
    }

    private func paneRemovalMessage(for request: GhosttyPaneRemovalRequest) -> String {
        if request.isOnlyPane {
            return "This is the only pane in the window, so removing it can close the window too."
        }
        return "This will close the pane."
    }
}

private struct GhosttyWindowRemovalRequest: Identifiable {
    let id: UUID
    let displayIndex: Int
    let paneCount: Int
}

private struct GhosttyPaneRemovalRequest: Identifiable {
    let id: UUID
    let isOnlyPane: Bool
}

private struct GhosttySelectionSheetFailureBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemRed))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 7)
        .accessibilityIdentifier("terminal.selection.failure")
    }
}

private struct GhosttySelectionContextActionButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(GhosttySelectionContextActionPalette.destructiveText)
                .frame(width: 44, height: 44)
                .ghosttySelectionContextActionSurface()
        }
        .buttonStyle(GhosttySelectionContextActionButtonStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
    }
}

private struct GhosttySelectionContextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum GhosttySelectionContextActionPalette {
    static let fallbackFill = Color(uiColor: .secondarySystemBackground).opacity(0.92)
    static let glassTint = Color.primary.opacity(0.055)
    static let destructiveText = Color(uiColor: .systemRed)
    static let stroke = Color.primary.opacity(0.11)
    static let shadow = Color.black.opacity(0.20)
}

private struct GhosttyRenderedPreviewSurface: View {
    let image: CGImage
    let size: CGSize

    var body: some View {
        Image(decorative: image, scale: PanePreviewLayout.currentScale())
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.30))
            .clipped()
    }

}

private struct GhosttyWindowSelectionTile: View {
    let displayIndex: Int
    let displayName: String
    let totalCount: Int
    let paneCount: Int
    let isSelected: Bool
    let previewState: GhosttyPanePreviewSession.PreviewState?
    let chromeStyle: GhosttyTerminalChromeStyle
    let layout: PanePreviewLayout.Metrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewSurface

            metadata
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.black.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .padding(8)
        }
        .frame(
            width: layout.tilePointSize.width,
            height: layout.tilePointSize.height,
            alignment: .topLeading
        )
        .terminalSelectionTileChrome(isSelected: isSelected, chromeStyle: chromeStyle)
        .overlay(alignment: .topLeading) {
            GhosttyPreviewIndexBadge(
                displayIndex: displayIndex,
                isSelected: isSelected,
                chromeStyle: chromeStyle
            )
            .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(previewState.accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch previewState {
        case .ready(let image):
            GhosttyRenderedPreviewSurface(
                image: image,
                size: layout.tilePointSize
            )

        case .pending, .none, .failed:
            Color.black.opacity(0.30)
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
        }
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(displayName.isEmpty ? "Window \(displayIndex)" : displayName)
                .fontWeight(.semibold)

            Text("·")

            Text("\(paneCount) \(paneCount == 1 ? "pane" : "panes")")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.94))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var accessibilityLabel: String {
        let paneText = "\(paneCount) \(paneCount == 1 ? "pane" : "panes")"
        let positional = "Window \(displayIndex) of \(totalCount)"
        let named = displayName.isEmpty ? positional : "\(positional), \(displayName)"
        if isSelected {
            return "\(named), \(paneText), active"
        }
        return "\(named), \(paneText)"
    }
}

private struct GhosttyPreviewIndexBadge: View {
    let displayIndex: Int
    let isSelected: Bool
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        Text("\(displayIndex)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                isSelected
                    ? chromeStyle.accentForeground
                    : TerminalSelectionSheetPalette.primary
            )
            .frame(width: 28, height: 28)
            .background(
                isSelected
                    ? chromeStyle.accent
                    : Color(uiColor: .secondarySystemBackground).opacity(0.84),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 0.75)
                }
            }
    }
}

private struct GhosttyPaneTopologyDiagram: View {
    static let contentInset: CGFloat = 6
    private static let outerCornerRadius: CGFloat = 12
    private static let tileInset: CGFloat = 2

    let panes: [GhosttyPaneSelectionSheetRenderProjection.Pane]
    let selectedPaneID: UUID?
    let size: CGSize
    let accent: Color
    let pendingRemovalPaneID: UUID?
    let onSelect: (UUID) -> Void
    let onLongPress: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    let onRemove: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void

    static func contentSize(for outerSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, outerSize.width - contentInset * 2),
            height: max(1, outerSize.height - contentInset * 2)
        )
    }

    private var layout: PaneTopologyLayout.Frames? {
        let topologyPanes = panes.compactMap { pane in
            pane.frame.map { PaneTopologyLayout.Pane(id: pane.id, frame: $0) }
        }
        guard topologyPanes.count == panes.count else { return nil }
        return PaneTopologyLayout.frames(
            panes: topologyPanes,
            size: Self.contentSize(for: size)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout {
                ForEach(panes) { pane in
                    if let frame = layout.frame(for: pane.id) {
                        let tile = frame.insetBy(dx: Self.tileInset, dy: Self.tileInset)
                        paneTile(for: pane, size: tile.size)
                            .position(x: tile.midX, y: tile.midY)
                    }
                }
            }
        }
        .frame(width: Self.contentSize(for: size).width, height: Self.contentSize(for: size).height)
        .padding(Self.contentInset)
        .frame(width: size.width, height: size.height)
        .background(
            Color.black.opacity(0.18),
            in: RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.outerCornerRadius, style: .continuous)
                .strokeBorder(TerminalSelectionSheetPalette.stroke, lineWidth: 1)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: pendingRemovalPaneID)
    }

    private func paneTile(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        size: CGSize
    ) -> some View {
        let selected = pane.id == selectedPaneID
        let radius = max(1, min(6, min(size.width, size.height) * 0.18))

        return ZStack(alignment: .topTrailing) {
            Button {
                onSelect(pane.id)
            } label: {
                paneLabel(for: pane, size: size)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                    .onEnded { _ in onLongPress(pane) }
            )
            .allowsHitTesting(pendingRemovalPaneID != pane.id)
            .accessibilityIdentifier("terminal.pane.tile.\(pane.id.uuidString)")
            .accessibilityLabel(accessibilityLabel(for: pane))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text("Remove Pane")) {
                onLongPress(pane)
            }

            if pendingRemovalPaneID == pane.id {
                GhosttySelectionContextActionButton(
                    title: "Remove Pane",
                    accessibilityIdentifier: "terminal.pane.remove.\(pane.id.uuidString)",
                    action: { onRemove(pane) }
                )
                .padding(4)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            selected
                ? accent.opacity(0.24)
                : TerminalSelectionSheetPalette.row.opacity(0.84),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    selected ? accent : TerminalSelectionSheetPalette.stroke,
                    lineWidth: selected ? 2 : 1
                )
        }
    }

    private func directoryName(
        _ pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        guard !pane.tmuxCurrentPath.isEmpty else { return "—" }
        let name = (pane.tmuxCurrentPath as NSString).lastPathComponent
        return name.isEmpty ? pane.tmuxCurrentPath : name
    }

    private func paneLabel(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        size: CGSize
    ) -> some View {
        VStack(spacing: 2) {
            Text(directoryName(pane))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    pane.id == selectedPaneID
                        ? accent
                        : TerminalSelectionSheetPalette.primary
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Text(commandName(for: pane))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .frame(width: max(0, size.width - 16))
        .frame(width: size.width, height: size.height, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }

    private func commandName(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        pane.tmuxCurrentCommand.isEmpty ? "—" : pane.tmuxCurrentCommand
    }

    private func accessibilityLabel(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        "\(directoryName(pane)), \(commandName(for: pane))"
    }
}

private struct GhosttyPaneSheetActionButton: View {
    let title: String
    let systemName: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: (() -> Void)?

    var body: some View {
        Button {
            Haptic.tap()
            action?()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: systemName)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(GhosttyPaneSheetActionButtonStyle(isEnabled: action != nil))
        .frame(maxWidth: .infinity)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .contentShape(Rectangle())
        .disabled(action == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GhosttyPaneSheetActionButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed && isEnabled
                    ? TerminalSelectionSheetPalette.controlPressedFill
                    : Color.clear
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct GhosttyPaneSheetZoomControl: View {
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Zoom")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent)
        .padding(.horizontal, 11)
        .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel("Zoom")
        .accessibilityIdentifier("terminal.pane.zoom")
    }
}

private struct GhosttyPaneSheetControlDivider: View {
    var body: some View {
        Rectangle()
            .fill(TerminalSelectionSheetPalette.stroke)
            .frame(width: 0.75, height: 24)
            .accessibilityHidden(true)
    }
}

private extension Optional where Wrapped == GhosttyPanePreviewSession.PreviewState {
    var accessibilityValue: String {
        switch self {
        case .ready:
            "Preview ready"
        case .failed:
            "Preview unavailable"
        case .pending, .none:
            "Preview loading"
        }
    }
}

private extension View {
    @ViewBuilder
    func ghosttySelectionContextActionSurface() -> some View {
        let shape = Circle()

        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.tint(GhosttySelectionContextActionPalette.glassTint).interactive(), in: shape)
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 9)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttySelectionContextActionPalette.fallbackFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttySelectionContextActionPalette.stroke, lineWidth: 1)
                }
                .shadow(color: GhosttySelectionContextActionPalette.shadow, radius: 18, y: 10)
        }
    }

}
