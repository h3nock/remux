import SwiftUI

/// A wide iPad window's tabs: the session's tmux windows or Herdr tabs as the toolbar's main item, between the
/// sidebar button and the actions, as Safari's compact tab bar keeps its tabs in the toolbar. Labels never truncate:
/// when the tabs outgrow the space the strip scrolls sideways, keeping the selected tab in view, and its edges fade
/// to show there is more.
struct TerminalTabStrip: View {
    typealias Window = GhosttyWindowSelectionSheetRenderProjection.Window

    let windows: [Window]
    let noun: GhosttyTopLevelNoun
    let isEnabled: Bool
    let onSelect: (UUID) -> Void

    /// The fade at each end of the strip, narrower than a tab's own padding, so a tab that fits never fades.
    static let edgeFade: CGFloat = 10

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(windows) { window in
                        tab(window)
                    }
                }
                .padding(.horizontal, Self.edgeFade)
            }
            .onAppear { scrollToSelection(proxy) }
            .onChange(of: selectedID) { _, _ in
                withAnimation(.snappy) { scrollToSelection(proxy) }
            }
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.edgeFade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.edgeFade)
            }
        }
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.tab-strip")
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
}
