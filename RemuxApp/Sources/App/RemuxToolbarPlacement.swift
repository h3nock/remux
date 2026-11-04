import SwiftUI

@MainActor
enum RemuxToolbarPlacement {
    static var confirmation: ToolbarItemPlacement {
        if #available(iOS 27.0, *) {
            .topBarPinnedTrailing
        } else {
            .confirmationAction
        }
    }
}
