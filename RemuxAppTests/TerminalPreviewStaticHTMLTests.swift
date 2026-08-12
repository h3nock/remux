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

    func testResolverMapsEntryAndRelativeResourcesIntoDocumentFolder() throws {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(
            entryRemotePath: "/srv/app/site/index.html",
            identifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )

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
    }

    func testResolverRejectsResourcesOutsideTheDocumentFolder() throws {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(
            entryRemotePath: "/srv/app/site/index.html"
        )
        let parentURL = try XCTUnwrap(
            URL(string: "../secret.txt", relativeTo: resolver.entryURL)?.absoluteURL
        )
        XCTAssertThrowsError(try resolver.remotePath(for: parentURL)) {
            XCTAssertEqual(
                $0 as? TerminalPreviewStaticHTMLError,
                .resourceOutsideDocumentRoot
            )
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

    @MainActor
    func testClosingSessionClosesStaticHTMLLeaseOnce() async throws {
        let closes = StaticHTMLCloseCounter()
        let client = TerminalPreviewClient(
            loadFile: { _ in throw RouteError.file },
            openStaticHTML: { path in
                try Self.makeResource(path: path, closes: closes)
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
        var resource: TerminalPreviewStaticHTMLResource? = try Self.makeResource(
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
    func testSchemeHandlerStreamsResponseChunksAndFinish() async throws {
        let entryMetadata = RemuxSFTPFileMetadata(
            size: 5,
            permissions: nil,
            modificationDate: nil
        )
        let resource = try TerminalPreviewStaticHTMLResource(
            remotePath: "/srv/app/index.html",
            entryMetadata: entryMetadata,
            readLease: TerminalPreviewStaticHTMLReadLease(
                stream: { _, metadata, onMetadata, onChunk in
                    try await onMetadata(metadata ?? entryMetadata)
                    try await onChunk(Data("in".utf8))
                    try await onChunk(Data("dex".utf8))
                },
                close: {}
            )
        )
        let handler = resource.makeSchemeHandler()
        let task = StaticHTMLSchemeTaskSpy(url: resource.entryURL)

        handler.webView(WKWebView(), start: task)

        try await waitUntil("scheme task did not finish") {
            task.finishCount == 1
        }
        XCTAssertEqual(task.responses.map(\.mimeType), ["text/html"])
        XCTAssertEqual(
            task.chunks.reduce(Data(), +),
            Data("index".utf8)
        )
        XCTAssertTrue(task.errors.isEmpty)
    }

    @MainActor
    func testSchemeHandlerUsesEntryMetadataOnlyForFirstRequest() async throws {
        let metadataPresence = StaticHTMLMetadataPresenceRecorder()
        let entryMetadata = RemuxSFTPFileMetadata(
            size: 5,
            permissions: nil,
            modificationDate: nil
        )
        let resource = try TerminalPreviewStaticHTMLResource(
            remotePath: "/srv/app/index.html",
            entryMetadata: entryMetadata,
            readLease: TerminalPreviewStaticHTMLReadLease(
                stream: { _, metadata, onMetadata, onChunk in
                    await metadataPresence.record(metadata != nil)
                    try await onMetadata(metadata ?? entryMetadata)
                    try await onChunk(Data("index".utf8))
                },
                close: {}
            )
        )
        let handler = resource.makeSchemeHandler()
        let firstTask = StaticHTMLSchemeTaskSpy(url: resource.entryURL)
        let secondTask = StaticHTMLSchemeTaskSpy(url: resource.entryURL)

        handler.webView(WKWebView(), start: firstTask)
        try await waitUntil("first scheme task did not finish") {
            firstTask.finishCount == 1
        }
        handler.webView(WKWebView(), start: secondTask)
        try await waitUntil("second scheme task did not finish") {
            secondTask.finishCount == 1
        }

        let recordedPresence = await metadataPresence.values()
        XCTAssertEqual(recordedPresence, [true, false])
    }

    @MainActor
    func testStoppedSchemeTaskReceivesNothingAfterStopReturns() async throws {
        let entered = StaticHTMLTestGate()
        let release = StaticHTMLTestGate()
        let finished = StaticHTMLTestGate()
        let entryMetadata = RemuxSFTPFileMetadata(
            size: 4,
            permissions: nil,
            modificationDate: nil
        )
        let resource = try TerminalPreviewStaticHTMLResource(
            remotePath: "/srv/app/index.html",
            entryMetadata: entryMetadata,
            readLease: TerminalPreviewStaticHTMLReadLease(
                stream: { _, metadata, onMetadata, onChunk in
                    await entered.open()
                    await release.wait()
                    do {
                        try await onMetadata(metadata ?? entryMetadata)
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

    @MainActor
    func testJavaScriptFetchesSameOriginResourcesThroughTheSchemeHandler() async throws {
        let site: [String: String] = [
            "/srv/app/index.html": """
            <!doctype html><html><head>\
            <script src="app.js"></script>\
            </head><body></body></html>
            """,
            "/srv/app/app.js": """
            fetch('data.json')
                .then(function (response) { return response.text(); })
                .then(function (text) { document.title = text; })
                .catch(function () { document.title = 'remux-static-fetch-failed'; });
            """,
            "/srv/app/data.json": "remux-static-fetch-ok",
        ]
        let resource = try TerminalPreviewStaticHTMLResource(
            remotePath: "/srv/app/index.html",
            entryMetadata: RemuxSFTPFileMetadata(
                size: UInt64(site["/srv/app/index.html"]!.utf8.count),
                permissions: nil,
                modificationDate: nil
            ),
            readLease: TerminalPreviewStaticHTMLReadLease(
                stream: { path, knownMetadata, onMetadata, onChunk in
                    guard let content = site[path] else {
                        throw TerminalPreviewStaticHTMLError.invalidResourceURL
                    }
                    let data = Data(content.utf8)
                    try await onMetadata(
                        knownMetadata ?? RemuxSFTPFileMetadata(
                            size: UInt64(data.count),
                            permissions: nil,
                            modificationDate: nil
                        )
                    )
                    try await onChunk(data)
                },
                close: {}
            )
        )
        let webView = TerminalPreviewStaticHTMLView.makeWebView(
            schemeHandler: resource.makeSchemeHandler()
        )
        XCTAssertTrue(webView.allowsBackForwardNavigationGestures)
        webView.load(URLRequest(url: resource.entryURL))

        try await waitUntil(
            "javascript same-origin fetch did not complete",
            timeout: .seconds(15)
        ) {
            webView.title == "remux-static-fetch-ok"
        }
    }

    @MainActor
    func testCoordinatorKeepsSchemeNavigationAndRoutesLinkTapsExternally() throws {
        let resource = try Self.makeResource(
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
    func testCoordinatorRoutesBlankTargetLinkTapsExternallyWithoutPopup() throws {
        let resource = try Self.makeResource(
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
    ) throws -> TerminalPreviewStaticHTMLResource {
        try TerminalPreviewStaticHTMLResource(
            remotePath: path,
            entryMetadata: RemuxSFTPFileMetadata(
                size: 64,
                permissions: nil,
                modificationDate: nil
            ),
            readLease: TerminalPreviewStaticHTMLReadLease(
                stream: { _, _, _, _ in },
                close: { await closes.increment() }
            )
        )
    }
}

private enum RouteError: Error, Equatable {
    case file
    case html
}

private final class StaticHTMLSchemeTaskSpy: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest

    private let lock = NSLock()
    private var recordedResponses: [URLResponse] = []
    private var recordedChunks: [Data] = []
    private var recordedFinishCount = 0
    private var recordedErrors: [Error] = []

    init(url: URL) {
        self.request = URLRequest(url: url)
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

private actor StaticHTMLMetadataPresenceRecorder {
    private var recordedValues: [Bool] = []

    func record(_ value: Bool) {
        recordedValues.append(value)
    }

    func values() -> [Bool] {
        recordedValues
    }
}

@MainActor
private func waitUntil(
    _ message: String,
    timeout: Duration = .seconds(1),
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
