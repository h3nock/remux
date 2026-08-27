import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum ShortcutsSettingsSheetPalette {
    static let iconSurface = RemuxAppPalette.rowIconSurface
}

private enum ShortcutEditorPalette {
    static let sectionFill = RemuxAppPalette.rowSurface
    static let sectionStroke = RemuxAppPalette.separator
    static let separator = RemuxAppPalette.separator
    static let modeRailFill = RemuxAppPalette.rowIconSurface
    static let modeRailStroke = RemuxAppPalette.separator
    static let sectionCornerRadius = GhosttyShortcutSurfacePalette.cornerRadiusLarge
}

struct ShortcutsSettingsSheet: View {
    @ObservedObject var store: ShortcutStore
    let theme: TerminalTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShortcutsSettingsView(
                store: store,
                theme: theme,
                onDismiss: { dismiss() }
            )
        }
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var store: ShortcutStore
    let theme: TerminalTheme
    var onDismiss: (() -> Void)?

    @State private var editorRequest: ShortcutEditorRequest?
    @State private var collectionEditorRequest: ShortcutCollectionEditorRequest?
    @State private var restoreCollection: ShortcutCollectionID?
    @State private var editMode: EditMode = .inactive

    init(
        store: ShortcutStore,
        theme: TerminalTheme,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        self.theme = theme
        self.onDismiss = onDismiss
    }

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.orderedCollections) { collection in
                    collectionRow(collection)
                        .shortcutSettingsListRowSurface()
                }
                .onDelete { indexSet in
                    let collections = store.snapshot.orderedCollections
                    let collectionIDs = indexSet.map { collections[$0].id }
                    store.update { snapshot in
                        for id in collectionIDs {
                            snapshot.deleteCollection(id: id)
                        }
                    }
                }
                .onMove { source, destination in
                    store.update { $0.moveCollections(from: source, to: destination) }
                }
            } header: {
                Text("Collections")
                    .font(GhosttyShortcutTypography.sectionLabel)
                    .foregroundStyle(RemuxAppPalette.sectionHeader)
            }

            if store.snapshot.hasMissingStarterCollections {
                Section {
                    Button {
                        store.update {
                            $0.restoreMissingStarterCollections(
                                StarterShortcuts.collections,
                                starters: StarterShortcuts.all
                            )
                        }
                    } label: {
                        Label("Restore Default Collections", systemImage: "arrow.counterclockwise")
                    }
                    .shortcutSettingsListRowSurface()
                }
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .remuxAppGroupedScrollBackground()
        .remuxAppChrome(theme: theme)
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Shortcuts")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()

                Button {
                    collectionEditorRequest = .new(snapshot: store.snapshot)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Collection")
            }
        }
        .environment(\.editMode, $editMode)
        .sheet(item: $collectionEditorRequest) { request in
            ShortcutCollectionEditorSheet(request: request, theme: theme) { collection in
                store.update { $0.upsertCollection(collection) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .remuxSheetPresentationBackground()
            .ghosttyTerminalChromePresentation()
        }
        .sheet(item: $editorRequest) { request in
            ShortcutEditorSheet(request: request, theme: theme) { shortcut, favorite in
                store.update {
                    $0.upsertShortcut(shortcut)
                    if favorite {
                        $0.setFavorite(true, shortcutID: shortcut.id)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .remuxSheetPresentationBackground()
            .ghosttyTerminalChromePresentation()
        }
        .confirmationDialog(
            "Restore Default Shortcuts",
            isPresented: Binding(
                get: { restoreCollection != nil },
                set: { isPresented in
                    if !isPresented {
                        restoreCollection = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let collection = restoreCollection {
                Button("Restore \(store.snapshot.collectionTitle(collection)) Defaults") {
                    store.update {
                        $0.restoreMissingStarters(in: collection, starters: StarterShortcuts.all)
                    }
                    restoreCollection = nil
                }
            }
        } message: {
            if let collection = restoreCollection {
                Text("This re-adds missing default shortcuts for \(store.snapshot.collectionTitle(collection)). Existing edits stay unchanged.")
            }
        }
    }

    private func favoriteCount(in collection: ShortcutCollectionID) -> Int {
        store.snapshot.shortcuts(in: collection).filter { store.snapshot.isFavorite($0.id) }.count
    }

    private func collectionRow(_ collection: ShortcutCollection) -> some View {
        NavigationLink {
            ShortcutCollectionDetailView(
                store: store,
                theme: theme,
                collectionID: collection.id,
                addShortcut: {
                    editorRequest = .new(defaultCollection: collection.id, snapshot: store.snapshot)
                },
                editShortcut: { shortcut in
                    editorRequest = .edit(shortcut, snapshot: store.snapshot)
                },
                editCollection: {
                    if let current = store.snapshot.collection(id: collection.id) {
                        collectionEditorRequest = .edit(current)
                    }
                },
                restoreStarters: {
                    restoreCollection = collection.id
                }
            )
        } label: {
            collectionRowLabel(collection)
        }
    }

    private func collectionRowLabel(_ collection: ShortcutCollection) -> some View {
        ShortcutCollectionSettingsRow(
            collection: collection,
            totalCount: store.snapshot.shortcuts(in: collection.id).count,
            visibleCount: store.snapshot.visibleShortcuts(in: collection.id).count,
            favoriteCount: favoriteCount(in: collection.id)
        )
    }
}

private struct ShortcutCollectionDetailView: View {
    @ObservedObject var store: ShortcutStore
    let theme: TerminalTheme
    let collectionID: ShortcutCollectionID
    let addShortcut: () -> Void
    let editShortcut: (Shortcut) -> Void
    let editCollection: () -> Void
    let restoreStarters: () -> Void
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.shortcuts(in: collectionID)) { shortcut in
                    ShortcutSettingsEditableRow(
                        shortcut: shortcut,
                        isFavorite: store.snapshot.isFavorite(shortcut.id),
                        editShortcut: {
                            editShortcut(shortcut)
                        },
                        toggleFavorite: {
                            store.update {
                                $0.setFavorite(!$0.isFavorite(shortcut.id), shortcutID: shortcut.id)
                            }
                        },
                        deleteShortcut: {
                            store.update { $0.deleteShortcut(id: shortcut.id) }
                        },
                        toggleHidden: {
                            store.update { $0.setHidden(!shortcut.isHidden, shortcutID: shortcut.id) }
                        }
                    )
                    .shortcutSettingsListRowSurface()
                }
                .onDelete { indexSet in
                    let shortcuts = store.snapshot.shortcuts(in: collectionID)
                    store.update { snapshot in
                        for index in indexSet {
                            snapshot.deleteShortcut(id: shortcuts[index].id)
                        }
                    }
                }
                .onMove { source, destination in
                    store.update {
                        $0.moveShortcuts(in: collectionID, from: source, to: destination)
                    }
                }
            } footer: {
                Text("Swipe to favorite, hide, or delete. Use Edit to reorder.")
            }

            if StarterShortcuts.collectionIDs.contains(collectionID) {
                Section {
                    Button {
                        restoreStarters()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 24, height: 24)

                            Text("Restore Default Shortcuts")
                                .font(GhosttyShortcutTypography.rowText)

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(GhosttySheetPalette.primary)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .shortcutSettingsListRowSurface()
                }
            }
        }
        .navigationTitle(store.snapshot.collectionTitle(collectionID))
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .remuxAppGroupedScrollBackground()
        .remuxAppChrome(theme: theme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()

                Button(action: addShortcut) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Shortcut")

                Menu {
                    Button("Rename Collection") {
                        editCollection()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Collection Actions")
            }
        }
        .environment(\.editMode, $editMode)
    }
}

private extension View {
    func shortcutSettingsListRowSurface() -> some View {
        remuxAppListRowSurface()
    }
}

private struct ShortcutSettingsEditableRow: View {
    @Environment(\.editMode) private var editMode

    let shortcut: Shortcut
    let isFavorite: Bool
    let editShortcut: () -> Void
    let toggleFavorite: () -> Void
    let deleteShortcut: () -> Void
    let toggleHidden: () -> Void

    var body: some View {
        ShortcutSettingsRow(
            shortcut: shortcut,
            isFavorite: isFavorite
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                editShortcut()
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isEditing {
                Button {
                    toggleFavorite()
                } label: {
                    Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: "star")
                }
                .tint(.yellow)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isEditing {
                Button(role: .destructive) {
                    deleteShortcut()
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button {
                    toggleHidden()
                } label: {
                    Label(shortcut.isHidden ? "Show" : "Hide", systemImage: shortcut.isHidden ? "eye" : "eye.slash")
                }
                .tint(.gray)
            }
        }
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }
}

private struct ShortcutSettingsRow: View {
    let shortcut: Shortcut
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(shortcut.title)
                .font(GhosttyShortcutTypography.shortcutCommandFull)
                .foregroundStyle(shortcut.isHidden ? GhosttySheetPalette.secondary : GhosttySheetPalette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let hint = shortcut.hint, !hint.isEmpty {
                Text(hint)
                    .font(GhosttyShortcutTypography.secondaryText)
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }

            if shortcut.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .accessibilityLabel("Hidden")
            }
        }
    }
}

private struct ShortcutCollectionSettingsRow: View {
    let collection: ShortcutCollection
    let totalCount: Int
    let visibleCount: Int
    let favoriteCount: Int

    var body: some View {
        HStack(spacing: 13) {
            ShortcutCollectionIconView(icon: collection.icon)
                .foregroundStyle(GhosttySheetPalette.primary)
                .frame(width: 34, height: 34)
                .background(
                    ShortcutsSettingsSheetPalette.iconSurface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title)
                    .font(GhosttyShortcutTypography.collectionTitle)
                    .foregroundStyle(GhosttySheetPalette.primary)
                Text(summary)
                    .font(GhosttyShortcutTypography.secondaryText)
                    .foregroundStyle(GhosttySheetPalette.secondary)
            }

            Spacer()

            if favoriteCount > 0 {
                Label("\(favoriteCount)", systemImage: "star.fill")
                    .font(GhosttyShortcutTypography.badge)
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        if totalCount == visibleCount {
            "\(visibleCount) shortcuts"
        } else {
            "\(visibleCount) visible of \(totalCount)"
        }
    }
}

struct ShortcutCollectionEditorRequest: Identifiable {
    let id = UUID()
    let collection: ShortcutCollection?
    let nextSortIndex: Int

    static func new(snapshot: ShortcutStoreSnapshot) -> Self {
        ShortcutCollectionEditorRequest(
            collection: nil,
            nextSortIndex: (snapshot.collections.map(\.sortIndex).max() ?? -1) + 1
        )
    }

    static func edit(_ collection: ShortcutCollection) -> Self {
        ShortcutCollectionEditorRequest(
            collection: collection,
            nextSortIndex: collection.sortIndex
        )
    }
}

struct ShortcutCollectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: ShortcutCollectionEditorRequest
    let theme: TerminalTheme
    let onSave: (ShortcutCollection) -> Void

    @State private var title: String
    @State private var selectedPreset: ShortcutCollectionIcon
    @State private var symbolName: String

    init(
        request: ShortcutCollectionEditorRequest,
        theme: TerminalTheme,
        onSave: @escaping (ShortcutCollection) -> Void
    ) {
        self.request = request
        self.theme = theme
        self.onSave = onSave
        let initialIcon = request.collection?.icon ?? .folder
        _title = State(initialValue: request.collection?.title ?? "")
        _selectedPreset = State(initialValue: initialIcon)
        _symbolName = State(initialValue: initialIcon.editableSystemSymbolName ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ShortcutEditorSection("Collection") {
                        ShortcutEditorTextFieldRow("Name", text: $title)
                    }

                    ShortcutEditorSection("Icon") {
                        ShortcutCollectionEditorIconSummaryRow(
                            icon: resolvedIcon,
                            detailText: iconDetailText,
                            isValid: isResolvedIconValid
                        )
                        ShortcutEditorDivider()
                        ShortcutEditorTextFieldRow("SF Symbol", text: $symbolName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ShortcutEditorDivider()
                        iconSuggestions
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RemuxAppPalette.background.ignoresSafeArea())
            .navigationTitle(request.collection == nil ? "New Collection" : "Edit Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                    }
                    .disabled(!canSave)
                }
            }
        }
        .remuxAppChrome(theme: theme)
    }

    private var iconSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShortcutCollectionIcon.suggestedIcons) { icon in
                    ShortcutCollectionIconSuggestionButton(
                        icon: icon,
                        isSelected: isIconSelected(icon),
                        action: {
                            selectIcon(icon)
                        }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResolvedIconValid
    }

    private var resolvedIcon: ShortcutCollectionIcon {
        let trimmedSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSymbol.isEmpty {
            return .system(trimmedSymbol)
        }
        return selectedPreset
    }

    private var isResolvedIconValid: Bool {
        switch resolvedIcon.rawValue {
        case ShortcutCollectionIcon.claude.rawValue, ShortcutCollectionIcon.codex.rawValue:
            return true
        default:
            #if canImport(UIKit)
            return UIImage(systemName: resolvedIcon.systemImageName) != nil
            #else
            return true
            #endif
        }
    }

    private var iconDetailText: String {
        if isResolvedIconValid {
            if let symbolName = resolvedIcon.editableSystemSymbolName {
                return "SF Symbol: \(symbolName)"
            }
            return "Built-in icon"
        }
        return "Unknown SF Symbol"
    }

    private func selectIcon(_ icon: ShortcutCollectionIcon) {
        selectedPreset = icon
        symbolName = icon.editableSystemSymbolName ?? ""
    }

    private func isIconSelected(_ icon: ShortcutCollectionIcon) -> Bool {
        resolvedIcon == icon
    }

    private func save() {
        let existing = request.collection
        let collection = ShortcutCollection(
            id: existing?.id ?? ShortcutCollectionID(rawValue: "custom.\(UUID().uuidString.lowercased())"),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: resolvedIcon,
            sortIndex: existing?.sortIndex ?? request.nextSortIndex,
            isHidden: existing?.isHidden ?? false
        )
        onSave(collection)
        dismiss()
    }
}

private struct ShortcutCollectionEditorIconSummaryRow: View {
    let icon: ShortcutCollectionIcon
    let detailText: String
    let isValid: Bool

    var body: some View {
        HStack(spacing: 14) {
            ShortcutCollectionIconView(icon: icon)
                .foregroundStyle(GhosttySheetPalette.primary)
                .frame(width: 44, height: 44)
                .background(
                    ShortcutsSettingsSheetPalette.iconSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(icon.displayTitle)
                    .font(GhosttyShortcutTypography.collectionTitle)
                    .foregroundStyle(GhosttySheetPalette.primary)
                    .lineLimit(1)

                Text(detailText)
                    .font(GhosttyShortcutTypography.secondaryText)
                    .foregroundStyle(isValid ? GhosttySheetPalette.secondary : Color(uiColor: .systemRed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 62, alignment: .center)
    }
}

private struct ShortcutCollectionIconSuggestionButton: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let icon: ShortcutCollectionIcon
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.selection()
            action()
        } label: {
            ShortcutCollectionIconView(icon: icon)
                .foregroundStyle(isSelected ? chromeStyle.accent : GhosttySheetPalette.secondary)
                .frame(width: 32, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShortcutCollectionIconSuggestionButtonStyle())
        .accessibilityLabel(icon.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ShortcutCollectionIconSuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ShortcutEditorRequest: Identifiable {
    let id = UUID()
    let shortcut: Shortcut?
    let defaultCollection: ShortcutCollectionID
    let collections: [ShortcutCollection]
    let favoriteOnSave: Bool
    let nextSortIndexByCollection: [ShortcutCollectionID: Int]

    static func new(
        defaultCollection: ShortcutCollectionID,
        favoriteOnSave: Bool = false,
        snapshot: ShortcutStoreSnapshot
    ) -> Self {
        ShortcutEditorRequest(
            shortcut: nil,
            defaultCollection: defaultCollection,
            collections: snapshot.collections,
            favoriteOnSave: favoriteOnSave,
            nextSortIndexByCollection: nextSortIndexes(in: snapshot)
        )
    }

    static func edit(
        _ shortcut: Shortcut,
        snapshot: ShortcutStoreSnapshot
    ) -> Self {
        ShortcutEditorRequest(
            shortcut: shortcut,
            defaultCollection: shortcut.collection,
            collections: snapshot.collections,
            favoriteOnSave: false,
            nextSortIndexByCollection: nextSortIndexes(in: snapshot)
        )
    }

    private static func nextSortIndexes(in snapshot: ShortcutStoreSnapshot) -> [ShortcutCollectionID: Int] {
        Dictionary(uniqueKeysWithValues: snapshot.collections.map { collection in
            let next = (snapshot.shortcuts(in: collection.id).map(\.sortIndex).max() ?? -1) + 1
            return (collection.id, next)
        })
    }
}

struct ShortcutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: ShortcutEditorRequest
    let theme: TerminalTheme
    let onSave: (Shortcut, Bool) -> Void

    @State private var collection: ShortcutCollectionID
    @State private var title: String
    @State private var hint: String
    @State private var mode: ShortcutEditorMode
    @State private var textValue: String
    @State private var submitText: Bool
    @State private var controlValue: String
    @State private var keyValue: ShortcutKey
    @State private var keyModifiers: ShortcutModifiers

    init(
        request: ShortcutEditorRequest,
        theme: TerminalTheme,
        onSave: @escaping (Shortcut, Bool) -> Void
    ) {
        self.request = request
        self.theme = theme
        self.onSave = onSave

        let shortcut = request.shortcut
        _collection = State(initialValue: shortcut?.collection ?? request.defaultCollection)
        _title = State(initialValue: shortcut?.title ?? "")
        _hint = State(initialValue: shortcut?.hint ?? "")

        switch shortcut?.sequence {
        case .text(let text, let submit):
            _mode = State(initialValue: .text)
            _textValue = State(initialValue: text)
            _submitText = State(initialValue: submit)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])

        case .control(let text):
            _mode = State(initialValue: .control)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: text)
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])

        case .key(let key, let modifiers):
            _mode = State(initialValue: .key)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: key)
            _keyModifiers = State(initialValue: modifiers)

        case .none:
            _mode = State(initialValue: .text)
            _textValue = State(initialValue: "")
            _submitText = State(initialValue: true)
            _controlValue = State(initialValue: "c")
            _keyValue = State(initialValue: .escape)
            _keyModifiers = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ShortcutEditorSection("Display") {
                        ShortcutEditorTextFieldRow("Title", text: $title)
                        ShortcutEditorDivider()
                        ShortcutEditorTextFieldRow("Hint", text: $hint)
                        ShortcutEditorDivider()
                        collectionRow
                    }

                    ShortcutEditorSection("Action") {
                        modePicker
                        ShortcutEditorDivider()
                        actionFields
                    }

                    if hasPreview {
                        ShortcutEditorSection("Preview") {
                            ShortcutEditorPreviewRow(text: previewText)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RemuxAppPalette.background.ignoresSafeArea())
            .navigationTitle(request.shortcut == nil ? "New Shortcut" : "Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                    }
                    .disabled(!canSave)
                }
            }
        }
        .remuxAppChrome(theme: theme)
    }

    private var collectionRow: some View {
        ShortcutEditorValueRow(title: "Collection") {
            Picker("Collection", selection: $collection) {
                ForEach(request.collections) { collection in
                    Text(collection.title).tag(collection.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(GhosttySheetPalette.secondary)
        }
    }

    private var modePicker: some View {
        ShortcutEditorModePicker(selection: $mode)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actionFields: some View {
        switch mode {
        case .text:
            ShortcutEditorTextFieldRow("Text", text: $textValue, axis: .vertical)
                .lineLimit(1 ... 4)
            ShortcutEditorDivider()
            ShortcutEditorToggleRow("Auto-send Enter", isOn: $submitText)

        case .control:
            ShortcutEditorTextFieldRow("Control key", text: $controlValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

        case .key:
            ShortcutEditorValueRow(title: "Key") {
                Picker("Key", selection: $keyValue) {
                    ForEach(ShortcutKey.allCases) { key in
                        Text(key.displayTitle).tag(key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(GhosttySheetPalette.secondary)
            }
            ShortcutEditorDivider()
            ShortcutEditorToggleRow("Ctrl", isOn: modifierBinding(.control))
            ShortcutEditorDivider()
            ShortcutEditorToggleRow("Opt", isOn: modifierBinding(.option))
            ShortcutEditorDivider()
            ShortcutEditorToggleRow("Shift", isOn: modifierBinding(.shift))
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sequence != nil
    }

    private var hasPreview: Bool {
        sequence != nil
    }

    private var sequence: ShortcutSequence? {
        switch mode {
        case .text:
            let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(textValue, submit: submitText)

        case .control:
            let trimmed = controlValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard GhosttyModifierState.controlText(for: trimmed) != nil else { return nil }
            return .control(trimmed)

        case .key:
            return .key(keyValue, modifiers: keyModifiers)
        }
    }

    private var previewText: String {
        switch sequence {
        case .text(let text, let submit):
            return submit ? "\(text)⏎" : text
        case .control(let text):
            return "^\(text.uppercased())"
        case .key(let key, let modifiers):
            let prefix = [
                modifiers.contains(.control) ? "Ctrl" : nil,
                modifiers.contains(.option) ? "Opt" : nil,
                modifiers.contains(.shift) ? "Shift" : nil,
            ].compactMap { $0 }.joined(separator: "-")
            return prefix.isEmpty ? key.displayTitle : "\(prefix)-\(key.displayTitle)"
        case .none:
            return " "
        }
    }

    private func save() {
        guard let sequence else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = request.shortcut
        let sortIndex: Int
        if existing?.collection == collection, let existing {
            sortIndex = existing.sortIndex
        } else {
            sortIndex = request.nextSortIndexByCollection[collection] ?? 0
        }
        let shortcut = Shortcut(
            id: existing?.id ?? UUID(),
            starterID: existing?.starterID,
            collection: collection,
            title: trimmedTitle,
            hint: trimmedHint.isEmpty ? nil : trimmedHint,
            sequence: sequence,
            sortIndex: sortIndex,
            isHidden: existing?.isHidden ?? false
        )
        onSave(shortcut, request.favoriteOnSave)
        dismiss()
    }

    private func modifierBinding(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { keyModifiers.contains(modifier) },
            set: { isEnabled in
                if isEnabled {
                    keyModifiers.insert(modifier)
                } else {
                    keyModifiers.remove(modifier)
                }
            }
        )
    }
}

private struct ShortcutEditorSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(GhosttyShortcutTypography.sectionLabel)
                .foregroundStyle(GhosttySheetPalette.secondary)
                .padding(.horizontal, 18)

            VStack(spacing: 0) {
                content
            }
            .background(ShortcutEditorPalette.sectionFill)
            .clipShape(RoundedRectangle(cornerRadius: ShortcutEditorPalette.sectionCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ShortcutEditorPalette.sectionCornerRadius, style: .continuous)
                    .strokeBorder(ShortcutEditorPalette.sectionStroke, lineWidth: 1)
            }
        }
    }
}

private struct ShortcutEditorTextFieldRow: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    private let title: String
    private let text: Binding<String>
    private let axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title
        self.text = text
        self.axis = axis
    }

    var body: some View {
        TextField(title, text: text, axis: axis)
            .font(GhosttyShortcutTypography.rowText)
            .foregroundStyle(GhosttySheetPalette.primary)
            .tint(chromeStyle.accent)
            .textFieldStyle(.plain)
            .padding(.horizontal, 18)
            .frame(minHeight: 56, alignment: .center)
    }
}

private struct ShortcutEditorValueRow<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(GhosttySheetPalette.primary)

            Spacer(minLength: 12)

            accessory
                .foregroundStyle(GhosttySheetPalette.secondary)
        }
        .font(GhosttyShortcutTypography.rowText)
        .padding(.horizontal, 18)
        .frame(minHeight: 56, alignment: .center)
    }
}

private struct ShortcutEditorModePicker: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    @Binding var selection: ShortcutEditorMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShortcutEditorMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(GhosttyShortcutTypography.compactControl)
                        .foregroundStyle(selection == mode ? GhosttySheetPalette.primary : GhosttySheetPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            selection == mode
                                ? GhosttyShortcutSurfacePalette.embeddedSelectedFill(chromeStyle)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .background(ShortcutEditorPalette.modeRailFill, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(ShortcutEditorPalette.modeRailStroke, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.14), value: selection)
    }
}

private struct ShortcutEditorToggleRow: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let title: String
    let isOn: Binding<Bool>

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: isOn)
            .font(GhosttyShortcutTypography.rowText)
            .foregroundStyle(GhosttySheetPalette.primary)
            .tint(chromeStyle.accent)
            .padding(.horizontal, 18)
            .frame(minHeight: 56, alignment: .center)
    }
}

private struct ShortcutEditorPreviewRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GhosttyShortcutTypography.shortcutCommandFull)
            .foregroundStyle(GhosttySheetPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

private struct ShortcutEditorDivider: View {
    var body: some View {
        Rectangle()
            .fill(ShortcutEditorPalette.separator)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

private enum ShortcutEditorMode: String, CaseIterable, Identifiable {
    case text
    case control
    case key

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            "Text"
        case .control:
            "Ctrl"
        case .key:
            "Key"
        }
    }
}
