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

/// Shared selector-sheet content geometry beneath system-owned navigation
/// chrome. Preview regions own their bounded viewport heights; the sheet
/// derives its presentation size from this content instead of duplicating
/// the navigation bar's geometry in detent arithmetic.
enum TerminalSelectionSheetLayout {
    static let horizontalContentPadding: CGFloat = 16

    /// Standard iPhone sheet detents place root content eight points below
    /// the native navigation bar. Custom-height detents don't inherit that
    /// inset, so fitted selectors supply the same boundary explicitly.
    static let navigationToContextSpacing: CGFloat = 8
    static let contextHeight: CGFloat = 16
    static let contextToContentSpacing: CGFloat = 12
    static let contentToActionsSpacing: CGFloat = 16
    static let actionBarHeight: CGFloat = 44
    static let actionsBottomPadding: CGFloat = 8

    @MainActor
    static func nativeNavigationBarHeight(width: CGFloat) -> CGFloat {
        UINavigationBar().sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
    }

    static func fixedChromeHeight(
        navigationBarHeight: CGFloat
    ) -> CGFloat {
        max(0, navigationBarHeight)
            + navigationToContextSpacing + contextHeight + contextToContentSpacing
            + contentToActionsSpacing + actionBarHeight + actionsBottomPadding
    }

    static func maximumContentHeight(
        availableHeight: CGFloat,
        navigationBarHeight: CGFloat
    ) -> CGFloat {
        guard availableHeight.isFinite else { return 0 }
        return max(
            0,
            availableHeight - fixedChromeHeight(
                navigationBarHeight: navigationBarHeight
            )
        )
    }

    static func sheetHeight(
        contentHeight: CGFloat,
        navigationBarHeight: CGFloat
    ) -> CGFloat {
        fixedChromeHeight(navigationBarHeight: navigationBarHeight)
            + max(0, contentHeight)
    }

    static func contentWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite else { return 1 }
        return max(1, availableWidth - horizontalContentPadding * 2)
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

/// Shared selector anatomy below a native navigation bar.
struct TerminalSelectionSheetContent<Content: View, Actions: View>: View {
    let context: String
    let content: Content
    let actions: Actions

    init(
        context: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.context = context
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: TerminalSelectionSheetLayout.contextToContentSpacing) {
                TerminalSelectionSheetContextLabel(text: context)
                    .padding(
                        .horizontal,
                        TerminalSelectionSheetLayout.horizontalContentPadding
                    )

                content
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            actions
                .padding(
                    .horizontal,
                    TerminalSelectionSheetLayout.horizontalContentPadding
                )
                .frame(maxWidth: .infinity)
                .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
                .padding(.top, TerminalSelectionSheetLayout.contentToActionsSpacing)
                .padding(.bottom, TerminalSelectionSheetLayout.actionsBottomPadding)
        }
        .padding(.top, TerminalSelectionSheetLayout.navigationToContextSpacing)
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
