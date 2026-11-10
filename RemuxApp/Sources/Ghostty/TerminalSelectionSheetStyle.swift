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
    static let selectedStroke = RemuxAccent.selectedStroke
}

/// Selector-sheet layout below the system navigation bar. The sheet's height
/// detent is the measured navigation bar height plus this fixed chrome plus
/// the content's bounded height.
enum TerminalSelectionSheetLayout {
    static let horizontalContentPadding: CGFloat = 16

    /// Standard iPhone sheet detents place root content eight points below
    /// the native navigation bar. Custom-height detents don't inherit that
    /// inset, so fitted selectors supply the same boundary explicitly.
    static let navigationToContextSpacing: CGFloat = 8
    static let contextHeight: CGFloat = 16
    /// The window sheet's group picker, in place of the context line.
    static let groupPickerHeight: CGFloat = 34
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
        navigationBarHeight: CGFloat,
        headerHeight: CGFloat = contextHeight
    ) -> CGFloat {
        max(0, navigationBarHeight)
            + navigationToContextSpacing + headerHeight + contextToContentSpacing
            + contentToActionsSpacing + actionBarHeight + actionsBottomPadding
    }

    static func maximumContentHeight(
        availableHeight: CGFloat,
        navigationBarHeight: CGFloat,
        headerHeight: CGFloat = contextHeight
    ) -> CGFloat {
        guard availableHeight.isFinite else { return 0 }
        return max(
            0,
            availableHeight - fixedChromeHeight(
                navigationBarHeight: navigationBarHeight,
                headerHeight: headerHeight
            )
        )
    }

    static func sheetHeight(
        contentHeight: CGFloat,
        navigationBarHeight: CGFloat,
        headerHeight: CGFloat = contextHeight
    ) -> CGFloat {
        fixedChromeHeight(navigationBarHeight: navigationBarHeight, headerHeight: headerHeight)
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

/// Shared selector anatomy below a native navigation bar: a header, the context line unless a sheet
/// has its own, then the content and the actions.
struct TerminalSelectionSheetContent<Header: View, Content: View, Actions: View>: View {
    let header: Header
    let content: Content
    let actions: Actions

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.header = header()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: TerminalSelectionSheetLayout.contextToContentSpacing) {
                header
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

extension TerminalSelectionSheetContent where Header == TerminalSelectionSheetContextLabel {
    init(
        context: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(header: { TerminalSelectionSheetContextLabel(text: context) }, content: content, actions: actions)
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
}
