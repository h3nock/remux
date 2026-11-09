import Foundation
import WebKit
import XCTest

@testable import Remux

final class TerminalPreviewStaticHTMLTests: XCTestCase {
    func testClientRoutesHTMLWithoutChangingFilePreviewRouting() async {
        let client = TerminalPreviewClient(
            loadFile: { _ in throw RouteError.file },
            openStaticHTML: { _ in throw RouteError.html }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.load(remotePath: "/srv/app/README.md")
        } verify: {
            XCTAssertEqual($0 as? RouteError, .file)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await client.load(remotePath: "/srv/app/index.HTML")
        } verify: {
            XCTAssertEqual($0 as? RouteError, .html)
        }
    }

    func testRemotePathsNormalizeByTheirTextAlone() {
        XCTAssertEqual(TerminalPreviewRemotePath.normalized("/srv/./app//site/../index.html"), "/srv/app/index.html")
        XCTAssertEqual(TerminalPreviewRemotePath.normalized("/../etc"), "/etc")
        XCTAssertEqual(TerminalPreviewRemotePath.normalized("/srv/app/"), "/srv/app")
        XCTAssertEqual(TerminalPreviewRemotePath.normalized("/"), "/")
        // Foundation's standardizingPath consults the phone's own files (it drops a leading /private when the rest
        // exists there); a remote path keeps every component.
        XCTAssertEqual(TerminalPreviewRemotePath.normalized("/private/var/site/index.html"), "/private/var/site/index.html")
        XCTAssertNil(TerminalPreviewRemotePath.normalized("srv/app/index.html"))
        XCTAssertNil(TerminalPreviewRemotePath.normalized("/srv/app\0/index.html"))
        XCTAssertNil(TerminalPreviewRemotePath.normalized("/srv/app\n/index.html"))
    }

    func testFolderContainmentComparesWholeComponentsByTheirBytes() {
        XCTAssertTrue(TerminalPreviewRemotePath.isInside("/srv/app", folder: "/srv/app"))
        XCTAssertTrue(TerminalPreviewRemotePath.isInside("/srv/app/site/index.html", folder: "/srv/app"))
        XCTAssertFalse(TerminalPreviewRemotePath.isInside("/srv/app-other/index.html", folder: "/srv/app"))
        XCTAssertFalse(TerminalPreviewRemotePath.isInside("/srv", folder: "/srv/app"))
        XCTAssertTrue(TerminalPreviewRemotePath.isInside("/etc/passwd", folder: "/"))

        // A composed é and an e with a combining accent are one string to Swift but different folders on a server.
        let composed = "/parent/\u{E9}"
        let decomposed = "/parent/e\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(TerminalPreviewRemotePath.isInside(decomposed + "/secret.txt", folder: composed))
    }

    func testResolverMapsEntryAndRelativeResourcesIntoDocumentFolder() throws {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(
            entryRemotePath: "/srv/app/site/index.html",
            identifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )

        XCTAssertEqual(resolver.entryPath, "/srv/app/site/index.html")
        XCTAssertEqual(resolver.documentRoot, "/srv/app/site")
        XCTAssertEqual(
            try resolver.remotePath(for: resolver.entryURL),
            "/srv/app/site/index.html"
        )
        let assetURL = try XCTUnwrap(
            URL(string: "assets/app%20icon.png", relativeTo: resolver.entryURL)?.absoluteURL
        )
        XCTAssertEqual(
            try resolver.remotePath(for: assetURL),
            "/srv/app/site/assets/app icon.png"
        )
        // Decoded once: a doubly encoded name stays a literal name inside the folder.
        let literalURL = try XCTUnwrap(
            URL(string: "%252e%252e/notes.txt", relativeTo: resolver.entryURL)?.absoluteURL
        )
        XCTAssertEqual(try resolver.remotePath(for: literalURL), "/srv/app/site/%2e%2e/notes.txt")
    }

    func testResolverRejectsResourcesOutsideTheDocumentFolder() throws {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(
            entryRemotePath: "/srv/app/site/index.html"
        )
        for outside in ["../secret.txt", "%2e%2e/secret.txt", "/srv/app/site-other/index.html"] {
            let url = try XCTUnwrap(URL(string: outside, relativeTo: resolver.entryURL)?.absoluteURL)
            XCTAssertThrowsError(try resolver.remotePath(for: url), outside) {
                XCTAssertEqual($0 as? TerminalPreviewStaticHTMLError, .resourceOutsideDocumentRoot)
            }
        }
        XCTAssertThrowsError(
            try resolver.remotePath(for: URL(string: "https://example.com/app.css")!)
        ) {
            XCTAssertEqual(
                $0 as? TerminalPreviewStaticHTMLError,
                .invalidResourceURL
            )
        }
    }

    func testResponsesCarryTheIsolationRulesAndTheFilesOwnType() throws {
        let url = URL(string: "remux-static-preview://host/srv/app/index.html")!
        for (path, mimeType, allowsCrossOrigin) in [
            ("/srv/app/index.html", "text/html", false),
            ("/srv/app/app.js", "text/javascript", true),
            ("/srv/app/module.mjs", "text/javascript", true),
            ("/srv/app/style.css", "text/css", false),
            ("/srv/app/data.json", "application/json", false),
            ("/srv/app/logo.svg", "image/svg+xml", false),
            ("/srv/app/settings.env", "application/octet-stream", false),
        ] {
            let response = try XCTUnwrap(TerminalPreviewStaticHTMLResponse.make(url: url, servedPath: path))
            XCTAssertEqual(response.statusCode, 200, path)
            XCTAssertEqual(response.mimeType, mimeType, path)
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "Content-Security-Policy"),
                TerminalPreviewStaticHTMLResponse.contentSecurityPolicy,
                path
            )
            XCTAssertEqual(response.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff", path)
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"),
                allowsCrossOrigin ? "*" : nil,
                path
            )
            XCTAssertNil(response.value(forHTTPHeaderField: "Content-Length"), path)
        }

        let directives = Dictionary(
            uniqueKeysWithValues: TerminalPreviewStaticHTMLResponse.contentSecurityPolicy
                .split(separator: ";")
                .map { $0.split(separator: " ").map(String.init) }
                .map { ($0[0], Array($0.dropFirst())) }
        )
        XCTAssertEqual(directives["sandbox"], ["allow-scripts", "allow-popups", "allow-forms", "allow-modals"])
        // No connection back to the page's own scheme: only network schemes.
        XCTAssertEqual(directives["connect-src"], ["https:", "http:", "wss:", "ws:"])
        for directive in ["frame-src", "child-src", "worker-src", "object-src"] {
            XCTAssertEqual(directives[directive], ["'none'"], directive)
        }
    }

    func testOpeningAsksForTheFolderAndThePageInOneRoundTrip() async throws {
        let calls = StaticHTMLCallLog()
        let answer = StaticHTMLTestGate()
        let server = StaticHTMLServer(files: ["/srv/app/index.html": "page"])
        let lease = server.readLease(calls: calls, answeringAfter: answer)

        let opening = Task {
            try await TerminalPreviewStaticHTMLResource.open(remotePath: "/srv/app/index.html", readLease: lease)
        }
        // All three are on the way before the server answers any of them.
        try await waitForCalls(calls, count: 3)
        let asked = await calls.lookups
        XCTAssertEqual(
            Set(asked),
            ["realPath /srv/app", "realPath /srv/app/index.html", "metadata /srv/app/index.html"]
        )
        await answer.open()
        _ = try await opening.value
    }

    func testOpeningRefusesAPageThatResolvesOutsideItsFolder() async throws {
        let server = StaticHTMLServer(
            files: ["/home/me/page.html": "elsewhere"],
            realPaths: ["/srv/app/index.html": "/home/me/page.html"]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await TerminalPreviewStaticHTMLResource.open(
                remotePath: "/srv/app/index.html",
                readLease: server.readLease()
            )
        } verify: {
            XCTAssertEqual($0 as? TerminalPreviewStaticHTMLError, .resourceOutsideDocumentRoot)
        }
    }

    func testOpeningFailsWhenTheServerCannotResolveTheFolder() async throws {
        let server = StaticHTMLServer(
            files: ["/srv/app/index.html": "page"],
            unresolvable: ["/srv/app"]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await TerminalPreviewStaticHTMLResource.open(
                remotePath: "/srv/app/index.html",
                readLease: server.readLease()
            )
        } verify: {
            XCTAssertEqual($0 as? StaticHTMLServerError, .unresolvable)
        }
    }

    func testOpeningRefusesAPageThatIsNotKnownToBeARegularFile() async throws {
        // A named pipe, a folder, and a file whose server sent no type.
        for mode: UInt32? in [0o010644, 0o040755, nil, 0o644] {
            let server = StaticHTMLServer(
                files: ["/srv/app/index.html": ""],
                modes: ["/srv/app/index.html": mode]
            )

            await XCTAssertThrowsErrorAsync {
                _ = try await TerminalPreviewStaticHTMLResource.open(
                    remotePath: "/srv/app/index.html",
                    readLease: server.readLease()
                )
            } verify: {
                XCTAssertEqual($0 as? TerminalPreviewStaticHTMLError, .resourceNotAFile, "mode \(String(describing: mode))")
            }
        }
    }

    @MainActor
    func testFilesThatResolveOutsideTheFolderAreRefusedBeforeAnythingIsSent() async throws {
        let calls = StaticHTMLCallLog()
        let server = StaticHTMLServer(
            files: [
                "/srv/app/index.html": "page",
                "/srv/app/pipe": "",
                "/home/me/.ssh/id_ed25519": "KEY",
                "/home/me/.aws/credentials": "CREDENTIALS",
            ],
            // A file that is a symlink out, and a file under a folder that is one.
            realPaths: [
                "/srv/app/key": "/home/me/.ssh/id_ed25519",
                "/srv/app/linked/credentials": "/home/me/.aws/credentials",
            ],
            unresolvable: ["/srv/app/unknown.txt"],
            modes: ["/srv/app/pipe": 0o010644]
        )
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease(calls: calls)
        )
        let handler = resource.makeSchemeHandler()

        for (name, expected) in [
            ("key", TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot),
            ("linked/credentials", .resourceOutsideDocumentRoot),
            ("pipe", .resourceNotAFile),
        ] {
            let task = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: name, relativeTo: resource.entryURL)))
            handler.webView(WKWebView(), start: task)
            try await waitUntil("\(name) was not refused") { !task.errors.isEmpty }
            XCTAssertEqual(task.errors.first as? TerminalPreviewStaticHTMLError, expected, name)
            XCTAssertTrue(task.responses.isEmpty, name)
            XCTAssertTrue(task.chunks.isEmpty, name)
        }
        let unresolvable = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "unknown.txt", relativeTo: resource.entryURL)))
        handler.webView(WKWebView(), start: unresolvable)
        try await waitUntil("a file the server could not resolve was not refused") { !unresolvable.errors.isEmpty }
        XCTAssertTrue(unresolvable.responses.isEmpty)

        let streamed = await calls.streams
        XCTAssertTrue(streamed.isEmpty, "a refused file must not be opened: \(streamed)")
    }

    @MainActor
    func testNothingIsSentForAFileUntilTheServerHasSaidWhereItIs() async throws {
        let calls = StaticHTMLCallLog()
        let answerRealPaths = StaticHTMLTestGate()
        let server = StaticHTMLServer(files: ["/srv/app/index.html": "page", "/srv/app/style.css": "p {}"])
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            // Opening makes the first three lookups; the gate holds the style sheet's real path.
            readLease: server.readLease(calls: calls, answeringRealPathsAfter: answerRealPaths, from: 4)
        )
        let task = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "style.css", relativeTo: resource.entryURL)))

        resource.makeSchemeHandler().webView(WKWebView(), start: task)
        // Both questions go out together; the metadata has its answer, the real path not yet.
        try await waitForCalls(calls, count: 5)
        let asked = await calls.lookups
        XCTAssertEqual(Set(asked.suffix(2)), ["realPath /srv/app/style.css", "metadata /srv/app/style.css"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(task.responses.isEmpty)
        XCTAssertTrue(task.chunks.isEmpty)

        await answerRealPaths.open()
        try await waitUntil("style.css was not served") { task.finishCount == 1 }
        XCTAssertEqual(task.responses.map(\.mimeType), ["text/css"])
    }

    @MainActor
    func testFilesAreReadAndTypedThroughTheirRealPath() async throws {
        let calls = StaticHTMLCallLog()
        let server = StaticHTMLServer(
            files: [
                "/data/app/index.html": "page",
                "/data/app/real.css": "p {}",
                "/data/app/.env": "TOKEN='value'",
            ],
            // The folder itself is a symlink; inside it, one file links to another and a script name links to data.
            realPaths: [
                "/srv/app": "/data/app",
                "/srv/app/index.html": "/data/app/index.html",
                "/srv/app/alias.css": "/data/app/real.css",
                "/srv/app/asset.js": "/data/app/.env",
            ]
        )
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease(calls: calls)
        )
        let handler = resource.makeSchemeHandler()

        let alias = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "alias.css", relativeTo: resource.entryURL)))
        handler.webView(WKWebView(), start: alias)
        try await waitUntil("alias.css was not served") { alias.finishCount == 1 }
        XCTAssertEqual(alias.responses.map(\.mimeType), ["text/css"])
        XCTAssertEqual(alias.chunks.reduce(Data(), +), Data("p {}".utf8))

        let script = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "asset.js", relativeTo: resource.entryURL)))
        handler.webView(WKWebView(), start: script)
        try await waitUntil("asset.js was not served") { script.finishCount == 1 }
        let response = try XCTUnwrap(script.responses.first as? HTTPURLResponse)
        XCTAssertEqual(response.mimeType, "application/octet-stream", "typed by the file it really is, not its link's name")
        XCTAssertNil(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        let streamed = await calls.streams
        XCTAssertEqual(streamed, ["/data/app/real.css", "/data/app/.env"])
    }

    @MainActor
    func testSchemeHandlerStreamsResponseChunksAndFinish() async throws {
        let server = StaticHTMLServer(files: ["/srv/app/index.html": "index"], chunked: true)
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease()
        )
        let handler = resource.makeSchemeHandler()
        let task = StaticHTMLSchemeTaskSpy(url: resource.entryURL)

        handler.webView(WKWebView(), start: task)

        try await waitUntil("scheme task did not finish") {
            task.finishCount == 1
        }
        XCTAssertEqual(task.responses.map(\.mimeType), ["text/html"])
        XCTAssertEqual(task.chunks.count, 2)
        XCTAssertEqual(
            task.chunks.reduce(Data(), +),
            Data("index".utf8)
        )
        XCTAssertTrue(task.errors.isEmpty)
    }

    @MainActor
    func testThePagesFirstRequestUsesTheOpeningCheckAndAReloadChecksAgain() async throws {
        let calls = StaticHTMLCallLog()
        let server = StaticHTMLServer(files: ["/srv/app/index.html": "index"])
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease(calls: calls)
        )
        let handler = resource.makeSchemeHandler()
        let firstTask = StaticHTMLSchemeTaskSpy(url: resource.entryURL)
        let secondTask = StaticHTMLSchemeTaskSpy(url: resource.entryURL)

        handler.webView(WKWebView(), start: firstTask)
        try await waitUntil("first scheme task did not finish") {
            firstTask.finishCount == 1
        }
        let afterFirst = await calls.lookups.count
        handler.webView(WKWebView(), start: secondTask)
        try await waitUntil("second scheme task did not finish") {
            secondTask.finishCount == 1
        }

        let lookups = await calls.lookups
        XCTAssertEqual(afterFirst, 3, "opening asked for the folder and the page; the first request asked nothing more")
        XCTAssertEqual(
            Set(lookups.dropFirst(3)),
            ["realPath /srv/app/index.html", "metadata /srv/app/index.html"]
        )
    }

    @MainActor
    func testStoppedSchemeTaskReceivesNothingAfterStopReturns() async throws {
        let entered = StaticHTMLTestGate()
        let release = StaticHTMLTestGate()
        let finished = StaticHTMLTestGate()
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: TerminalPreviewStaticHTMLReadLease(
                realPath: { $0 },
                metadata: { _ in RemuxSFTPFileMetadata(size: 4, permissions: 0o100644, modificationDate: nil) },
                stream: { _, metadata, onMetadata, onChunk in
                    await entered.open()
                    await release.wait()
                    do {
                        try await onMetadata(metadata)
                        try await onChunk(Data("late".utf8))
                    } catch {}
                    await finished.open()
                },
                close: {}
            )
        )
        let handler = resource.makeSchemeHandler()
        let webView = WKWebView()
        let task = StaticHTMLSchemeTaskSpy(url: resource.entryURL)

        handler.webView(webView, start: task)
        await entered.wait()
        handler.webView(webView, stop: task)
        await release.open()
        await finished.wait()

        XCTAssertTrue(task.responses.isEmpty)
        XCTAssertTrue(task.chunks.isEmpty)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.errors.isEmpty)
    }

    /// The page runs in the app's own web view, through the app's own scheme handler: everything a page needs from
    /// its folder works, and no way of reading a neighbouring file's bytes does.
    @MainActor
    func testAPreviewedPageUsesItsFolderButCannotReadIt() async throws {
        // The control: served without the preview's rules, the same page reads every one of those files, so a read
        // that gets nothing in the preview below was stopped rather than broken.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let plainHandler = PlainProbeSchemeHandler(files: Self.isolationProbeSite)
        configuration.setURLSchemeHandler(plainHandler, forURLScheme: TerminalPreviewStaticHTMLResource.scheme)
        let controlView = WKWebView(frame: .zero, configuration: configuration)
        controlView.load(URLRequest(url: URL(string: "\(TerminalPreviewStaticHTMLResource.scheme)://control/srv/app/index.html")!))
        let control = try await Self.probeResults(of: controlView)
        for read in Self.probeReads {
            XCTAssertTrue(control[read]?.hasPrefix("READ:") == true, "control \(read): \(control[read] ?? "missing")")
        }
        for feature in Self.probeFeatures {
            XCTAssertEqual(control[feature], "yes", "control \(feature): \(control[feature] ?? "missing")")
        }

        let server = StaticHTMLServer(files: Self.isolationProbeSite)
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease()
        )
        let webView = TerminalPreviewStaticHTMLView.makeWebView(
            schemeHandler: resource.makeSchemeHandler()
        )
        XCTAssertTrue(webView.allowsBackForwardNavigationGestures)
        webView.load(URLRequest(url: resource.entryURL))
        let results = try await Self.probeResults(of: webView)

        for feature in Self.probeFeatures {
            XCTAssertEqual(results[feature], "yes", "\(feature): \(results[feature] ?? "missing")")
        }
        for read in Self.probeReads {
            let value = try XCTUnwrap(results[read], "\(read) did not report")
            XCTAssertFalse(value.hasPrefix("READ:"), "\(read): \(value)")
            XCTAssertFalse(value.contains("SECRET"), "\(read): \(value)")
        }
        XCTAssertEqual(results["origin"], "null", "the page has an origin of its own")
    }

    @MainActor
    func testStoppingARequestWhileItsLookupIsPendingSendsAndReadsNothing() async throws {
        let calls = StaticHTMLCallLog()
        let answer = StaticHTMLTestGate()
        let server = StaticHTMLServer(files: ["/srv/app/index.html": "page", "/srv/app/style.css": "p {}"])
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease(calls: calls, answeringRealPathsAfter: answer, from: 4)
        )
        let handler = resource.makeSchemeHandler()
        let webView = WKWebView()
        let task = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "style.css", relativeTo: resource.entryURL)))

        handler.webView(webView, start: task)
        try await waitForCalls(calls, count: 5)
        handler.webView(webView, stop: task)
        await answer.open()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(task.responses.isEmpty)
        XCTAssertTrue(task.chunks.isEmpty)
        XCTAssertTrue(task.errors.isEmpty)
        XCTAssertEqual(task.finishCount, 0)
        let streamed = await calls.streams
        XCTAssertTrue(streamed.isEmpty, "a stopped request must not go on to read: \(streamed)")
    }

    @MainActor
    func testClosingThePreviewWhileALookupIsPendingClosesTheLeaseOnce() async throws {
        let calls = StaticHTMLCallLog()
        let closes = StaticHTMLCloseCounter()
        let answer = StaticHTMLTestGate()
        let server = StaticHTMLServer(
            files: ["/srv/app/index.html": "page", "/srv/app/style.css": "p {}"],
            closes: closes
        )
        let resource = try await TerminalPreviewStaticHTMLResource.open(
            remotePath: "/srv/app/index.html",
            readLease: server.readLease(calls: calls, answeringRealPathsAfter: answer, from: 4)
        )
        let task = StaticHTMLSchemeTaskSpy(url: try XCTUnwrap(URL(string: "style.css", relativeTo: resource.entryURL)))

        resource.makeSchemeHandler().webView(WKWebView(), start: task)
        try await waitForCalls(calls, count: 5)
        resource.close()

        // Closing waits for the work under way before it closes the lease, then closes it once.
        try await Task.sleep(for: .milliseconds(100))
        let closesWhileLookupPending = await closes.value()
        XCTAssertEqual(closesWhileLookupPending, 0, "the lease was closed under a pending lookup")
        await answer.open()
        for _ in 0..<200 {
            if await closes.value() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let closeCount = await closes.value()
        XCTAssertEqual(closeCount, 1)
    }

    /// Runs the probe page in `webView` and returns what each read and feature reported.
    @MainActor
    private static func probeResults(of webView: WKWebView) async throws -> [String: String] {
        var results: [String: String] = [:]
        let deadline = ContinuousClock.now + .seconds(30)
        while results["done"] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let value = try? await webView.evaluateJavaScript(
                "window.results && window.results.done ? JSON.stringify(window.results) : ''"
            )
            if let text = value as? String, !text.isEmpty {
                results = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
            }
        }
        XCTAssertEqual(results["done"], "yes", "the probe page did not finish: \(results)")
        return results
    }

    private static let probeFeatures = [
        "inlineScript", "scriptFileRan", "moduleScriptRan", "dynamicImport", "stylesheetApplied", "imageShown",
        "fontLoaded",
    ]

    private static let probeReads = [
        "fetchNeighbour", "fetchSubfolder", "xhr", "xhrAsync", "iframeRead", "objectRead", "workerFetch",
        "stylesheetRulesRead", "imagePixelsRead", "envAsScript",
    ]

    @MainActor
    func testClosingSessionClosesStaticHTMLLeaseOnce() async throws {
        let closes = StaticHTMLCloseCounter()
        let client = TerminalPreviewClient(
            loadFile: { _ in throw RouteError.file },
            openStaticHTML: { path in
                try await Self.makeResource(path: path, closes: closes)
            }
        )
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server"
        )
        let candidate = try XCTUnwrap(
            TerminalPreviewCandidate(selection: "/srv/app/index.html")
        )

        session.open(candidate, resolvingPathWith: { "/srv/app/index.html" })
        try await waitUntil("HTML resource did not become ready") {
            if case .ready = session.state { return true }
            return false
        }
        session.close()

        for _ in 0..<100 {
            if await closes.value() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closeCount = await closes.value()
        XCTAssertEqual(closeCount, 1)
    }

    func testReleasingResourceClosesLeaseWithoutRetainingResource() async throws {
        let closes = StaticHTMLCloseCounter()
        var resource: TerminalPreviewStaticHTMLResource? = try await Self.makeResource(
            path: "/srv/app/index.html",
            closes: closes
        )
        weak let releasedResource = resource

        resource = nil

        for _ in 0..<100 {
            if releasedResource == nil, await closes.value() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(releasedResource)
        let closeCount = await closes.value()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testCoordinatorKeepsSchemeNavigationAndRoutesLinkTapsExternally() async throws {
        let resource = try await Self.makeResource(
            path: "/srv/app/index.html",
            closes: StaticHTMLCloseCounter()
        )
        let recorder = NavigationRecorder()
        let coordinator = TerminalPreviewStaticHTMLView.Coordinator(
            resource: resource,
            openExternalURL: { recorder.opened.append($0) }
        )
        let webView = WKWebView()
        let externalLink = URL(string: "https://example.com/docs")!

        coordinator.webView(
            webView,
            decidePolicyFor: NavigationActionStub(url: resource.entryURL, type: .other),
            decisionHandler: { recorder.policies.append($0) }
        )
        coordinator.webView(
            webView,
            decidePolicyFor: NavigationActionStub(url: externalLink, type: .linkActivated),
            decisionHandler: { recorder.policies.append($0) }
        )
        coordinator.webView(
            webView,
            decidePolicyFor: NavigationActionStub(
                url: URL(string: "https://tracker.example.com/redirect")!,
                type: .other
            ),
            decisionHandler: { recorder.policies.append($0) }
        )

        XCTAssertEqual(recorder.policies, [.allow, .cancel, .cancel])
        XCTAssertEqual(recorder.opened, [externalLink])
    }

    @MainActor
    func testCoordinatorRoutesBlankTargetLinkTapsExternallyWithoutPopup() async throws {
        let resource = try await Self.makeResource(
            path: "/srv/app/index.html",
            closes: StaticHTMLCloseCounter()
        )
        let recorder = NavigationRecorder()
        let coordinator = TerminalPreviewStaticHTMLView.Coordinator(
            resource: resource,
            openExternalURL: { recorder.opened.append($0) }
        )
        let externalLink = URL(string: "https://example.com/report")!

        let popup = coordinator.webView(
            WKWebView(),
            createWebViewWith: WKWebViewConfiguration(),
            for: NavigationActionStub(url: externalLink, type: .linkActivated),
            windowFeatures: WKWindowFeatures()
        )

        XCTAssertNil(popup)
        XCTAssertEqual(recorder.opened, [externalLink])
    }

    nonisolated private static func makeResource(
        path: String,
        closes: StaticHTMLCloseCounter
    ) async throws -> TerminalPreviewStaticHTMLResource {
        try await TerminalPreviewStaticHTMLResource.open(
            remotePath: path,
            readLease: TerminalPreviewStaticHTMLReadLease(
                realPath: { $0 },
                metadata: { _ in RemuxSFTPFileMetadata(size: 64, permissions: 0o100644, modificationDate: nil) },
                stream: { _, _, _, _ in },
                close: { await closes.increment() }
            )
        )
    }

    /// A page that tries each way of reading the files beside it (each reports `READ:` and what it read if it got
    /// through), and uses each thing a page needs from its folder (each reports `yes`).
    private static let isolationProbeSite: [String: Data] = isolationProbeText.mapValues { Data($0.utf8) }
        .merging(["/srv/app/pixel.png": onePixelPNG, "/srv/app/probe.ttf": oneGlyphFont]) { text, _ in text }

    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    /// A TrueType font with one glyph (family RemuxProbe), made for this test with fontTools' FontBuilder.
    private static let oneGlyphFont = Data(
        base64Encoded: """
        AAEAAAAKAIAAAwAgT1MvMkUhRDUAAAEoAAAAYGNtYXAADACUAAABkAAAADRnbHlmTjxOOgAAAcwAAAA0aGVhZC+bgDQAAACsAAAANmhoZWEFegH2\
        AAAA5AAAACRobXR4ArwAZAAAAYgAAAAGbG9jYQAaAA0AAAHEAAAABm1heHAABAAGAAABCAAAACBuYW1lQS1H4AAAAgAAAABpcG9zdAAoAAAAAAJs\
        AAAAJgABAAAAAQAAjDvhcl8PPPUAAwPoAAAAAOcWnkwAAAAA5xaeTABkAAAB9AK8AAAAAwACAAAAAAAAAAEAAAMg/zgAAAJYAGQAZAH0AAEAAAAA\
        AAAAAAAAAAAAAAABAAEAAAACAAQAAQAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAwJYAZAABQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\
        AAAAAAABAAAAAAAAAAAAAAAAPz8/PwAAAEEAQQMg/zgAAAMgAMgAAAAAAAAAAAAAAAAAAAAgAAACWABkAGQAAAAAAAIAAAADAAAAFAADAAEAAAAU\
        AAQAIAAAAAQABAABAAAAQf//AAAAQf///8AAAQAAAAAAAAANABoAAAABAGQAAAH0ArwAAwAAMxEhEWQBkAK8/UQAAAEAZAAAAfQCvAADAAAzESER\
        ZAGQArz9RAAAAAAEADYAAQAAAAAAAQAKAAAAAQAAAAAAAgAHAAoAAwABBAkAAQAUABEAAwABBAkAAgAOACVSZW11eFByb2JlUmVndWxhcgBSAGUA\
        bQB1AHgAUAByAG8AYgBlAFIAZQBnAHUAbABhAHIAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAJAAA
        """
    )!

    private static let isolationProbeText: [String: String] = [
        "/srv/app/index.html": """
        <!doctype html><html><head>
        <link rel="stylesheet" href="style.css">
        <script src="app.js"></script>
        <script type="module" src="module.mjs"></script>
        </head><body><div id="probe">probe</div><img id="img" src="pixel.png">
        <script>
        window.results = {};
        const R = (k, v) => { window.results[k] = String(v); };
        R('origin', self.origin);
        R('inlineScript', 'yes');
        const wait = ms => new Promise(res => setTimeout(res, ms));
        async function run() {
          try { R('fetchNeighbour', 'READ:' + await (await fetch('notes.txt')).text()); } catch (e) { R('fetchNeighbour', 'blocked: ' + e); }
          try { R('fetchSubfolder', 'READ:' + await (await fetch('sub/deep.txt')).text()); } catch (e) { R('fetchSubfolder', 'blocked: ' + e); }
          try { const x = new XMLHttpRequest(); x.open('GET', 'notes.txt', false); x.send(); R('xhr', 'READ:' + x.responseText); } catch (e) { R('xhr', 'blocked: ' + e); }
          await new Promise(res => {
            try {
              const x = new XMLHttpRequest(); x.open('GET', 'notes.txt');
              x.onload = () => { R('xhrAsync', 'READ:' + x.responseText); res(); };
              x.onerror = () => { R('xhrAsync', 'blocked'); res(); };
              x.send();
            } catch (e) { R('xhrAsync', 'blocked: ' + e); res(); }
            setTimeout(() => { if (!window.results.xhrAsync) R('xhrAsync', 'no answer'); res(); }, 1500);
          });
          await new Promise(res => {
            const f = document.createElement('iframe'); f.src = 'notes.txt';
            f.onload = () => { try { R('iframeRead', 'READ:' + f.contentDocument.body.innerText); } catch (e) { R('iframeRead', 'blocked: ' + e); } res(); };
            document.body.appendChild(f);
            setTimeout(() => { if (!window.results.iframeRead) R('iframeRead', 'did not load'); res(); }, 1500);
          });
          await new Promise(res => {
            const o = document.createElement('object'); o.data = 'notes.txt'; o.type = 'text/plain';
            o.onload = () => { try { R('objectRead', 'READ:' + o.contentDocument.body.innerText); } catch (e) { R('objectRead', 'blocked: ' + e); } res(); };
            o.onerror = () => { R('objectRead', 'blocked'); res(); };
            document.body.appendChild(o);
            setTimeout(() => { if (!window.results.objectRead) R('objectRead', 'did not load'); res(); }, 1500);
          });
          try {
            const w = new Worker('worker.js');
            await new Promise(res => {
              w.onmessage = ev => { R('workerFetch', ev.data); res(); };
              w.onerror = () => { R('workerFetch', 'blocked'); res(); };
              setTimeout(() => { if (!window.results.workerFetch) R('workerFetch', 'no reply'); res(); }, 1500);
            });
          } catch (e) { R('workerFetch', 'blocked: ' + e); }
          await new Promise(res => {
            const s = document.createElement('script'); s.src = 'settings.env';
            s.onload = () => { R('envAsScript', window.REMUX_ENV_TOKEN ? 'READ:' + window.REMUX_ENV_TOKEN : 'ran, nothing read'); res(); };
            s.onerror = () => { R('envAsScript', 'blocked'); res(); };
            document.head.appendChild(s);
            setTimeout(() => { if (!window.results.envAsScript) R('envAsScript', 'no answer'); res(); }, 1500);
          });
          R('stylesheetApplied', getComputedStyle(document.getElementById('probe')).color === 'rgb(1, 2, 3)' ? 'yes' : 'no');
          try { R('stylesheetRulesRead', 'READ:' + document.styleSheets[0].cssRules[0].cssText); } catch (e) { R('stylesheetRulesRead', 'blocked: ' + e); }
          const img = document.getElementById('img');
          R('imageShown', img.complete && img.naturalWidth > 0 ? 'yes' : 'no');
          try { const c = document.createElement('canvas'); c.width = 1; c.height = 1; const g = c.getContext('2d'); g.drawImage(img, 0, 0); R('imagePixelsRead', 'READ:' + g.getImageData(0, 0, 1, 1).data.join(',')); } catch (e) { R('imagePixelsRead', 'blocked: ' + e); }
          R('scriptFileRan', window.appLoaded === true ? 'yes' : 'no');
          R('moduleScriptRan', window.moduleLoaded === true ? 'yes' : 'no');
          try { const m = await import('./value.js'); R('dynamicImport', m.value === 42 ? 'yes' : 'no'); } catch (e) { R('dynamicImport', 'blocked: ' + e); }
          try { const faces = await document.fonts.load('16px RemuxProbe'); R('fontLoaded', faces.length > 0 ? 'yes' : 'no'); } catch (e) { R('fontLoaded', 'error: ' + e); }
          R('done', 'yes');
        }
        window.addEventListener('load', () => wait(200).then(run));
        </script></body></html>
        """,
        "/srv/app/style.css": """
        @font-face { font-family: RemuxProbe; src: url(probe.ttf); }
        #probe { color: rgb(1, 2, 3); font-family: RemuxProbe; }
        """,
        "/srv/app/app.js": "window.appLoaded = true;",
        "/srv/app/module.mjs": "window.moduleLoaded = true;",
        "/srv/app/value.js": "export const value = 42;",
        "/srv/app/worker.js": "fetch('notes.txt').then(r => r.text()).then(t => postMessage('READ:' + t)).catch(e => postMessage('blocked: ' + e));",
        "/srv/app/notes.txt": "NEIGHBOUR-SECRET",
        "/srv/app/sub/deep.txt": "DEEP-SECRET",
        "/srv/app/settings.env": "REMUX_ENV_TOKEN='ENV-SECRET'",
    ]
}

private enum RouteError: Error, Equatable {
    case file
    case html
}

private enum StaticHTMLServerError: Error, Equatable {
    case unresolvable
    case noSuchFile
}

/// A server's files for the preview to read: contents by real path, the real path of each requested path that
/// isn't its own (a symlink), paths the server can't resolve, and file modes (a regular file's unless given; nil
/// for a server that sends none).
private struct StaticHTMLServer: Sendable {
    var files: [String: Data]
    var realPaths: [String: String] = [:]
    var unresolvable: Set<String> = []
    var modes: [String: UInt32?] = [:]
    /// Each file arrives in two chunks.
    var chunked = false
    /// Counts the lease's closes.
    var closes: StaticHTMLCloseCounter?

    init(
        files: [String: String],
        realPaths: [String: String] = [:],
        unresolvable: Set<String> = [],
        modes: [String: UInt32?] = [:],
        chunked: Bool = false,
        closes: StaticHTMLCloseCounter? = nil
    ) {
        self.init(
            files: files.mapValues { Data($0.utf8) },
            realPaths: realPaths,
            unresolvable: unresolvable,
            modes: modes,
            chunked: chunked,
            closes: closes
        )
    }

    init(
        files: [String: Data],
        realPaths: [String: String] = [:],
        unresolvable: Set<String> = [],
        modes: [String: UInt32?] = [:],
        chunked: Bool = false,
        closes: StaticHTMLCloseCounter? = nil
    ) {
        self.files = files
        self.realPaths = realPaths
        self.unresolvable = unresolvable
        self.modes = modes
        self.chunked = chunked
        self.closes = closes
    }

    /// With `answeringAfter`, every lookup waits for that gate; with `answeringRealPathsAfter`, real-path lookups
    /// from the `from`th call on (counting from 1) wait for it.
    func readLease(
        calls: StaticHTMLCallLog = StaticHTMLCallLog(),
        answeringAfter gate: StaticHTMLTestGate? = nil,
        answeringRealPathsAfter realPathGate: StaticHTMLTestGate? = nil,
        from firstGatedCall: Int = 1
    ) -> TerminalPreviewStaticHTMLReadLease {
        let server = self
        return TerminalPreviewStaticHTMLReadLease(
            realPath: { path in
                let call = await calls.record("realPath \(path)")
                await gate?.wait()
                if call >= firstGatedCall { await realPathGate?.wait() }
                guard !server.unresolvable.contains(path) else { throw StaticHTMLServerError.unresolvable }
                return server.realPaths[path] ?? path
            },
            metadata: { path in
                await calls.record("metadata \(path)")
                await gate?.wait()
                let realPath = server.realPaths[path] ?? path
                guard let data = server.files[realPath] else { throw StaticHTMLServerError.noSuchFile }
                return RemuxSFTPFileMetadata(
                    size: UInt64(data.count),
                    permissions: server.modes.keys.contains(path) ? server.modes[path] ?? nil : 0o100644,
                    modificationDate: nil
                )
            },
            stream: { path, metadata, onMetadata, onChunk in
                await calls.recordStream(path)
                guard let data = server.files[path] else { throw StaticHTMLServerError.noSuchFile }
                try await onMetadata(metadata)
                if server.chunked, data.count > 1 {
                    let middle = data.count / 2
                    try await onChunk(data.prefix(middle))
                    try await onChunk(data.suffix(from: middle))
                } else {
                    try await onChunk(data)
                }
            },
            close: { await server.closes?.increment() }
        )
    }
}

/// The lookups (`realPath <path>` / `metadata <path>`) and reads asked of the server, in the order they came.
private actor StaticHTMLCallLog {
    private(set) var lookups: [String] = []
    private(set) var streams: [String] = []

    @discardableResult
    func record(_ lookup: String) -> Int {
        lookups.append(lookup)
        return lookups.count
    }

    func recordStream(_ path: String) {
        streams.append(path)
    }
}

private func waitForCalls(_ calls: StaticHTMLCallLog, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await calls.lookups.count < count, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let made = await calls.lookups
    XCTAssertGreaterThanOrEqual(made.count, count, "lookups so far: \(made)")
}

/// Serves files by path with no rules at all, the way the preview did before it isolated pages: the probe's control.
private final class PlainProbeSchemeHandler: NSObject, WKURLSchemeHandler {
    private let files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let data = files[url.path] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(
            URLResponse(
                url: url,
                mimeType: TerminalPreviewStaticHTMLResponse.contentType(forPath: url.path).mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
        )
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private final class StaticHTMLSchemeTaskSpy: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest

    private let lock = NSLock()
    private var recordedResponses: [URLResponse] = []
    private var recordedChunks: [Data] = []
    private var recordedFinishCount = 0
    private var recordedErrors: [Error] = []

    init(url: URL) {
        self.request = URLRequest(url: url.absoluteURL)
    }

    var responses: [URLResponse] { lock.withLock { recordedResponses } }
    var chunks: [Data] { lock.withLock { recordedChunks } }
    var finishCount: Int { lock.withLock { recordedFinishCount } }
    var errors: [Error] { lock.withLock { recordedErrors } }

    func didReceive(_ response: URLResponse) {
        lock.withLock { recordedResponses.append(response) }
    }

    func didReceive(_ data: Data) {
        lock.withLock { recordedChunks.append(data) }
    }

    func didFinish() {
        lock.withLock { recordedFinishCount += 1 }
    }

    func didFailWithError(_ error: Error) {
        lock.withLock { recordedErrors.append(error) }
    }
}

@MainActor
private final class NavigationRecorder {
    var policies: [WKNavigationActionPolicy] = []
    var opened: [URL] = []
}

private final class NavigationActionStub: WKNavigationAction {
    private let url: URL
    private let type: WKNavigationType

    init(url: URL, type: WKNavigationType) {
        self.url = url
        self.type = type
        super.init()
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { type }
}

private actor StaticHTMLTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor StaticHTMLCloseCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@MainActor
private func waitUntil(
    _ message: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline {
            XCTFail(message)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
