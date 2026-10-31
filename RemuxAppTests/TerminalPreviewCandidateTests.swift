import XCTest

@testable import Remux

final class TerminalPreviewCandidateTests: XCTestCase {
    func testAcceptsAbsoluteServerPathsAndFileURLs() {
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/srv/app/readme.md")?.remotePath,
            "/srv/app/readme.md"
        )
        XCTAssertEqual(
            TerminalPreviewCandidate(
                selection: "file:///srv/app/a%20file.pdf"
            )?.remotePath,
            "/srv/app/a file.pdf"
        )
    }

    func testRejectsNonFilePreviewTargets() {
        for value in [
            "README",
            "~/README.md",
            "https://example.com/readme.pdf",
            "file://server/srv/app/readme.md",
            "/srv/app/bad\0name.txt",
        ] {
            XCTAssertNil(TerminalPreviewCandidate(selection: value), value)
        }
    }

    func testAcceptsLoopbackURLTargets() {
        let cases: [(String, String, Int)] = [
            ("http://localhost:3000", "localhost", 3000),
            ("http://127.0.0.1:8000/docs/index.html?x=1", "127.0.0.1", 8000),
            ("https://localhost:8443/", "localhost", 8443),
            ("http://0.0.0.0:5173/", "127.0.0.1", 5173),
            ("http://[::1]:9000", "::1", 9000),
            ("http://localhost.:3000/", "localhost", 3000),
            ("localhost:3000", "localhost", 3000),
            ("127.0.0.1:8000/health", "127.0.0.1", 8000),
        ]
        for (value, host, port) in cases {
            let target = TerminalPreviewCandidate(selection: value)?.localhostTarget
            XCTAssertEqual(target?.host, host, value)
            XCTAssertEqual(target?.port, port, value)
            let expectedURL = value.hasPrefix("http") ? value : "http://" + value
            XCTAssertEqual(target?.url.absoluteString, expectedURL, value)
        }
    }

    func testDNSNamesBeginningWith127AreExternalLinks() {
        let value = "http://127.demo.example.com:3000/"
        XCTAssertNil(TerminalPreviewCandidate(selection: value))
        XCTAssertEqual(TerminalExternalLink.url(selection: value)?.host, "127.demo.example.com")
        XCTAssertNotNil(TerminalPreviewCandidate(selection: "http://127.23.4.5:3000/"))
        XCTAssertNil(TerminalExternalLink.url(selection: "http://127.23.4.5:3000/"))
    }

    func testInvalidLoopbackPortsCannotFallThroughToExternalOpen() {
        for value in ["http://localhost:70000/", "http://127.0.0.1:0/", "http://[::1]:70000/", "localhost:70000"] {
            XCTAssertNil(TerminalPreviewCandidate(selection: value), value)
            XCTAssertNil(TerminalExternalLink.url(selection: value), value)
        }
    }

    func testRejectsNonLoopbackHosts() {
        for value in [
            "http://example.com",
            "http://192.168.1.10:3000",
            "http://localhost.evil.com:3000",
            "http://127.evil.com:3000",
            "localhost",
            "ftp://localhost:21",
        ] {
            XCTAssertNil(TerminalPreviewCandidate(selection: value), value)
        }
    }

    func testAcceptsStaticHTMLPaths() {
        for value in [
            "/srv/app/index.html",
            "/srv/app/index.HTM",
            "/srv/app/page.xhtml",
        ] {
            XCTAssertEqual(
                TerminalPreviewCandidate(selection: value)?.remotePath,
                value
            )
        }
    }

    func testAcceptsRelativePathsFromAutomaticAndWordSelections() throws {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "../docs/README.md",
            explicitTarget: nil
        )

        let candidate = try XCTUnwrap(context.candidate(for: "../docs/README.md"))
        XCTAssertEqual(candidate.path, .relative("../docs/README.md"))
        XCTAssertEqual(candidate.remotePath, "../docs/README.md")

        context.selectionDidChange()
        XCTAssertEqual(
            context.candidate(for: "README.md")?.path,
            .relative("README.md")
        )
        XCTAssertEqual(
            context.candidate(for: "docs/README.md")?.path,
            .relative("docs/README.md")
        )
        XCTAssertNil(context.candidate(for: "README"))
    }

    func testResolvesRelativePathsLexicallyAgainstPaneDirectory() throws {
        let candidate = try XCTUnwrap(TerminalPreviewCandidate(
            selection: "../docs/./README.md"
        ))

        XCTAssertEqual(
            try XCTUnwrap(candidate.path).resolved(relativeTo: "/srv/app/src"),
            "/srv/app/docs/README.md"
        )
    }

    func testRejectsInvalidRelativePathInputsAndCurrentDirectories() throws {
        for value in ["~/README.md", ".", "..", "https://example.com/file.txt"] {
            XCTAssertNil(
                TerminalPreviewCandidate(selection: value),
                value
            )
        }

        let candidate = try XCTUnwrap(TerminalPreviewCandidate(
            selection: "README.md"
        ))
        let path = try XCTUnwrap(candidate.path)
        XCTAssertThrowsError(try path.resolved(relativeTo: "relative/cwd")) {
            XCTAssertEqual($0 as? TerminalPreviewPathError, .invalidCurrentDirectory)
        }
    }

    func testUnknownExtensionRemainsEligibleForQuickLookDecision() {
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/tmp/artifact.unknown")?.remotePath,
            "/tmp/artifact.unknown"
        )
        XCTAssertEqual(
            TerminalPreviewCandidate(selection: "/tmp/Makefile")?.remotePath,
            "/tmp/Makefile"
        )
    }

    func testTrimsTerminalCellPaddingWithoutRemovingInternalSpaces() {
        XCTAssertEqual(
            TerminalPreviewCandidate(
                selection: "  /tmp/a report.txt   \n"
            )?.remotePath,
            "/tmp/a report.txt"
        )
    }

    func testExplicitTargetOverridesUntouchedAutomaticSelection() {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "report",
            explicitTarget: "file:///srv/report.pdf"
        )

        XCTAssertEqual(
            context.candidate(for: "report")?.remotePath,
            "/srv/report.pdf"
        )
    }

    func testEditedSelectionCannotReuseExplicitTarget() {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "report",
            explicitTarget: "file:///srv/report.pdf"
        )

        XCTAssertNil(context.candidate(for: "report edited"))

        context.selectionDidChange()
        XCTAssertNil(context.candidate(for: "report"))
    }

    func testOpensNonLoopbackWebLinksExternally() {
        for value in [
            "https://github.com/h3nock/remux/pull/131",
            "http://example.com/docs?page=2#setup",
            "  HTTPS://Example.com/path  \n",
        ] {
            XCTAssertNotNil(TerminalExternalLink.url(selection: value), value)
        }
    }

    func testKeepsLoopbackAndNonWebTargetsOutOfExternalLinks() {
        for value in [
            "http://localhost:3000",
            "http://127.0.0.1:8000/docs",
            "http://localhost.:3000",
            "localhost:3000",
            "/srv/app/readme.md",
            "file:///srv/app/readme.md",
            "mailto:someone@example.com",
            "ftp://example.com/file",
            "https://",
            "https://example.com/a\nb",
        ] {
            XCTAssertNil(TerminalExternalLink.url(selection: value), value)
        }
    }

    func testExternalLinkUsesExplicitTargetOnlyForUntouchedAutomaticSelection() {
        var context = TerminalPreviewSelectionContext()
        context.setAutomaticSelection(
            visibleText: "the PR",
            explicitTarget: "https://github.com/h3nock/remux/pull/1"
        )

        XCTAssertEqual(
            context.externalLink(for: "the PR")?.absoluteString,
            "https://github.com/h3nock/remux/pull/1"
        )
        XCTAssertNil(context.candidate(for: "the PR"))
        XCTAssertEqual(
            TerminalExternalLink.url(
                selection: "https://github.com@example.com/login"
            )?.host,
            "example.com"
        )
        XCTAssertNil(context.externalLink(for: "the PR edited"))

        context.selectionDidChange()
        XCTAssertNil(context.externalLink(for: "the PR"))
    }
}
