import Foundation
import SwiftUI
import UIKit
import WebKit

/// Shared navigation policy for preview web views: in-preview URLs load
/// normally, deliberate link taps to external http(s) destinations open in
/// the system browser, everything else is cancelled.
struct TerminalPreviewWebLinkPolicy {
    let allowsNavigation: @MainActor (URL) -> Bool
    let openExternalURL: @MainActor (URL) -> Void

    @MainActor
    func decidePolicy(
        for navigationAction: WKNavigationAction
    ) -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, allowsNavigation(url) {
            return .allow
        }
        routeExternally(navigationAction)
        return .cancel
    }

    @MainActor
    func handleCreateWebView(
        _ webView: WKWebView,
        for navigationAction: WKNavigationAction
    ) {
        if let url = navigationAction.request.url, allowsNavigation(url) {
            webView.load(navigationAction.request)
        } else {
            routeExternally(navigationAction)
        }
    }

    // Only deliberate link taps may leave the preview; programmatic
    // redirects and auto-loading frames stay cancelled.
    @MainActor
    private func routeExternally(_ navigationAction: WKNavigationAction) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        openExternalURL(url)
    }
}

@MainActor
func reloadTerminalPreviewWebView(
    _ webView: WKWebView,
    ifRequested generation: UInt,
    lastGeneration: inout UInt,
    fallbackURL: URL
) {
    guard lastGeneration != generation else { return }
    lastGeneration = generation
    if webView.reloadFromOrigin() == nil {
        webView.load(URLRequest(url: webView.url ?? fallbackURL))
    }
}

enum TerminalPreviewLiveWebError: LocalizedError, Equatable, Sendable {
    case invalidLocalURL

    var errorDescription: String? {
        "The localhost preview address is invalid."
    }
}

final class TerminalPreviewLiveWebResource: @unchecked Sendable, Equatable {
    let localURL: URL
    let localPort: Int

    private let closeForward: @Sendable () async throws -> Void
    private let lock = NSLock()
    private var closed = false

    init(
        target: TerminalPreviewLocalhostTarget,
        localPort: Int,
        closeForward: @escaping @Sendable () async throws -> Void
    ) throws {
        let pathQuery = target.pathQuery.isEmpty ? "/" : target.pathQuery
        guard pathQuery.hasPrefix("/"),
              let localURL = URL(
                string: "\(target.scheme)://127.0.0.1:\(localPort)\(pathQuery)"
              )
        else { throw TerminalPreviewLiveWebError.invalidLocalURL }
        self.localURL = localURL
        self.localPort = localPort
        self.closeForward = closeForward
    }

    static func == (
        lhs: TerminalPreviewLiveWebResource,
        rhs: TerminalPreviewLiveWebResource
    ) -> Bool {
        lhs === rhs
    }

    func close() {
        let shouldClose: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        let closeForward = closeForward
        Task {
            do {
                try await closeForward()
            } catch {
                NSLog(
                    "Remux live web preview forward close failed: %@",
                    String(describing: error)
                )
            }
        }
    }

    deinit {
        close()
    }
}

struct TerminalPreviewLiveWebClient: Sendable {
    private let openHandler: @Sendable (
        TerminalPreviewLocalhostTarget
    ) async throws -> TerminalPreviewLiveWebResource

    init(
        open: @escaping @Sendable (
            TerminalPreviewLocalhostTarget
        ) async throws -> TerminalPreviewLiveWebResource
    ) {
        self.openHandler = open
    }

    init(provider: RemuxSessionLiveForwardProvider) {
        self.init { target in
            let handle = try await provider.openForward(
                to: try RemuxSSHDirectTCPIPTarget(
                    host: target.host,
                    port: target.port
                )
            )
            do {
                return try TerminalPreviewLiveWebResource(
                    target: target,
                    localPort: handle.localPort,
                    closeForward: handle.close
                )
            } catch {
                do {
                    try await handle.close()
                } catch {
                    NSLog(
                        "Remux live web failed-open forward close failed: %@",
                        String(describing: error)
                    )
                }
                throw error
            }
        }
    }

    func open(
        _ target: TerminalPreviewLocalhostTarget
    ) async throws -> TerminalPreviewLiveWebResource {
        try await openHandler(target)
    }
}

struct TerminalPreviewLiveWebView: UIViewRepresentable {
    let resource: TerminalPreviewLiveWebResource
    let reloadGeneration: UInt

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resource: resource,
            reloadGeneration: reloadGeneration
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = Self.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: resource.localURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        reloadTerminalPreviewWebView(
            webView,
            ifRequested: reloadGeneration,
            lastGeneration: &context.coordinator.reloadGeneration,
            fallbackURL: resource.localURL
        )
    }

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let policy: TerminalPreviewWebLinkPolicy
        fileprivate var reloadGeneration: UInt

        init(
            resource: TerminalPreviewLiveWebResource,
            reloadGeneration: UInt = 0,
            openExternalURL: @escaping @MainActor (URL) -> Void = {
                UIApplication.shared.open($0)
            }
        ) {
            let localPort = resource.localPort
            self.reloadGeneration = reloadGeneration
            self.policy = TerminalPreviewWebLinkPolicy(
                allowsNavigation: { url in
                    guard let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https"
                    else { return false }
                    return url.host == "127.0.0.1" && url.port == localPort
                },
                openExternalURL: openExternalURL
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationActionPolicy
            ) -> Void
        ) {
            decisionHandler(policy.decidePolicy(for: navigationAction))
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            policy.handleCreateWebView(webView, for: navigationAction)
            return nil
        }
    }
}
