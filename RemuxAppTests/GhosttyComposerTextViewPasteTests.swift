import XCTest
import UIKit
@testable import Remux

@MainActor
final class GhosttyComposerTextViewPasteTests: XCTestCase {
    func testAPictureIsNotPastedWhileASendIsInFlight() {
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let textView = GhosttyComposerUITextView()
        var pastedAttachments = 0
        textView.onPasteAttachment = {
            pastedAttachments += 1
            return true
        }
        let paste = #selector(UITextView.paste(_:))

        XCTAssertTrue(textView.canPerformAction(paste, withSender: nil), "A copied picture can be pasted.")

        textView.allowsUserEdits = false
        XCTAssertFalse(textView.canPerformAction(paste, withSender: nil))
        textView.paste(nil)
        XCTAssertEqual(pastedAttachments, 0, "A send in flight would drop a picture pasted meanwhile.")

        textView.allowsUserEdits = true
        textView.paste(nil)
        XCTAssertEqual(pastedAttachments, 1)
    }
}
