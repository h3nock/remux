import SwiftUI
import UIKit

enum TerminalSelectionSheetPalette {
    static let row = Color(uiColor: .secondarySystemFill)
    static let stroke = Color.primary.opacity(0.12)
    static let controlFill = Color(uiColor: .secondarySystemFill)
    static let controlPressedFill = Color.primary.opacity(0.08)
    static let controlGroupGlassTint = Color.primary.opacity(0.035)
    static let primary = Color.primary.opacity(0.92)
    static let secondary = Color.secondary.opacity(0.78)
    static let tertiary = Color.secondary.opacity(0.56)

    static func selectedStroke(_ chromeStyle: GhosttyTerminalChromeStyle) -> Color {
        chromeStyle.selectedStroke
    }
}

/// Single source of truth for selector-sheet chrome heights. The scaffold
/// lays its rows out from these tokens and `sheetHeight` sums the same
/// tokens for the presentation detent, so the sheet always cleanly fits
/// its content: the views and the height math cannot drift apart.
enum TerminalSelectionSheetLayout {
    static let headerTopPadding: CGFloat = 14
    static let headerHeight: CGFloat = 36
    static let headerBottomPadding: CGFloat = 12
    static let contextHeight: CGFloat = 16
    static let contextToContentSpacing: CGFloat = 12
    static let contentToActionsSpacing: CGFloat = 16
    static let actionBarHeight: CGFloat = 44
    static let actionsBottomPadding: CGFloat = 8

    /// The `.height()` detent excludes the bottom safe area (verified by
    /// measurement: adding it produced exactly one safe-area of slack), so
    /// the sum covers only the content rows the scaffold lays out.
    static func sheetHeight(gridHeight: CGFloat) -> CGFloat {
        headerTopPadding + headerHeight + headerBottomPadding
            + contextHeight + contextToContentSpacing
            + gridHeight
            + contentToActionsSpacing + actionBarHeight + actionsBottomPadding
    }
}

// Existing non-selector sheets keep their established palette name and styling.
typealias GhosttySheetPalette = TerminalSelectionSheetPalette

struct TerminalSelectionSheetContextLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TerminalSelectionSheetLayout.contextHeight)
    }
}

extension View {
    func compactCircularChromeButtonLabel() -> some View {
        self
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.primary)
            .frame(width: 36, height: 36)
            .background(TerminalSelectionSheetPalette.controlFill, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

struct TerminalSelectionSheetCloseButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.tap()
            action()
        } label: {
            Image(systemName: "xmark")
                .compactCircularChromeButtonLabel()
        }
        .accessibilityLabel("Close \(title)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct TerminalSelectionTileCheckmark: View {
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(chromeStyle.accentForeground)
            .frame(width: 22, height: 22)
            .background(chromeStyle.accent, in: Circle())
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// Shared anatomy for the terminal selector sheets. Owns its header (title
/// and close button) as plain content — no navigation bar — so the sheet's
/// natural height is fully defined by views the app controls, which is what
/// lets fitted presentation size the sheet to its content.
struct TerminalSelectionSheetScaffold<Content: View, Actions: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let context: String
    let closeAccessibilityIdentifier: String
    let content: Content
    let actions: Actions

    init(
        title: String,
        context: String,
        closeAccessibilityIdentifier: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.context = context
        self.closeAccessibilityIdentifier = closeAccessibilityIdentifier
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TerminalSelectionSheetCloseButton(
                    title: title,
                    accessibilityIdentifier: closeAccessibilityIdentifier,
                    action: dismiss.callAsFunction
                )

                Spacer(minLength: 0)
            }
            .overlay {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: TerminalSelectionSheetLayout.headerHeight)
            .padding(.top, TerminalSelectionSheetLayout.headerTopPadding)
            .padding(.bottom, TerminalSelectionSheetLayout.headerBottomPadding)

            VStack(alignment: .leading, spacing: TerminalSelectionSheetLayout.contextToContentSpacing) {
                TerminalSelectionSheetContextLabel(text: context)
                    .padding(.horizontal, 16)

                content
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            actions
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
                .padding(.top, TerminalSelectionSheetLayout.contentToActionsSpacing)
                .padding(.bottom, TerminalSelectionSheetLayout.actionsBottomPadding)
        }
    }
}

struct TerminalSelectionSheetActionButton: View {
    let title: String
    let systemName: String
    let accessibilityIdentifier: String
    let action: (() -> Void)?

    var body: some View {
        let button = Button {
            Haptic.tap()
            action?()
        } label: {
            Label(title, systemImage: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .disabled(action == nil)

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glass)
                .buttonSizing(.flexible)
                .controlSize(.regular)
        } else {
            button
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }
}

extension View {
    @ViewBuilder
    func terminalSelectionSheetControlGroupSurface() -> some View {
        let shape = Capsule()

        if #available(iOS 26.0, *) {
            self
                .clipShape(shape)
                .glassEffect(
                    .regular
                        .tint(TerminalSelectionSheetPalette.controlGroupGlassTint)
                        .interactive(),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        TerminalSelectionSheetPalette.stroke,
                        lineWidth: 0.75
                    )
                }
        } else {
            self
                .background(TerminalSelectionSheetPalette.controlFill, in: shape)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        TerminalSelectionSheetPalette.stroke,
                        lineWidth: 1
                    )
                }
        }
    }

    func terminalSelectionTileChrome(
        isSelected: Bool,
        chromeStyle: GhosttyTerminalChromeStyle
    ) -> some View {
        background(TerminalSelectionSheetPalette.row)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? TerminalSelectionSheetPalette.selectedStroke(chromeStyle)
                            : TerminalSelectionSheetPalette.stroke,
                        lineWidth: isSelected ? 1.25 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    TerminalSelectionTileCheckmark(chromeStyle: chromeStyle)
                        .padding(6)
                }
            }
    }

    @ViewBuilder
    func terminalSelectionSheetPresentationBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.presentationBackground(.regularMaterial)
        }
    }

}
