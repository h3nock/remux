import GhosttyKit
import SwiftUI

enum GhosttyKitBuildModePolicy {
    static func releaseValidationFailure(for mode: ghostty_build_mode_e) -> String? {
        guard mode != GHOSTTY_BUILD_MODE_RELEASE_FAST else { return nil }

        return "Remux Release requires ReleaseFast GhosttyKit; detected \(name(for: mode)). Run scripts/build_release_ghosttykit.sh and rebuild."
    }

    private static func name(for mode: ghostty_build_mode_e) -> String {
        switch mode {
        case GHOSTTY_BUILD_MODE_DEBUG:
            "Debug"
        case GHOSTTY_BUILD_MODE_RELEASE_SAFE:
            "ReleaseSafe"
        case GHOSTTY_BUILD_MODE_RELEASE_FAST:
            "ReleaseFast"
        case GHOSTTY_BUILD_MODE_RELEASE_SMALL:
            "ReleaseSmall"
        default:
            "unknown (\(mode.rawValue))"
        }
    }
}

@main
struct RemuxApp: App {
    @StateObject private var keyboardCommandCenter = AppKeyboardCommandCenter()

    init() {
        #if !DEBUG
        if let failure = GhosttyKitBuildModePolicy.releaseValidationFailure(
            for: ghostty_info().build_mode
        ) {
            fatalError(failure)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppKeyboardCommandHost(center: keyboardCommandCenter) {
                RootView()
                    .environment(\.appKeyboardCommandCenter, keyboardCommandCenter)
            }
        }
    }
}
