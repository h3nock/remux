import Foundation

struct PhysicalKeyboardChromeState: Equatable {
    private(set) var usesFloatingChrome: Bool
    private(set) var isChromeVisible: Bool
    private(set) var autoHideToken: Int?
    private var nextToken = 0
    private var hidesChrome: Bool

    init(isPhysicalKeyboardConnected: Bool, hidesChrome: Bool) {
        self.usesFloatingChrome = isPhysicalKeyboardConnected
        self.isChromeVisible = !isPhysicalKeyboardConnected || !hidesChrome
        self.autoHideToken = nil
        self.hidesChrome = hidesChrome
    }

    mutating func keyboardConnectionChanged(
        isConnected: Bool,
        hidesChrome: Bool
    ) {
        usesFloatingChrome = isConnected
        self.hidesChrome = hidesChrome
        autoHideToken = nil
        isChromeVisible = !isConnected || !hidesChrome
    }

    mutating func terminalTapped() {
        revealIfAutoHidden()
    }

    mutating func chromeInteracted() {
        revealIfAutoHidden()
    }

    mutating func autoHideElapsed(token: Int) {
        guard autoHideToken == token else { return }
        autoHideToken = nil
        isChromeVisible = false
    }

    private mutating func revealIfAutoHidden() {
        guard usesFloatingChrome, hidesChrome else { return }
        isChromeVisible = true
        nextToken += 1
        autoHideToken = nextToken
    }
}
