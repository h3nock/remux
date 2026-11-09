import Foundation
import WebKit
import XCTest
@testable import Remux

/// The HTML preview against a real OpenSSH server, whose real paths are what keep a symlink in the previewed folder
/// from serving a file outside it. Runs against the live host of the Herdr live tests (`REMUX_LIVE_HERDR_CONFIG`,
/// passed to `xcodebuild test` as `TEST_RUNNER_REMUX_LIVE_HERDR_CONFIG`) and skips without it.
final class TerminalPreviewStaticHTMLLiveTests: XCTestCase {
    @MainActor
    func testSymlinksOutOfThePreviewFolderAreRefusedAndOnesInsideItAreServed() async throws {
        let configuration = try HerdrLiveConfiguration.load()
        let trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalPreviewStaticHTMLLive-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: trustedHostRoot) }
        let host = LiveHost(configuration: configuration, trustedHostRoot: trustedHostRoot)
        let root = "/tmp/remux-html-\(UUID().uuidString.prefix(8).lowercased())"
        // Before the setup, so a setup that fails part way leaves nothing either.
        addTeardownBlock {
            do {
                try await host.run("rm -rf -- \"$(printf %b \"$1\")\"", arguments: [root])
            } catch {
                XCTFail("The live folder \(root) was not removed: \(error)")
            }
        }
        try await host.run(Self.setupScript, arguments: [root])

        // A page that is a symlink out of its folder is refused when the preview opens.
        let refusedLease = try await host.openSFTPLease()
        do {
            _ = try await TerminalPreviewStaticHTMLResource.open(
                remotePath: "\(root)/site/linked-page.html",
                readLease: TerminalPreviewStaticHTMLReadLease(lease: refusedLease)
            )
            XCTFail("A page that resolves outside its folder was opened")
        } catch {
            XCTAssertEqual(error as? TerminalPreviewStaticHTMLError, .resourceOutsideDocumentRoot, "\(error)")
        }
        try await refusedLease.close()

        let lease = try await host.openSFTPLease()
        let resource: TerminalPreviewStaticHTMLResource
        do {
            resource = try await TerminalPreviewStaticHTMLResource.open(
                remotePath: "\(root)/site/index.html",
                readLease: TerminalPreviewStaticHTMLReadLease(lease: lease)
            )
        } catch {
            try? await lease.close()
            XCTFail("The preview did not open: \(error)")
            return
        }
        defer { resource.close() }
        let handler = resource.makeSchemeHandler()

        for name in ["index.html", "inside.txt", "link-in.txt"] {
            let task = LiveSchemeTaskSpy(url: try XCTUnwrap(URL(string: name, relativeTo: resource.entryURL)))
            handler.webView(WKWebView(), start: task)
            try await waitUntil("\(name) was not served") { task.finished || !task.errors.isEmpty }
            XCTAssertTrue(task.errors.isEmpty, "\(name): \(task.errors)")
            if name != "index.html" {
                XCTAssertEqual(String(decoding: task.body, as: UTF8.self), "INSIDE", name)
            }
        }
        for (name, expected) in [
            ("link-out.txt", TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot),
            ("linked-dir/secret.txt", .resourceOutsideDocumentRoot),
            // A named pipe is refused before it is opened: opening one would hold the server's SFTP session.
            ("pipe", .resourceNotAFile),
        ] {
            let task = LiveSchemeTaskSpy(url: try XCTUnwrap(URL(string: name, relativeTo: resource.entryURL)))
            handler.webView(WKWebView(), start: task)
            try await waitUntil("\(name) was not refused") { task.finished || !task.errors.isEmpty }
            XCTAssertEqual(task.errors.first as? TerminalPreviewStaticHTMLError, expected, "\(name): \(task.errors)")
            XCTAssertFalse(task.receivedResponse, name)
            XCTAssertTrue(task.body.isEmpty, name)
        }
    }

    /// Arguments arrive octal-encoded (`RemoteShellArgument`); `printf %b` decodes them.
    private static let setupScript = """
    set -eu
    root=$(printf %b "$1")
    mkdir "$root"
    mkdir "$root/site" "$root/outside"
    printf '<!doctype html><title>page</title>' > "$root/site/index.html"
    printf 'INSIDE' > "$root/site/inside.txt"
    printf 'OUTSIDE-SECRET' > "$root/outside/secret.txt"
    printf '<!doctype html><title>outside</title>' > "$root/outside/page.html"
    ln -s inside.txt "$root/site/link-in.txt"
    ln -s ../outside/secret.txt "$root/site/link-out.txt"
    ln -s ../outside "$root/site/linked-dir"
    ln -s ../outside/page.html "$root/site/linked-page.html"
    mkfifo "$root/site/pipe"
    """
}

/// The live host: scripts run over a dedicated connection, and SFTP leases from a pool of its own.
private struct LiveHost: Sendable {
    let configuration: HerdrLiveConfiguration
    let trustedHostRoot: URL
    private let pool = RemuxSSHRootService()
    private let serverID = UUID()

    init(configuration: HerdrLiveConfiguration, trustedHostRoot: URL) {
        self.configuration = configuration
        self.trustedHostRoot = trustedHostRoot
    }

    func run(_ script: String, arguments: [String]) async throws {
        let trace = RemuxTransportStartupTrace(flowID: "html-preview-live-script")
        let command = (["exec /bin/sh -s --"] + arguments.map(RemoteShellArgument.octalEncoded)).joined(separator: " ")
        let result = try await RemuxSSHExecSession.run(
            using: try await configuration.claimDedicatedRoot(
                trustedHostRoot: trustedHostRoot,
                serverID: serverID,
                trace: trace
            ),
            command: command,
            stdin: Data(script.utf8),
            trace: trace
        )
        guard result.exitStatus == 0 else {
            throw HerdrLiveError(description: "The live script failed: \(String(decoding: result.stderr, as: UTF8.self))")
        }
    }

    func openSFTPLease() async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        let (server, rootConfiguration) = try configuration.signIn(trustedHostRoot: trustedHostRoot, serverID: serverID)
        let target = SessionTarget(
            server: server,
            workspace: SavedWorkspace(serverID: server.id, sessionName: "html-preview-live"),
            sshAuth: .password(
                username: server.username,
                password: "",
                identityID: server.identityID,
                displayLabel: server.displayName
            ),
            terminalSettings: .default
        )
        return try await RemuxCitadelSFTPClientProvider(
            sshRootService: pool,
            rootKey: RemuxSSHRootKey(target: target),
            rootConfiguration: rootConfiguration,
            operationTimeout: .seconds(15)
        ).openClientLease()
    }
}

private final class LiveSchemeTaskSpy: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest

    private let lock = NSLock()
    private var response: URLResponse?
    private var data = Data()
    private var didFinishLoading = false
    private var failures: [Error] = []

    init(url: URL) {
        self.request = URLRequest(url: url.absoluteURL)
    }

    var receivedResponse: Bool { lock.withLock { response != nil } }
    var body: Data { lock.withLock { data } }
    var finished: Bool { lock.withLock { didFinishLoading } }
    var errors: [Error] { lock.withLock { failures } }

    func didReceive(_ response: URLResponse) {
        lock.withLock { self.response = response }
    }

    func didReceive(_ data: Data) {
        lock.withLock { self.data.append(data) }
    }

    func didFinish() {
        lock.withLock { didFinishLoading = true }
    }

    func didFailWithError(_ error: Error) {
        lock.withLock { failures.append(error) }
    }
}

@MainActor
private func waitUntil(
    _ message: String,
    timeout: Duration = .seconds(20),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail(message)
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
