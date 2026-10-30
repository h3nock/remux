import SwiftUI

enum GhosttySurfaceSelectionSheet: Identifiable {
    /// The window sheet, with its previews; nil for a backend whose sheet lists its windows as rows.
    case windows(GhosttyPanePreviewSession?)
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
    @State private var removal = GhosttyTileRemoval<GhosttyWindowSelectionSheetRenderProjection.Window>()
    @State private var renamePrompt: TerminalRenamePrompt?
    @State private var renameName = ""

    /// The windows' previews; nil lists the windows as rows.
    let session: GhosttyPanePreviewSession?
    let projection: GhosttyWindowSelectionSheetRenderProjection
    let topLevelNoun: GhosttyTopLevelNoun
    let sessionName: String
    let layout: PanePreviewLayout.Metrics
    let contentHeight: CGFloat
    let commandFailureMessage: String?
    /// The close the backend's server asked about, which the sheet asks while it is open.
    let askedCloseQuestion: GhosttyCloseQuestion?
    let onCreateWindow: (() -> Void)?
    let onSelect: (UUID) -> Void
    let onRemoveWindow: (UUID) -> Void
    let onRenameWindow: (UUID, String) -> Void
    /// Picking a group changes only which windows the sheet lists.
    let onShowGroup: (UUID) -> Void
    let onCreateGroup: () -> Void

    var body: some View {
        NavigationStack {
            TerminalSelectionSheetContent {
                if let grouping = projection.grouping {
                    GhosttyWindowGroupPicker(grouping: grouping, onShow: onShowGroup, onCreate: onCreateGroup)
                } else {
                    TerminalSelectionSheetContextLabel(
                        text: "\(sessionName) · \(projection.windows.count) \((projection.windows.count == 1 ? topLevelNoun.singular : topLevelNoun.plural).lowercased())"
                    )
                }
            } content: {
                Group {
                    if let session {
                        ScrollView(showsIndicators: false) {
                            GhosttyWindowPreviewGrid(
                                session: session,
                                projection: projection,
                                topLevelNoun: topLevelNoun,
                                layout: layout,
                                onSelect: select,
                                onClose: close
                            )
                        }
                        .contentMargins(
                            .horizontal,
                            TerminalSelectionSheetLayout.horizontalContentPadding,
                            for: .scrollContent
                        )
                    } else {
                        GhosttyWindowRowList(
                            windows: projection.windows,
                            topLevelNoun: topLevelNoun,
                            onSelect: select,
                            onClose: close,
                            onRename: rename
                        )
                    }
                }
                .frame(height: contentHeight)
                .accessibilityIdentifier("terminal.windows.scroll")
            } actions: {
                TerminalSelectionSheetActionButton(
                    title: "New \(topLevelNoun.singular)",
                    systemName: "plus",
                    accessibilityIdentifier: "terminal.window.new",
                    action: onCreateWindow
                )
            }
            .navigationTitle(topLevelNoun.plural)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptic.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close \(topLevelNoun.plural)")
                    .accessibilityIdentifier("terminal.windows.close")
                }
            }
        }
        .onChange(of: projection.windows.map(\.id)) { _, newValue in
            removal.keep(among: newValue)
        }
        .ghosttyCloseConfirmationDialog(closeQuestion)
        .terminalRenameAlert($renamePrompt, name: $renameName)
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

    private func select(_ window: GhosttyWindowSelectionSheetRenderProjection.Window) {
        removal.end()
        Haptic.selection()
        onSelect(window.id)
    }

    /// Closes the window, after the question its backend asks first, if any.
    private func close(_ window: GhosttyWindowSelectionSheetRenderProjection.Window) {
        Haptic.warning()
        if let window = removal.remove(window.id, among: projection.windows) {
            onRemoveWindow(window.id)
        }
    }

    private func rename(_ window: GhosttyWindowSelectionSheetRenderProjection.Window) {
        guard let field = window.renameField else { return }
        Haptic.tap()
        renameName = field.name
        renamePrompt = TerminalRenamePrompt(
            title: "Rename \(topLevelNoun.singular)", placeholder: field.placeholder, allowsEmpty: false
        ) { name in onRenameWindow(window.id, name) }
    }

    /// The window's removal asked about, else the close the backend's server asked about.
    private var closeQuestion: GhosttyCloseQuestion? {
        guard let window = removal.asked, let confirmation = window.closeConfirmation else { return askedCloseQuestion }
        return GhosttyCloseQuestion(
            confirmation: confirmation,
            confirmIdentifier: "terminal.window.remove.confirm.\(window.displayIndex)"
        ) { agreed in
            if agreed { onRemoveWindow(window.id) }
            removal.end()
        }
    }
}

struct GhosttyPaneSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var removal = GhosttyTileRemoval<GhosttyPaneSelectionSheetRenderProjection.Pane>()
    @State private var renamePrompt: TerminalRenamePrompt?
    @State private var renameName = ""

    let projection: GhosttyPaneSelectionSheetRenderProjection
    let topologySize: CGSize
    let commandFailureMessage: String?
    /// The close the backend's server asked about, which the sheet asks while it is open.
    let askedCloseQuestion: GhosttyCloseQuestion?
    let onSplitPane: (() -> Void)?
    let onStackPane: (() -> Void)?
    let onSetZoomed: (Bool) -> Void
    let onSelect: (UUID) -> Void
    let onRemovePane: (UUID) -> Void
    let onRenamePane: (UUID, String) -> Void

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
            removal.keep(among: newValue)
        }
        .ghosttyCloseConfirmationDialog(closeQuestion)
        .terminalRenameAlert($renamePrompt, name: $renameName)
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
            onSelect: { paneID in
                Haptic.selection()
                removal.end()
                onSelect(paneID)
            },
            onClose: close,
            onRename: rename,
            onClearName: { pane in onRenamePane(pane.id, "") }
        )
        .frame(height: topologySize.height, alignment: .top)
    }

    private func close(_ pane: GhosttyPaneSelectionSheetRenderProjection.Pane) {
        Haptic.warning()
        if let pane = removal.remove(pane.id, among: projection.panes) { onRemovePane(pane.id) }
    }

    private func rename(_ pane: GhosttyPaneSelectionSheetRenderProjection.Pane) {
        guard let field = pane.renameField else { return }
        Haptic.tap()
        renameName = field.name
        renamePrompt = TerminalRenamePrompt(title: "Rename Pane", placeholder: field.placeholder, allowsEmpty: true) { name in
            onRenamePane(pane.id, name)
        }
    }

    /// The pane's removal asked about, else the close the backend's server asked about.
    private var closeQuestion: GhosttyCloseQuestion? {
        guard let pane = removal.asked, let confirmation = pane.closeConfirmation else { return askedCloseQuestion }
        return GhosttyCloseQuestion(confirmation: confirmation, confirmIdentifier: "terminal.pane.remove.confirm") { agreed in
            if agreed { onRemovePane(pane.id) }
            removal.end()
        }
    }
}

/// The windows as a grid of previews of their focused panes. A long press on a tile offers its removal.
private struct GhosttyWindowPreviewGrid: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @ObservedObject var session: GhosttyPanePreviewSession

    let projection: GhosttyWindowSelectionSheetRenderProjection
    let topLevelNoun: GhosttyTopLevelNoun
    let layout: PanePreviewLayout.Metrics
    let onSelect: (GhosttyWindowSelectionSheetRenderProjection.Window) -> Void
    let onClose: (GhosttyWindowSelectionSheetRenderProjection.Window) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(layout.tilePointSize.width), spacing: layout.gridSpacing),
                count: layout.columnCount
            ),
            alignment: .center,
            spacing: layout.gridSpacing
        ) {
            ForEach(projection.windows) { window in
                Button {
                    onSelect(window)
                } label: {
                    GhosttyWindowSelectionTile(
                        topLevelNoun: topLevelNoun,
                        displayIndex: window.displayIndex,
                        displayName: window.displayName,
                        totalCount: window.totalCount,
                        paneCount: window.paneCount,
                        isSelected: window.isSelected,
                        agentStatus: window.agentStatus,
                        previewState: window.focusedPreviewPaneID.flatMap { pane in
                            projection.previewLeafIDs.contains(pane) ? session.imagesByPaneID[pane] : .failed
                        },
                        chromeStyle: chromeStyle,
                        layout: layout
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.window.tile.\(window.displayIndex)")
                .contextMenu {
                    Button(role: .destructive) {
                        onClose(window)
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("terminal.window.remove.\(window.displayIndex)")
                }
                .frame(width: layout.tilePointSize.width, height: layout.tilePointSize.height)
                .accessibilityAction(named: Text("Close \(topLevelNoun.singular)")) { onClose(window) }
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            session.reconcile(leafIDs: projection.previewLeafIDs)
            GhosttyRuntimeTrace.perf("panePreview.presentation activate kind=windows")
        }
        .onChange(of: projection.previewLeafIDs) { _, newValue in
            session.reconcile(leafIDs: newValue)
        }
    }
}

/// A tile that a selection sheet's long-press can remove.
protocol GhosttyRemovableTile: Identifiable where ID == UUID {
    /// What closing the tile asks the user first; nil when it closes at once.
    var closeConfirmation: GhosttyCloseConfirmation? { get }
}

extension GhosttyWindowSelectionSheetRenderProjection.Window: GhosttyRemovableTile {}
extension GhosttyPaneSelectionSheetRenderProjection.Pane: GhosttyRemovableTile {}

/// A selection sheet's pending close question. The backend remains responsible for the actual close.
struct GhosttyTileRemoval<Tile: GhosttyRemovableTile> {
    private(set) var asked: Tile?

    /// Returns the tile when it closes at once; otherwise retain its confirmation until answered.
    mutating func remove(_ id: UUID, among tiles: [Tile]) -> Tile? {
        guard let tile = tiles.first(where: { $0.id == id }) else { return nil }
        guard tile.closeConfirmation != nil else { return tile }
        asked = tile
        return nil
    }

    mutating func keep(among ids: [UUID]) {
        if let id = asked?.id, !ids.contains(id) { asked = nil }
    }

    mutating func end() { asked = nil }
}

/// A close the user is asked to confirm, and what their answer does.
struct GhosttyCloseQuestion {
    let confirmation: GhosttyCloseConfirmation
    let confirmIdentifier: String
    /// The dialog answers no as it goes, after any button, so a no after a yes must change nothing.
    let answer: (Bool) -> Void
}

/// The native rename alert's presentation. Its caller owns the text until the alert is dismissed.
struct TerminalRenamePrompt {
    let title: String
    let placeholder: String
    let allowsEmpty: Bool
    let save: (String) -> Void
}

extension View {
    func terminalRenameAlert(_ prompt: Binding<TerminalRenamePrompt?>, name: Binding<String>) -> some View {
        alert(
            prompt.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { prompt in
            TextField(prompt.placeholder, text: name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Name")
                .accessibilityIdentifier("terminal.rename.name")
            Button("Cancel", role: .cancel) {}
            Button("Save") { prompt.save(name.wrappedValue) }
                .disabled(!prompt.allowsEmpty && name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("terminal.rename.save")
        }
    }

    /// The selection sheets' dialog before a close, in its backend's words.
    func ghosttyCloseConfirmationDialog(_ question: GhosttyCloseQuestion?) -> some View {
        confirmationDialog(
            question?.confirmation.title ?? "",
            isPresented: Binding(
                get: { question != nil },
                set: { isPresented in
                    if !isPresented { question?.answer(false) }
                }
            ),
            titleVisibility: .visible,
            presenting: question
        ) { question in
            Button(question.confirmation.action, role: .destructive) {
                question.answer(true)
            }
            .accessibilityIdentifier(question.confirmIdentifier)
        } message: { question in
            Text(question.confirmation.message)
        }
    }
}

/// A backend's groups of windows, as Herdr's workspaces: the most recent as capsules, and the rest behind
/// More, which shows the group it lists when that one is picked. A new group ends the capsules when they
/// all fit, and ends More's menu otherwise. The order follows the backend's recency, so it holds as groups
/// are added. Each group shows its most urgent agent's dot before its name.
private struct GhosttyWindowGroupPicker: View {
    @Environment(\.colorScheme) private var colorScheme

    let grouping: GhosttyWindowSelectionSheetRenderProjection.Grouping
    let onShow: (UUID) -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(grouping.capsules.enumerated()), id: \.element.id) { index, group in
                let isShown = group.id == grouping.shownGroupID
                Button {
                    Haptic.selection()
                    onShow(group.id)
                } label: {
                    GhosttyWindowGroupCapsule(title: group.name, agentStatus: group.agentStatus, isShown: isShown)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityName(of: group))
                .accessibilityAddTraits(isShown ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("terminal.windows.group.\(index + 1)")
            }

            if grouping.overflow.isEmpty {
                newGroupCapsule
            } else {
                more
            }

            Spacer(minLength: 0)
        }
        .frame(height: TerminalSelectionSheetLayout.groupPickerHeight)
    }

    private var newGroupCapsule: some View {
        Button {
            Haptic.tap()
            onCreate()
        } label: {
            Image(systemName: "plus")
                .windowGroupCapsule(isShown: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New \(grouping.noun.singular)")
        .accessibilityIdentifier("terminal.windows.group.new")
    }

    private var more: some View {
        let shownInMore = grouping.overflow.first { $0.id == grouping.shownGroupID }
        return Menu {
            // A toggle for each group, which a menu draws as a checkmark, not a picker: the group shown may be
            // a capsule, which the menu doesn't list.
            Section {
                ForEach(grouping.overflow) { group in
                    Toggle(
                        isOn: Binding(
                            get: { group.id == grouping.shownGroupID },
                            set: { isOn in if isOn { onShow(group.id) } }
                        )
                    ) {
                        if let status = group.agentStatus {
                            Label {
                                Text(group.name)
                            } icon: {
                                Image(uiImage: status.dotImage(for: colorScheme))
                            }
                            .accessibilityLabel("\(group.name), agent \(status.word)")
                        } else {
                            Text(group.name)
                        }
                    }
                }
            }

            Button {
                onCreate()
            } label: {
                Label("New \(grouping.noun.singular)", systemImage: "plus")
            }
            .accessibilityIdentifier("terminal.windows.group.new")
        } label: {
            GhosttyWindowGroupCapsule(
                title: shownInMore?.name ?? "More",
                agentStatus: shownInMore?.agentStatus,
                isShown: shownInMore != nil,
                showsMenuIndicator: true
            )
        }
        // Top to bottom in the groups' order, as the Sessions list has them, then a new group, whichever way
        // the menu opens.
        .menuOrder(.fixed)
        .accessibilityLabel(
            shownInMore.map { "\(accessibilityName(of: $0)), more \(grouping.noun.plural.lowercased())" }
                ?? "More \(grouping.noun.plural.lowercased())"
        )
        .accessibilityIdentifier("terminal.windows.group.more")
    }

    private func accessibilityName(of group: GhosttyWindowSelectionSheetRenderProjection.Grouping.Group) -> String {
        let agent = group.agentStatus.map { ", agent \($0.word)" } ?? ""
        return "\(grouping.noun.singular) \(group.name)\(agent)"
    }
}

private struct GhosttyWindowGroupCapsule: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let agentStatus: TerminalAgentStatus?
    let isShown: Bool
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: 5) {
            if let agentStatus {
                TerminalAgentDot(status: agentStatus)
                    // A shown capsule is filled in the opposite appearance's colours.
                    .environment(\.colorScheme, isShown ? (colorScheme == .dark ? .light : .dark) : colorScheme)
            }

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .windowGroupCapsule(isShown: isShown)
    }
}

private extension View {
    /// The group picker's capsule: a shown group's is filled in the opposite appearance.
    func windowGroupCapsule(isShown: Bool) -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundStyle(isShown ? Color(uiColor: .systemBackground) : TerminalSelectionSheetPalette.primary)
            .padding(.horizontal, 14)
            .frame(height: TerminalSelectionSheetLayout.groupPickerHeight)
            .background(
                isShown ? TerminalSelectionSheetPalette.primary : TerminalSelectionSheetPalette.controlFill,
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

struct GhosttySelectionSheetFailureBanner: View {
    let message: String
    var accessibilityIdentifier = "terminal.selection.failure"

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
        .accessibilityIdentifier(accessibilityIdentifier)
    }
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
    let topLevelNoun: GhosttyTopLevelNoun
    let displayIndex: Int
    let displayName: String
    let totalCount: Int
    let paneCount: Int
    let isSelected: Bool
    let agentStatus: TerminalAgentStatus?
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
            if let agentStatus {
                TerminalAgentDot(status: agentStatus)
                    // The label sits on a dark plate in either appearance.
                    .environment(\.colorScheme, .dark)
            }

            Text(displayName.isEmpty ? "\(topLevelNoun.singular) \(displayIndex)" : displayName)
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
        let positional = "\(topLevelNoun.singular) \(displayIndex) of \(totalCount)"
        let named = displayName.isEmpty ? positional : "\(positional), \(displayName)"
        let agent = agentStatus.map { ", agent \($0.word)" } ?? ""
        if isSelected {
            return "\(named), \(paneText)\(agent), active"
        }
        return "\(named), \(paneText)\(agent)"
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
    let onSelect: (UUID) -> Void
    let onClose: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    let onRename: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void
    let onClearName: (GhosttyPaneSelectionSheetRenderProjection.Pane) -> Void

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
    }

    private func paneTile(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane,
        size: CGSize
    ) -> some View {
        let selected = pane.id == selectedPaneID
        let radius = max(1, min(6, min(size.width, size.height) * 0.18))

        return Button {
            onSelect(pane.id)
        } label: {
            paneLabel(for: pane, size: size)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let field = pane.renameField {
                Button {
                    onRename(pane)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier("terminal.pane.rename.\(pane.id.uuidString)")
                if !field.name.isEmpty {
                    Button {
                        onClearName(pane)
                    } label: {
                        Label("Clear Name", systemImage: "eraser")
                    }
                    .accessibilityIdentifier("terminal.pane.clear-name.\(pane.id.uuidString)")
                }
            }
            Button(role: .destructive) {
                onClose(pane)
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .accessibilityIdentifier("terminal.pane.remove.\(pane.id.uuidString)")
        }
        .accessibilityIdentifier("terminal.pane.tile.\(pane.id.uuidString)")
        .accessibilityLabel(accessibilityLabel(for: pane))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            if let field = pane.renameField {
                Button("Rename Pane") { onRename(pane) }
                if !field.name.isEmpty { Button("Clear Name") { onClearName(pane) } }
            }
            Button("Close Pane") { onClose(pane) }
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
        guard !pane.currentPath.isEmpty else { return "—" }
        let name = (pane.currentPath as NSString).lastPathComponent
        return name.isEmpty ? pane.currentPath : name
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

            if let agent = pane.agent {
                TerminalAgentStateLine(state: agent)
            }
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
        pane.currentCommand.isEmpty ? "—" : pane.currentCommand
    }

    private func accessibilityLabel(
        for pane: GhosttyPaneSelectionSheetRenderProjection.Pane
    ) -> String {
        let label = "\(directoryName(pane)), \(commandName(for: pane))"
        guard let agent = pane.agent else { return label }
        return "\(label), \(agent.word)"
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
