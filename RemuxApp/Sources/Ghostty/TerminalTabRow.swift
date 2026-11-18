import SwiftUI

/// A wide iPad window's tabs: the session's tmux windows or Herdr tabs on a row of their own under the toolbar, as
/// Safari's tab bar sits under its toolbar, with New Tab at the end. Labels never truncate: when the tabs outgrow the
/// row it scrolls sideways, keeping the selected tab in view.
struct TerminalTabRow: View {
    typealias Window = GhosttyWindowSelectionSheetRenderProjection.Window

    let windows: [Window]
    let noun: GhosttyTopLevelNoun
    let theme: TerminalTheme
    let isEnabled: Bool
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void

    static let height: CGFloat = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(windows) { window in
                        tab(window)
                    }
                    newTabButton
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .onAppear { scrollToSelection(proxy) }
            .onChange(of: selectedID) { _, _ in
                withAnimation(.snappy) { scrollToSelection(proxy) }
            }
        }
        .frame(height: Self.height)
        .background(theme.terminalSurfaceBackground)
        .overlay(alignment: .bottom) {
            Color(uiColor: theme.terminalCompositeSeparatorUIColor).frame(height: 1)
        }
        .environment(\.colorScheme, theme.terminalChromeColorScheme)
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.tab-row")
    }

    private var selectedID: UUID? {
        windows.first(where: \.isSelected)?.id
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        proxy.scrollTo(selectedID, anchor: .center)
    }

    private func tab(_ window: Window) -> some View {
        Button {
            Haptic.tap()
            onSelect(window.id)
        } label: {
            HStack(spacing: 6) {
                Text(window.displayName.isEmpty ? "\(window.displayIndex)" : window.displayName)
                    .font(.subheadline.weight(window.isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                if let agentStatus = window.agentStatus {
                    TerminalAgentDot(status: agentStatus)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 32)
            .foregroundStyle(window.isSelected ? Color.primary : Color.secondary)
            .background {
                if window.isSelected {
                    Capsule().fill(Color.primary.opacity(0.14))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(window.id)
        .accessibilityLabel(window.displayName.isEmpty ? "\(noun.singular) \(window.displayIndex)" : window.displayName)
        .accessibilityValue("\(noun.singular) \(window.displayIndex) of \(window.totalCount)")
        .accessibilityAddTraits(window.isSelected ? .isSelected : [])
        .accessibilityIdentifier("terminal.tab.\(window.displayIndex)")
    }

    private var newTabButton: some View {
        Button {
            Haptic.tap()
            onCreate()
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.medium))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("New \(noun.singular)")
        .accessibilityIdentifier("terminal.tab.new")
    }
}
