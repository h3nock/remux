import Combine
import UIKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyComposerTextSynchronizationTests: XCTestCase {
    @MainActor
    private final class DraftModel: ObservableObject {
        @Published var draft = ""
    }

    func testFirstCharacterSurvivesReentrantPublishedDraftSnapshot() {
        let model = DraftModel()
        let editor = UITextView()
        let synchronization = GhosttyComposerTextSynchronization()
        var observedSnapshots: [String] = []
        let subscription = observeDraftChanges(
            model,
            editor: editor,
            synchronization: synchronization,
            onSnapshot: { observedSnapshots.append($0) }
        )
        defer { subscription.cancel() }

        let typedText = "l"
        editor.text = typedText
        editor.selectedRange = NSRange(location: typedText.utf16.count, length: 0)

        synchronization.publishUserEdit(typedText) { model.draft = $0 }

        XCTAssertEqual(observedSnapshots, [""])
        XCTAssertEqual(model.draft, typedText)
        XCTAssertEqual(editor.text, typedText)
        XCTAssertEqual(editor.selectedRange, NSRange(location: typedText.utf16.count, length: 0))
    }

    func testLiteralNewlinesAndNonBMPTextSurviveReentrantPublishedDraftSnapshot() {
        let model = DraftModel()
        model.draft = "previous draft\n"
        let editor = UITextView()
        editor.text = model.draft
        let synchronization = GhosttyComposerTextSynchronization()
        var observedSnapshots: [String] = []
        let subscription = observeDraftChanges(
            model,
            editor: editor,
            synchronization: synchronization,
            onSnapshot: { observedSnapshots.append($0) }
        )
        defer { subscription.cancel() }

        let typedText = "first line\n\nlast line 🧪"
        editor.text = typedText
        editor.selectedRange = NSRange(location: typedText.utf16.count, length: 0)
        XCTAssertGreaterThan(typedText.utf16.count, typedText.count)

        synchronization.publishUserEdit(typedText) { model.draft = $0 }

        XCTAssertEqual(observedSnapshots, ["previous draft\n"])
        XCTAssertEqual(model.draft, typedText)
        XCTAssertEqual(editor.text, typedText)
        XCTAssertEqual(editor.selectedRange, NSRange(location: typedText.utf16.count, length: 0))
    }

    func testExternalClearAndReplacementStillSynchronizeAfterUserPublication() {
        let model = DraftModel()
        model.draft = "existing"
        let editor = UITextView()
        editor.text = model.draft
        let synchronization = GhosttyComposerTextSynchronization()
        let subscription = observeDraftChanges(
            model,
            editor: editor,
            synchronization: synchronization
        )
        defer { subscription.cancel() }

        let typedText = "existing plus"
        editor.text = typedText
        editor.selectedRange = NSRange(location: typedText.utf16.count, length: 0)
        synchronization.publishUserEdit(typedText) { model.draft = $0 }

        XCTAssertEqual(editor.text, typedText)
        XCTAssertEqual(model.draft, typedText)

        model.draft = "external replacement"
        synchronization.applyExternalText(model.draft, to: editor)
        XCTAssertEqual(editor.text, "external replacement")
        XCTAssertEqual(
            editor.selectedRange,
            NSRange(location: model.draft.utf16.count, length: 0)
        )

        model.draft = ""
        synchronization.applyExternalText(model.draft, to: editor)
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
    }

    private func observeDraftChanges(
        _ model: DraftModel,
        editor: UITextView,
        synchronization: GhosttyComposerTextSynchronization,
        onSnapshot: @escaping (String) -> Void = { _ in }
    ) -> AnyCancellable {
        model.objectWillChange.sink { [weak model, weak editor] in
            guard let model, let editor else { return }
            // SwiftUI's ObservableObject update begins before @Published stores
            // the new value, so this synchronous read sees the old snapshot.
            let snapshot = model.draft
            onSnapshot(snapshot)
            synchronization.applyExternalText(snapshot, to: editor)
        }
    }
}
