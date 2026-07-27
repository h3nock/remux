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

            Divider()

            if results.isEmpty {
                ContentUnavailableView.search(text: query)
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
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: 620, maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 30)
        .padding()
        .accessibilityIdentifier("command-palette")
        .onAppear {
            results = commands
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
