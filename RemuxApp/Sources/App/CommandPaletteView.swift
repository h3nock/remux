import SwiftUI

struct CommandPaletteView: View {
    let commands: [CommandPaletteItem]
    let snapshots: () -> [TerminalViewportSnapshot]
    let onSelect: (CommandPaletteAction) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [CommandPaletteItem] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command")
                TextField("Type a command or search visible terminals", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("command-palette.search")
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(LibraryHomePalette.rowSurface)

            Divider()
                .overlay(LibraryHomePalette.separator)

            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LibraryHomePalette.background)
            } else {
                List(results) { item in
                    Button {
                        onSelect(item.action)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("command-palette.item.\(item.id)")
                    .disabled(!item.isEnabled)
                    .listRowBackground(LibraryHomePalette.rowSurface)
                    .listRowSeparatorTint(LibraryHomePalette.separator)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(LibraryHomePalette.background)
            }
        }
        .frame(maxWidth: 620, maxHeight: 520)
        .background(
            LibraryHomePalette.background,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(LibraryHomePalette.separator, lineWidth: 1)
        }
        .shadow(radius: 30)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
        .task {
            results = commands
            await Task.yield()
            isSearchFocused = true
        }
        .onChange(of: query) { _, value in
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                if !value.isEmpty {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled else { return }
                results = CommandPaletteSearch.results(
                    query: value,
                    commands: commands,
                    snapshots: snapshots()
                )
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }
}
