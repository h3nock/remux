import SwiftUI

struct TerminalRuntimeStateIndicator: View {
    let state: TerminalRuntimeState

    private var presentation: TerminalRuntimeStatusPresentation {
        TerminalRuntimeStatusPresentation.projection(for: state)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(presentation.label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch presentation.tone {
        case .connecting:
            .blue
        case .reconnecting:
            .orange
        case .connected:
            .green
        case .disconnected:
            .red
        }
    }
}
