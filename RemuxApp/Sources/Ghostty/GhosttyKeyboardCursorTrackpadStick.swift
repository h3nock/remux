import SwiftUI

/// The arrow-key gesture's stick, over the terminal. For a terminal hold it sits above the thumb and toward the
/// middle of the screen, where neither hand covers it and drags along either axis pass by it; for a space-bar hold,
/// centred just above the keyboard. It observes the driver's feedback itself, so a drag redraws only the stick.
struct GhosttyKeyboardCursorTrackpadStick: View {
    let feedback: GhosttyKeyboardCursorTrackpadFeedback

    /// Where the stick last was, so it fades out in place after the gesture ends.
    @State private var lastAnchor: GhosttyKeyboardCursorTrackpad.FeedbackState.Anchor?

    var body: some View {
        let state = feedback.state
        GeometryReader { proxy in
            if let anchor = state.anchor ?? lastAnchor {
                GhosttyKeyboardCursorTrackpadStickDisc(state: state)
                    .scaleEffect(state.isVisible ? 1 : 0.9)
                    .opacity(state.isVisible && state.fadeOut == nil ? 1 : 0)
                    .animation(
                        state.isVisible ? .spring(response: 0.22, dampingFraction: 0.78) : .easeOut(duration: 0.2),
                        value: state.isVisible
                    )
                    .animation(state.fadeOut.map { .linear(duration: $0) } ?? .easeOut(duration: 0.12), value: state.fadeOut)
                    .position(Self.center(
                        for: anchor,
                        windowOrigin: proxy.frame(in: .global).origin,
                        in: CGRect(origin: .zero, size: proxy.size)
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: state.anchor) { _, anchor in
            if let anchor { lastAnchor = anchor }
        }
    }

    nonisolated static let radius: CGFloat = 30

    /// Where the stick goes in `bounds`, the terminal's area, whose origin is at `windowOrigin` in the window. Above
    /// the thumb by 64 pt and 60 pt toward the middle; near the top, where there is no room above, beside it on the
    /// same side.
    nonisolated static func center(
        for anchor: GhosttyKeyboardCursorTrackpad.FeedbackState.Anchor,
        windowOrigin: CGPoint,
        in bounds: CGRect
    ) -> CGPoint {
        guard case .thumb(let windowPoint) = anchor else {
            return CGPoint(x: bounds.midX, y: bounds.maxY - 14 - radius)
        }
        let top = bounds.minY + radius + 8
        let thumb = CGPoint(x: windowPoint.x - windowOrigin.x, y: windowPoint.y - windowOrigin.y)
        let toward: CGFloat = thumb.x > bounds.midX ? -1 : 1
        let above = thumb.y - 64
        let wanted = above >= top
            ? CGPoint(x: thumb.x + toward * 60, y: above)
            : CGPoint(x: thumb.x + toward * 84, y: max(thumb.y - 8, top))
        return CGPoint(
            x: min(max(wanted.x, bounds.minX + radius + 8), bounds.maxX - radius - 8),
            y: min(wanted.y, bounds.maxY - radius - 10)
        )
    }
}

/// A 60 pt disc of the toolbar's glass and a knob in the armed key's colour. On the side the arrows are going a wedge
/// fans out from the centre, faint and growing toward the rim as the run nears repeating; repeating fills it to the
/// rim, a step denser, and every arrow pulses it, so the rhythm on screen is the repeat itself. The knob never changes.
/// Reduce Motion keeps the pulses and drops the knob's nudge.
private struct GhosttyKeyboardCursorTrackpadStickDisc: View {
    let state: GhosttyKeyboardCursorTrackpad.FeedbackState

    @State private var pulse = false
    @State private var nudge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let radius = GhosttyKeyboardCursorTrackpadStick.radius
    private static let knobRadius: CGFloat = 11
    /// How far the knob leans at the boundary of repeating.
    private static let knobTravel: CGFloat = 16

    var body: some View {
        let direction = state.direction
        let progress = state.isRepeating ? 1 : state.progress
        // While stepping the wedge runs ahead of the knob, from half the radius to the rim at the boundary.
        let reach = 0.5 + 0.5 * progress
        let strength = 0.3 + 0.7 * Double(progress)
        ZStack {
            Circle()
                .fill(Color.clear)
                .ghosttyChromeGlass(in: Circle(), isInteractive: false)
            ForEach(GhosttyKeyboardCursorTrackpad.Direction.allCases, id: \.self) { side in
                let shownReach = side == direction && progress > 0 ? reach : 0
                ZStack {
                    wedge(side, reach: shownReach, inner: 0.12, outer: 0.26 + 0.2 * strength)
                        .opacity(state.isRepeating ? 0 : 1)
                    wedge(side, reach: shownReach, inner: 0.2, outer: 0.64)
                        .opacity(state.isRepeating ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.22), value: state.isRepeating)
                wedge(side, reach: shownReach, inner: 0.04, outer: 0.2)
                    .opacity(pulse ? 1 : 0)
                    .animation(.easeOut(duration: pulse ? 0.03 : 0.2), value: pulse)
            }
            Circle()
                .fill(GhosttyPhoneChromePalette.armedKeyFill)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                .frame(width: Self.knobRadius * 2, height: Self.knobRadius * 2)
                .shadow(color: .black.opacity(0.32), radius: 3, y: 1.5)
                .offset(offset(direction, by: Self.knobTravel * progress))
                .animation(.spring(response: 0.16, dampingFraction: 0.82), value: progress)
                .offset(offset(direction, by: nudge ? 1.8 : 0))
                .animation(.spring(response: 0.1, dampingFraction: 0.55), value: nudge)
        }
        .frame(width: Self.radius * 2, height: Self.radius * 2)
        .onChange(of: state.arrowsSent) { previous, sent in
            guard sent > previous else { return }
            pulse = true
            if !reduceMotion { nudge = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                nudge = false
                try? await Task.sleep(for: .milliseconds(10))
                pulse = false
            }
        }
    }

    /// Fades in from the centre, so the slice has no visible point there.
    private func wedge(
        _ side: GhosttyKeyboardCursorTrackpad.Direction,
        reach: CGFloat,
        inner: Double,
        outer: Double
    ) -> some View {
        let ink = GhosttyPhoneChromePalette.chromeForeground
        return Wedge(angle: side.angle, reach: reach)
            .fill(RadialGradient(
                stops: [
                    .init(color: ink.opacity(0), location: 0.12),
                    .init(color: ink.opacity(inner), location: 0.45),
                    .init(color: ink.opacity(outer), location: 1),
                ],
                center: .center,
                startRadius: 0,
                endRadius: Self.radius
            ))
            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: reach)
    }

    private func offset(_ direction: GhosttyKeyboardCursorTrackpad.Direction?, by distance: CGFloat) -> CGSize {
        guard let direction else { return .zero }
        return switch direction {
        case .up: CGSize(width: 0, height: -distance)
        case .down: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        case .right: CGSize(width: distance, height: 0)
        }
    }
}

/// A slice of a circle from its centre toward one side, out to `reach` (0 to 1) of the radius.
private struct Wedge: Shape {
    private static let span: Double = 84

    var angle: Double
    var reach: CGFloat

    var animatableData: CGFloat {
        get { reach }
        set { reach = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * max(0, min(1, reach))
        var path = Path()
        guard radius > 0.5 else { return path }
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(angle - Self.span / 2),
            endAngle: .degrees(angle + Self.span / 2),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private extension GhosttyKeyboardCursorTrackpad.Direction {
    /// Degrees clockwise from the right, as SwiftUI turns.
    var angle: Double {
        switch self {
        case .right: 0
        case .down: 90
        case .left: 180
        case .up: 270
        }
    }
}
