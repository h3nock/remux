import SwiftUI

/// Displays either the stable committed rate or the complete shape currently
/// being armed. The repeat scheduler remains driven only by `committedTier`.
struct GhosttyKeyboardCursorTrackpadHUD: View {
    let state: GhosttyKeyboardCursorTrackpad.FeedbackState

    private let cornerRadius: CGFloat = 14
    private let dimensions: CGFloat = 64
    private let maximumArmingFill: CGFloat = 0.82

    var body: some View {
        ZStack {
            ForEach(DirectionPlacement.allCases, id: \.self) { placement in
                Group {
                    if state.direction == placement.direction {
                        tierIndicator(for: placement.direction)
                    } else {
                        baseArrow(for: placement.direction)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: placement.alignment
                )
            }
        }
        .padding(8)
        .frame(width: dimensions, height: dimensions)
        .background(GhosttyPhoneChromePalette.dock.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 6, y: 2)
        .opacity(state.isVisible ? 1 : 0)
        .scaleEffect(state.isVisible ? 1 : 0.94)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: state.isVisible)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func baseArrow(for direction: GhosttyKeyboardCursorTrackpad.Direction) -> some View {
        Image(systemName: arrowSymbol(for: direction))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.42))
    }

    @ViewBuilder
    private func tierIndicator(
        for direction: GhosttyKeyboardCursorTrackpad.Direction
    ) -> some View {
        let displayedTier = state.armingTier ?? state.committedTier
        let progress: CGFloat = state.armingTier == nil
            ? 1
            : state.armingProgress * maximumArmingFill

        switch displayedTier {
        case .neutral:
            baseArrow(for: direction)
        case .one:
            progressivelyFilledSymbol(
                arrowSymbol(for: direction),
                direction: direction,
                progress: progress,
                size: 13
            )
        case .two, .three:
            chevronGroup(
                direction: direction,
                count: displayedTier.rawValue,
                progress: progress
            )
        }
    }

    @ViewBuilder
    private func chevronGroup(
        direction: GhosttyKeyboardCursorTrackpad.Direction,
        count: Int,
        progress: CGFloat
    ) -> some View {
        if direction.isHorizontal {
            HStack(spacing: -2) {
                chevrons(direction: direction, count: count, progress: progress)
            }
        } else {
            VStack(spacing: -2) {
                chevrons(direction: direction, count: count, progress: progress)
            }
        }
    }

    @ViewBuilder
    private func chevrons(
        direction: GhosttyKeyboardCursorTrackpad.Direction,
        count: Int,
        progress: CGFloat
    ) -> some View {
        ForEach(0..<count, id: \.self) { index in
            let fillIndex = fillsFromTrailingEdge(direction)
                ? count - index - 1
                : index
            progressivelyFilledSymbol(
                chevronSymbol(for: direction),
                direction: direction,
                progress: max(0, min(1, progress * CGFloat(count) - CGFloat(fillIndex))),
                size: 12
            )
        }
    }

    private func fillsFromTrailingEdge(
        _ direction: GhosttyKeyboardCursorTrackpad.Direction
    ) -> Bool {
        direction == .left || direction == .up
    }

    private func progressivelyFilledSymbol(
        _ symbol: String,
        direction: GhosttyKeyboardCursorTrackpad.Direction,
        progress: CGFloat,
        size: CGFloat
    ) -> some View {
        ZStack {
            Image(systemName: symbol)
                .foregroundStyle(Color.white.opacity(0.42))
            Image(systemName: symbol)
                .foregroundStyle(RemuxAccent.fill)
                .mask {
                    GeometryReader { proxy in
                        Rectangle()
                            .frame(
                                width: direction.isHorizontal
                                    ? proxy.size.width * progress
                                    : proxy.size.width,
                                height: direction.isHorizontal
                                    ? proxy.size.height
                                    : proxy.size.height * progress
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: fillAlignment(for: direction)
                            )
                    }
                }
        }
        .font(.system(size: size, weight: .bold))
    }

    private func fillAlignment(
        for direction: GhosttyKeyboardCursorTrackpad.Direction
    ) -> Alignment {
        switch direction {
        case .right: .leading
        case .left: .trailing
        case .down: .top
        case .up: .bottom
        }
    }

    private func arrowSymbol(for direction: GhosttyKeyboardCursorTrackpad.Direction) -> String {
        switch direction {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }

    private func chevronSymbol(for direction: GhosttyKeyboardCursorTrackpad.Direction) -> String {
        switch direction {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    private enum DirectionPlacement: CaseIterable, Hashable {
        case up
        case down
        case left
        case right

        var direction: GhosttyKeyboardCursorTrackpad.Direction {
            switch self {
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
            }
        }

        var alignment: Alignment {
            switch self {
            case .up: .top
            case .down: .bottom
            case .left: .leading
            case .right: .trailing
            }
        }
    }
}
