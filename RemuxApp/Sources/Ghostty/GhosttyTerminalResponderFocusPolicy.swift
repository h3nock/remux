import Foundation

struct GhosttyTerminalResponderFocusPolicy: Equatable {
    let isSelected: Bool
    let keyboardMode: GhosttyKeyboardChromeMode
    let isPhysicalKeyboardConnected: Bool
    let isInputAvailable: Bool
    let isTransientInputOwnerPresented: Bool

    var isResponderEnabled: Bool {
        isInputAvailable && !isTransientInputOwnerPresented
    }

    var areAppKeyboardCommandsEnabled: Bool {
        !isTransientInputOwnerPresented
            && (isInputAvailable || isPhysicalKeyboardConnected)
    }

    var wantsFirstResponder: Bool {
        isSelected
            && (keyboardMode.enablesSystemKeyboard || isPhysicalKeyboardConnected)
            && (isResponderEnabled || areAppKeyboardCommandsEnabled)
    }
}
