import Foundation
import WebKit
import XCTest

@testable import Remux

final class TerminalPreviewLiveWebTests: XCTestCase {
    @MainActor
    func testWebViewEnablesBackForwardNavigationGestures() {
        let webView = TerminalPreviewLiveWebView.makeWebView()

        XCTAssertTrue(webView.allowsBackForwardNavigationGestures)
    }

    func testClientRoutesLocalhostTargetsToLiveWeb() async throws {
        let client = TerminalPreviewClient(
            loadFile: { _ in throw LiveWebRouteError.file },
            openStaticHTML: { _ in throw LiveWebRouteError.html },
            openLiveWeb: { target in
                try TerminalPreviewLiveWebResource(
                    target: target,
                    localPort: 54321,
                    closeForward: {}
                )
            }
        )
        let target = try XCTUnwrap(
            TerminalPreviewCandidate(
                selection: "http://localhost:3000/app?tab=1"
            )?.localhostTarget
        )

        let resource = try await client.openLiveWeb(target)

        guard case .liveWeb(let liveWeb) = resource else {
            return XCTFail("localhost target should open a live web resource")
        }
        XCTAssertEqual(
            liveWeb.localURL.absoluteString,
            "http://127.0.0.1:54321/app?tab=1"
        )
        XCTAssertNil(resource.shareURL)
    }

    func testClientWithoutForwardCapabilityRefusesLiveWeb() async throws {
        let client = TerminalPreviewClient(
            loadFile: { _ in throw LiveWebRouteError.file },
            openStaticHTML: { _ in throw LiveWebRouteError.html }
        )
        let target = try XCTUnwrap(
            TerminalPreviewCandidate(selection: "http://localhost:3000")?
                .localhostTarget
        )

        do {
            _ = try await client.openLiveWeb(target)
            XCTFail("missing forward capability should refuse live web")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .sessionUnavailable)
        }
    }

    @MainActor
    func testSessionOpensLocalhostWithoutPathResolutionAndClosesForwardOnce() async throws {
        let closes = LiveWebCloseCounter()
        let resolutions = LiveWebCloseCounter()
        let client = TerminalPreviewClient(
            loadFile: { _ in throw LiveWebRouteError.file },
            openStaticHTML: { _ in throw LiveWebRouteError.html },
            openLiveWeb: { target in
                try TerminalPreviewLiveWebResource(
                    target: target,
                    localPort: 54321,
                    closeForward: { await closes.increment() }
                )
            }
        )
        let session = TerminalPreviewSession(
            client: client,
            serverDisplayName: "Server"
        )
        let candidate = try XCTUnwrap(
            TerminalPreviewCandidate(selection: "http://127.0.0.1:5173/")
        )

        session.open(
            candidate,
            resolvingPathWith: {
                await resolutions.increment()
                return "/unused"
            }
        )
        try await waitUntilLiveWeb("live web resource did not become ready") {
            if case .ready(_, .liveWeb) = session.state { return true }
            return false
        }
        let resolutionCount = await resolutions.value()
        XCTAssertEqual(resolutionCount, 0)

        session.close()
        for _ in 0..<100 {
            if await closes.value() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closeCount = await closes.value()
        XCTAssertEqual(closeCount, 1)
    }

    func testResourceClosesForwardOnceAcrossCloseAndRelease() async throws {
        let closes = LiveWebCloseCounter()
        var resource: TerminalPreviewLiveWebResource? =
            try TerminalPreviewLiveWebResource(
                target: TerminalPreviewLocalhostTarget(
                    host: "localhost",
                    port: 3000,
                    scheme: "http",
                    pathQuery: "/"
                ),
                localPort: 54321,
                closeForward: { await closes.increment() }
            )

        resource?.close()
        resource?.close()
        resource = nil

        for _ in 0..<100 {
            if await closes.value() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let closeCount = await closes.value()
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testCoordinatorAllowsLocalOriginAndRoutesExternalLinkTaps() throws {
        let resource = try TerminalPreviewLiveWebResource(
            target: TerminalPreviewLocalhostTarget(
                host: "localhost",
                port: 3000,
                scheme: "http",
                pathQuery: "/"
            ),
            localPort: 54321,
            closeForward: {}
        )
        let recorder = LiveWebPolicyRecorder()
        let coordinator = TerminalPreviewLiveWebView.Coordinator(
            resource: resource,
            openExternalURL: { recorder.opened.append($0) }
        )
        let webView = WKWebView()
        let record: @MainActor @Sendable (WKNavigationActionPolicy) -> Void = {
            recorder.policies.append($0)
        }
        let externalLink = URL(string: "https://example.com/docs")!

        coordinator.webView(
            webView,
            decidePolicyFor: LiveWebNavigationActionStub(
                url: URL(string: "http://127.0.0.1:54321/next")!,
                type: .other
            ),
            decisionHandler: record
        )
        coordinator.webView(
            webView,
            decidePolicyFor: LiveWebNavigationActionStub(
                url: externalLink,
                type: .linkActivated
            ),
            decisionHandler: record
        )
        coordinator.webView(
            webView,
            decidePolicyFor: LiveWebNavigationActionStub(
                url: URL(string: "http://127.0.0.1:9999/other-port")!,
                type: .other
            ),
            decisionHandler: record
        )

        XCTAssertEqual(recorder.policies, [.allow, .cancel, .cancel])
        XCTAssertEqual(recorder.opened, [externalLink])
    }
}

@MainActor
private final class LiveWebPolicyRecorder {
    var policies: [WKNavigationActionPolicy] = []
    var opened: [URL] = []
}

private enum LiveWebRouteError: Error, Equatable {
    case file
    case html
}

private actor LiveWebCloseCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class LiveWebNavigationActionStub: WKNavigationAction {
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

@MainActor
private func waitUntilLiveWeb(
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
