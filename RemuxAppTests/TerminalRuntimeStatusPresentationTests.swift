import XCTest

@testable import Remux

final class TerminalRuntimeStatusPresentationTests: XCTestCase {
    func testProgressStatesExposeLoadingTitles() {
        XCTAssertEqual(
            TerminalRuntimeStatusPresentation.projection(for: .connecting),
            TerminalRuntimeStatusPresentation(
                label: "Connecting",
                tone: .connecting,
                loadingTitle: "Opening session"
            )
        )
        XCTAssertEqual(
            TerminalRuntimeStatusPresentation.projection(for: .reconnecting(.foreground)),
            TerminalRuntimeStatusPresentation(
                label: "Restoring",
                tone: .reconnecting,
                loadingTitle: "Restoring session"
            )
        )
        XCTAssertEqual(
            TerminalRuntimeStatusPresentation.projection(for: .reconnecting(.transportLoss)),
            TerminalRuntimeStatusPresentation(
                label: "Reconnecting",
                tone: .reconnecting,
                loadingTitle: "Reconnecting"
            )
        )
    }

    func testDisconnectedLabelsKeepFailureCategoryVisible() {
        let cases: [(TerminalDisconnectReason.Kind, String)] = [
            (.authentication, "Auth Failed"),
            (.serverUnreachable, "Unreachable"),
            (.hostKey, "Host Key"),
            (.profile, "Profile Error"),
            (.invalidSettings, "Settings Error"),
            (.remoteExit, "Exited"),
            (.runtime, "Terminal Error"),
            (.userClosed, "Closed"),
            (.transportIO, "Disconnected"),
            (.unknown, "Disconnected"),
        ]

        for (kind, label) in cases {
            let presentation = TerminalRuntimeStatusPresentation.projection(
                for: .disconnected(TerminalDisconnectReason(kind: kind, message: "failure"))
            )

            XCTAssertEqual(presentation.label, label, "\(kind)")
            XCTAssertEqual(presentation.tone, .disconnected, "\(kind)")
            XCTAssertNil(presentation.loadingTitle, "\(kind)")
        }
    }
}
