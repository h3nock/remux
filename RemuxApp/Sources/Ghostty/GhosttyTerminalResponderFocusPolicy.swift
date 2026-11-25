import Foundation

struct GhosttyTerminalResponderFocusPolicy: Equatable {
    let isSelected: Bool
    let keyboardMode: GhosttyKeyboardChromeMode
    let keyboardOwner: GhosttyKeyboardOwner
    let isInputAvailable: Bool
    let isKeyboardFocusAvailable: Bool
    let isTransientInputOwnerPresented: Bool

    var isResponderEnabled: Bool {
        isInputAvailable
            && !isTransientInputOwnerPresented
    }

    var wantsFirstResponder: Bool {
        // The screen owns the keyboard. A pane that is still attaching or drawing pauses input,
        // without making the keyboard leave and return with that pane's first ready projection.
        isSelected
            && keyboardMode.enablesSystemKeyboard
            && keyboardOwner == .terminal
            && isKeyboardFocusAvailable
            && !isTransientInputOwnerPresented
    }
}

/// When the composer's field holds the keyboard.
///
/// It steps aside under whatever the terminal steps aside for: a picker, the camera, the attachment viewer, Find, the
/// shortcut settings, or a sheet over the terminal. Left wanting the keyboard there, it takes it back the moment
/// something in the sheet lets go of it (the markup canvas on Done, for one), and the keyboard then rises over the
/// sheet.
struct GhosttyComposerResponderFocusPolicy: Equatable {
    let keyboardMode: GhosttyKeyboardChromeMode
    let keyboardOwner: GhosttyKeyboardOwner
    let isTransientInputOwnerPresented: Bool

    var wantsFirstResponder: Bool {
        keyboardMode.enablesSystemKeyboard
            && keyboardOwner == .composer
            && !isTransientInputOwnerPresented
    }
}
