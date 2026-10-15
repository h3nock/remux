import XCTest
@testable import Remux

final class RemuxDeepLinkTests: XCTestCase {
    func testParsesSessionWindowAndPane() throws {
        let link = try RemuxDeepLink(
            url: URL(string: "remux://open?server=Build%20Host&session=dev&window=2&pane=1")!
        )

        XCTAssertEqual(
            link,
            RemuxDeepLink(server: "Build Host", sessionName: "dev", window: "2", pane: "1")
        )
    }

    func testParsesSessionOnlyLinkWithoutPaneTarget() throws {
        let link = try RemuxDeepLink(url: URL(string: "REMUX://Open?server=box&session=main")!)

        XCTAssertEqual(link, RemuxDeepLink(server: "box", sessionName: "main"))
        XCTAssertNil(link.paneTarget)
    }

    func testTreatsEmptyWindowAndPaneAsAbsent() throws {
        let link = try RemuxDeepLink(url: URL(string: "remux://open?server=box&session=main&window=&pane=")!)

        XCTAssertNil(link.window)
        XCTAssertNil(link.pane)
    }

    func testRejectsMalformedLinks() {
        XCTAssertThrowsError(try RemuxDeepLink(url: URL(string: "https://open?server=a&session=b")!)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ParseError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try RemuxDeepLink(url: URL(string: "remux://delete?server=a&session=b")!)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ParseError, .unsupportedAction("delete"))
        }
        XCTAssertThrowsError(try RemuxDeepLink(url: URL(string: "remux://open?session=b")!)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ParseError, .missingServer)
        }
        XCTAssertThrowsError(try RemuxDeepLink(url: URL(string: "remux://open?server=a")!)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ParseError, .missingSession)
        }
        XCTAssertThrowsError(try RemuxDeepLink(url: URL(string: "remux://open?server=a&session=b%0Akill-server")!)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ParseError, .invalidValue("session"))
        }
    }

    func testURLRoundTrips() throws {
        let link = RemuxDeepLink(server: "me@box:2222", sessionName: "a b+c&d", window: "logs", pane: "%7")

        XCTAssertEqual(try RemuxDeepLink(url: link.url), link)
    }

    func testResolvesServerByIDNameUserHostAndHost() throws {
        let identity = UUID()
        let alpha = SavedServer(displayName: "Alpha", host: "alpha.test", username: "will", identityID: identity)
        let beta = SavedServer(displayName: "Beta", host: "beta.test", port: 2222, username: "root", identityID: identity)
        let servers = [alpha, beta]

        func resolve(_ reference: String) throws -> SavedServer.ID {
            try RemuxDeepLink(server: reference, sessionName: "s").resolveServer(in: servers).id
        }

        XCTAssertEqual(try resolve(beta.id.uuidString), beta.id)
        XCTAssertEqual(try resolve("alpha"), alpha.id)
        XCTAssertEqual(try resolve("root@beta.test"), beta.id)
        XCTAssertEqual(try resolve("root@beta.test:2222"), beta.id)
        XCTAssertEqual(try resolve("ALPHA.test"), alpha.id)
        XCTAssertThrowsError(try resolve("gamma")) {
            XCTAssertEqual($0 as? RemuxDeepLink.ServerResolutionError, .notFound("gamma"))
        }
    }

    func testServerResolutionPrefersNameAndReportsAmbiguity() throws {
        let identity = UUID()
        let work = SavedServer(displayName: "box", host: "shared.test", username: "work", identityID: identity)
        let personal = SavedServer(displayName: "Personal", host: "shared.test", username: "me", identityID: identity)
        let servers = [work, personal]

        XCTAssertEqual(
            try RemuxDeepLink(server: "me@shared.test", sessionName: "s").resolveServer(in: servers).id,
            personal.id
        )
        XCTAssertThrowsError(try RemuxDeepLink(server: "shared.test", sessionName: "s").resolveServer(in: servers)) {
            XCTAssertEqual($0 as? RemuxDeepLink.ServerResolutionError, .ambiguous("shared.test"))
        }
    }

    func testServerReferenceUsesNameUnlessAnotherServerSharesIt() {
        let identity = UUID()
        let alpha = SavedServer(displayName: "Alpha", host: "a.test", username: "u", identityID: identity)
        let box = SavedServer(displayName: "box", host: "b.test", username: "u", identityID: identity)
        let otherBox = SavedServer(displayName: "Box", host: "c.test", username: "u", identityID: identity)
        let servers = [alpha, box, otherBox]

        XCTAssertEqual(RemuxDeepLink.serverReference(for: alpha, among: servers), "Alpha")
        XCTAssertEqual(RemuxDeepLink.serverReference(for: box, among: servers), box.id.uuidString)
        for server in servers {
            let reference = RemuxDeepLink.serverReference(for: server, among: servers)
            XCTAssertEqual(
                try RemuxDeepLink(server: reference, sessionName: "s").resolveServer(in: servers).id,
                server.id
            )
        }
    }

    func testTmuxTargetQualifiesBySessionUnlessPaneIsGlobalID() {
        XCTAssertEqual(
            TmuxTargetSelection(sessionName: "dev", window: "2", pane: "1").tmuxTarget,
            "=dev:2.1"
        )
        XCTAssertEqual(
            TmuxTargetSelection(sessionName: "dev", window: "@4", pane: nil).tmuxTarget,
            "=dev:@4"
        )
        XCTAssertEqual(
            TmuxTargetSelection(sessionName: "dev", window: nil, pane: "2").tmuxTarget,
            "=dev:.2"
        )
        XCTAssertEqual(
            TmuxTargetSelection(sessionName: "dev", window: "2", pane: "%9").tmuxTarget,
            "%9"
        )
    }

    func testResolveCommandQuotesTarget() {
        let selection = TmuxTargetSelection(sessionName: "a\"b$c", window: "my\\win", pane: nil)

        XCTAssertEqual(
            selection.resolveCommand,
            #"display-message -p -t "=a\"b\$c:my\\win" '#{window_id} #{pane_id} #{session_name}'"#
        )
    }

    func testParsesResolveReplyOnlyForTheLinkedSession() {
        let selection = TmuxTargetSelection(sessionName: "my dev", window: nil, pane: "%12")
        let parsed = selection.parseResolveReply("@3 %12 my dev\n")

        XCTAssertEqual(parsed?.0, TmuxWindowID(3))
        XCTAssertEqual(parsed?.1, TmuxPaneID(12))
        XCTAssertNil(selection.parseResolveReply("@3 %12 other"))
        XCTAssertNil(selection.parseResolveReply("can't find window: 9"))
        XCTAssertNil(selection.parseResolveReply("@3 %12"))
    }

    func testDecodesPercentEncodedPaneIDAndAllowsEmojiNames() throws {
        let link = try RemuxDeepLink(
            url: URL(string: "remux://open?server=box&session=%F0%9F%A7%91%E2%80%8D%F0%9F%92%BB&pane=%257")!
        )

        XCTAssertEqual(link.sessionName, "🧑‍💻")
        XCTAssertEqual(link.pane, "%7")
    }
}
