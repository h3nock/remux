import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

enum TerminalPreviewResource: Equatable, Sendable {
    case file(TerminalPreviewFileResource)
    case staticHTML(TerminalPreviewStaticHTMLResource)
    case liveWeb(TerminalPreviewLiveWebResource)

    var shareURL: URL? {
        guard case .file(let resource) = self else { return nil }
        return resource.url
    }

    func close() {
        switch self {
        case .file:
            break
        case .staticHTML(let resource):
            resource.close()
        case .liveWeb(let resource):
            resource.close()
        }
    }
}

struct TerminalPreviewClient: Sendable {
    private let fileClient: TerminalPreviewFileClient
    private let staticHTMLClient: TerminalPreviewStaticHTMLClient
    private let liveWebClient: TerminalPreviewLiveWebClient?

    init(
        provider: RemuxSessionCitadelSFTPClientProvider,
        liveForwardProvider: RemuxSessionLiveForwardProvider?
    ) {
        self.fileClient = TerminalPreviewFileClient(provider: provider)
        self.staticHTMLClient = TerminalPreviewStaticHTMLClient(provider: provider)
        self.liveWebClient = liveForwardProvider.map {
            TerminalPreviewLiveWebClient(provider: $0)
        }
    }

    init(
        loadFile: @escaping @Sendable (String) async throws -> TerminalPreviewFileResource,
        openStaticHTML: @escaping @Sendable (String) async throws -> TerminalPreviewStaticHTMLResource,
        openLiveWeb: (@Sendable (
            TerminalPreviewLocalhostTarget
        ) async throws -> TerminalPreviewLiveWebResource)? = nil
    ) {
        self.fileClient = TerminalPreviewFileClient(load: loadFile)
        self.staticHTMLClient = TerminalPreviewStaticHTMLClient(open: openStaticHTML)
        self.liveWebClient = openLiveWeb.map { TerminalPreviewLiveWebClient(open: $0) }
    }

    func load(remotePath: String) async throws -> TerminalPreviewResource {
        switch URL(fileURLWithPath: remotePath).pathExtension.lowercased() {
        case "htm", "html", "xhtml":
            return .staticHTML(try await staticHTMLClient.open(remotePath: remotePath))
        default:
            return .file(try await fileClient.load(remotePath: remotePath))
        }
    }

    func openLiveWeb(
        _ target: TerminalPreviewLocalhostTarget
    ) async throws -> TerminalPreviewResource {
        guard let liveWebClient else {
            throw RemuxSFTPClientError.sessionUnavailable
        }
        return .liveWeb(try await liveWebClient.open(target))
    }
}

struct TerminalPreviewStaticHTMLClient: Sendable {
    private let openHandler: @Sendable (String) async throws -> TerminalPreviewStaticHTMLResource

    init(
        open: @escaping @Sendable (String) async throws -> TerminalPreviewStaticHTMLResource
    ) {
        self.openHandler = open
    }

    init(provider: RemuxSessionCitadelSFTPClientProvider) {
        self.init { remotePath in
            let lease = try await provider.openClientLease()
            do {
                let metadata = try await lease.client.metadata(atPath: remotePath)
                if let size = metadata.size,
                   size > TerminalPreviewFileLoader<RemuxSessionCitadelSFTPClientProvider>
                    .defaultMaximumByteCount {
                    throw TerminalPreviewFileError.tooLarge(
                        maximumByteCount: TerminalPreviewFileLoader<
                            RemuxSessionCitadelSFTPClientProvider
                        >.defaultMaximumByteCount
                    )
                }
                return try TerminalPreviewStaticHTMLResource(
                    remotePath: remotePath,
                    entryMetadata: metadata,
                    readLease: TerminalPreviewStaticHTMLReadLease(lease: lease)
                )
            } catch {
                do {
                    try await lease.close()
                } catch {
                    NSLog(
                        "Remux static HTML failed-open close failed: %@",
                        String(describing: error)
                    )
                }
                throw error
            }
        }
    }

    func open(remotePath: String) async throws -> TerminalPreviewStaticHTMLResource {
        try await openHandler(remotePath)
    }
}

final class TerminalPreviewStaticHTMLResource: @unchecked Sendable, Equatable {
    static let scheme = "remux-static-preview"

    let entryURL: URL
    private let resolver: TerminalPreviewStaticHTMLPathResolver
    private let transport: TerminalPreviewStaticHTMLTransport

    init(
        remotePath: String,
        entryMetadata: RemuxSFTPFileMetadata,
        readLease: TerminalPreviewStaticHTMLReadLease
    ) throws {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(
            entryRemotePath: remotePath
        )
        self.entryURL = resolver.entryURL
        self.resolver = resolver
        self.transport = TerminalPreviewStaticHTMLTransport(
            entryURL: resolver.entryURL,
            entryMetadata: entryMetadata,
            readLease: readLease
        )
    }

    static func == (
        lhs: TerminalPreviewStaticHTMLResource,
        rhs: TerminalPreviewStaticHTMLResource
    ) -> Bool {
        lhs === rhs
    }

    func close() {
        let transport = self.transport
        Task { await transport.close() }
    }

    @MainActor
    func makeSchemeHandler() -> TerminalPreviewStaticHTMLSchemeHandler {
        TerminalPreviewStaticHTMLSchemeHandler(
            resolver: resolver,
            transport: transport
        )
    }

    deinit {
        let transport = self.transport
        Task { await transport.close() }
    }
}

enum TerminalPreviewStaticHTMLError: LocalizedError, Equatable, Sendable {
    case invalidEntryPath
    case invalidResourceURL
    case resourceOutsideDocumentRoot

    var errorDescription: String? {
        switch self {
        case .invalidEntryPath:
            return "The HTML preview path is invalid."
        case .invalidResourceURL:
            return "The HTML preview requested an invalid resource."
        case .resourceOutsideDocumentRoot:
            return "The HTML preview cannot read outside its document folder."
        }
    }
}

struct TerminalPreviewStaticHTMLPathResolver: Equatable, Sendable {
    let entryURL: URL

    private let host: String
    private let documentRoot: String

    init(entryRemotePath: String, identifier: UUID = UUID()) throws {
        guard entryRemotePath.hasPrefix("/"),
              !entryRemotePath.contains("\0"),
              !entryRemotePath.contains("\n"),
              !entryRemotePath.contains("\r")
        else { throw TerminalPreviewStaticHTMLError.invalidEntryPath }

        let standardizedPath = (entryRemotePath as NSString).standardizingPath
        guard standardizedPath.hasPrefix("/") else {
            throw TerminalPreviewStaticHTMLError.invalidEntryPath
        }
        let documentRoot = (standardizedPath as NSString).deletingLastPathComponent
        let host = identifier.uuidString.lowercased()
        var components = URLComponents()
        components.scheme = TerminalPreviewStaticHTMLResource.scheme
        components.host = host
        components.path = standardizedPath
        guard let entryURL = components.url else {
            throw TerminalPreviewStaticHTMLError.invalidEntryPath
        }

        self.entryURL = entryURL
        self.host = host
        self.documentRoot = documentRoot.isEmpty ? "/" : documentRoot
    }

    func remotePath(for url: URL) throws -> String {
        guard url.scheme == TerminalPreviewStaticHTMLResource.scheme,
              url.host == host,
              !url.path.contains("\0"),
              !url.path.contains("\n"),
              !url.path.contains("\r")
        else { throw TerminalPreviewStaticHTMLError.invalidResourceURL }

        let path = (url.path as NSString).standardizingPath
        let isInsideRoot = documentRoot == "/"
            ? path.hasPrefix("/")
            : path == documentRoot || path.hasPrefix(documentRoot + "/")
        guard isInsideRoot else {
            throw TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot
        }
        return path
    }
}

struct TerminalPreviewStaticHTMLReadLease: Sendable {
    typealias MetadataHandler = TerminalPreviewRemoteFileReader.MetadataHandler
    typealias ChunkHandler = TerminalPreviewRemoteFileReader.ChunkHandler

    private let streamHandler: @Sendable (
        String,
        RemuxSFTPFileMetadata?,
        @escaping MetadataHandler,
        @escaping ChunkHandler
    ) async throws -> Void
    private let closeHandler: @Sendable () async throws -> Void

    init(
        stream: @escaping @Sendable (
            String,
            RemuxSFTPFileMetadata?,
            @escaping MetadataHandler,
            @escaping ChunkHandler
        ) async throws -> Void,
        close: @escaping @Sendable () async throws -> Void
    ) {
        self.streamHandler = stream
        self.closeHandler = close
    }

    init(lease: RemuxSFTPClientLease<RemuxCitadelSFTPClient>) {
        self.init(
            stream: { remotePath, knownMetadata, onMetadata, onChunk in
                _ = try await TerminalPreviewRemoteFileReader.stream(
                    client: lease.client,
                    remotePath: remotePath,
                    maximumByteCount: TerminalPreviewFileLoader<
                        RemuxSessionCitadelSFTPClientProvider
                    >.defaultMaximumByteCount,
                    knownMetadata: knownMetadata,
                    onMetadata: onMetadata,
                    onChunk: onChunk
                )
            },
            close: lease.close
        )
    }

    func stream(
        remotePath: String,
        knownMetadata: RemuxSFTPFileMetadata?,
        onMetadata: @escaping MetadataHandler,
        onChunk: @escaping ChunkHandler
    ) async throws {
        try await streamHandler(remotePath, knownMetadata, onMetadata, onChunk)
    }

    func close() async throws {
        try await closeHandler()
    }
}

final class TerminalPreviewStaticHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    private struct WeakSink {
        weak var sink: TerminalPreviewStaticHTMLSchemeTaskSink?
    }

    private let transport: TerminalPreviewStaticHTMLTransport
    private let resolver: TerminalPreviewStaticHTMLPathResolver
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: WeakSink] = [:]

    fileprivate init(
        resolver: TerminalPreviewStaticHTMLPathResolver,
        transport: TerminalPreviewStaticHTMLTransport
    ) {
        self.resolver = resolver
        self.transport = transport
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let sink = TerminalPreviewStaticHTMLSchemeTaskSink(task: urlSchemeTask)
        let identifier = ObjectIdentifier(urlSchemeTask)
        register(sink, for: identifier)
        let resolver = resolver
        let url = urlSchemeTask.request.url
        Task {
            await transport.start(
                identifier: identifier,
                url: url,
                resolver: resolver,
                sink: sink
            )
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // WebKit forbids task callbacks once this delegate returns, so the
        // sink must be silenced synchronously, before any actor hop.
        let identifier = ObjectIdentifier(urlSchemeTask)
        removeSink(for: identifier)?.stop()
        Task { await transport.stop(identifier: identifier) }
    }

    private func register(
        _ sink: TerminalPreviewStaticHTMLSchemeTaskSink,
        for identifier: ObjectIdentifier
    ) {
        lock.withLock {
            sinks = sinks.filter { $0.value.sink != nil }
            sinks[identifier] = WeakSink(sink: sink)
        }
    }

    private func removeSink(
        for identifier: ObjectIdentifier
    ) -> TerminalPreviewStaticHTMLSchemeTaskSink? {
        lock.withLock {
            sinks.removeValue(forKey: identifier)?.sink
        }
    }
}

private actor TerminalPreviewStaticHTMLTransport {
    private struct Operation {
        let token: UUID
        let task: Task<Void, Never>
        let sink: TerminalPreviewStaticHTMLSchemeTaskSink
    }

    private let entryURL: URL
    private var entryMetadata: RemuxSFTPFileMetadata?
    private let readLease: TerminalPreviewStaticHTMLReadLease
    private var operations: [ObjectIdentifier: Operation] = [:]
    private var closed = false

    init(
        entryURL: URL,
        entryMetadata: RemuxSFTPFileMetadata,
        readLease: TerminalPreviewStaticHTMLReadLease
    ) {
        self.entryURL = entryURL
        self.entryMetadata = entryMetadata
        self.readLease = readLease
    }

    func start(
        identifier: ObjectIdentifier,
        url: URL?,
        resolver: TerminalPreviewStaticHTMLPathResolver,
        sink: TerminalPreviewStaticHTMLSchemeTaskSink
    ) async {
        guard !closed else {
            await sink.fail(CancellationError())
            return
        }
        guard !sink.isStopped else { return }
        let readLease = readLease
        let knownMetadata: RemuxSFTPFileMetadata?
        if url == entryURL {
            knownMetadata = entryMetadata
            entryMetadata = nil
        } else {
            knownMetadata = nil
        }
        let token = UUID()
        let task = Task {
            do {
                guard let url else {
                    throw TerminalPreviewStaticHTMLError.invalidResourceURL
                }
                let remotePath = try resolver.remotePath(for: url)
                try await readLease.stream(
                    remotePath: remotePath,
                    knownMetadata: knownMetadata,
                    onMetadata: { metadata in
                        try Task.checkCancellation()
                        await sink.receiveResponse(
                            for: url,
                            remotePath: remotePath,
                            metadata: metadata
                        )
                    },
                    onChunk: { data in
                        try Task.checkCancellation()
                        await sink.receive(data)
                    }
                )
                try Task.checkCancellation()
                await sink.finish()
            } catch is CancellationError {
                sink.stop()
            } catch {
                await sink.fail(error)
            }
        }
        operations[identifier] = Operation(token: token, task: task, sink: sink)
        Task { [weak self] in
            await task.value
            await self?.finish(identifier: identifier, token: token)
        }
    }

    func stop(identifier: ObjectIdentifier) {
        guard let operation = operations.removeValue(forKey: identifier) else { return }
        operation.sink.stop()
        operation.task.cancel()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let active = Array(operations.values)
        operations.removeAll()
        for operation in active {
            operation.sink.stop()
            operation.task.cancel()
        }
        for operation in active {
            await operation.task.value
        }
        do {
            try await readLease.close()
        } catch {
            NSLog(
                "Remux static HTML SFTP close failed: %@",
                String(describing: error)
            )
        }
    }

    private func finish(identifier: ObjectIdentifier, token: UUID) {
        guard operations[identifier]?.token == token else { return }
        operations.removeValue(forKey: identifier)
    }
}

private final class TerminalPreviewStaticHTMLSchemeTaskSink: @unchecked Sendable {
    private let lock = NSLock()
    private let task: any WKURLSchemeTask
    private var stopped = false

    init(task: any WKURLSchemeTask) {
        self.task = task
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    @MainActor
    func receiveResponse(
        for url: URL,
        remotePath: String,
        metadata: RemuxSFTPFileMetadata
    ) {
        guard isActive else { return }
        let type = UTType(filenameExtension: (remotePath as NSString).pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            expectedContentLength: metadata.size.map { Int(clamping: $0) } ?? -1,
            textEncodingName: nil
        )
        task.didReceive(response)
    }

    @MainActor
    func receive(_ data: Data) {
        guard isActive else { return }
        task.didReceive(data)
    }

    @MainActor
    func finish() {
        guard isActive else { return }
        task.didFinish()
        stop()
    }

    @MainActor
    func fail(_ error: Error) {
        guard isActive else { return }
        task.didFailWithError(error)
        stop()
    }

    private var isActive: Bool {
        lock.withLock { !stopped }
    }

}

struct TerminalPreviewStaticHTMLView: UIViewRepresentable {
    let resource: TerminalPreviewStaticHTMLResource
    let reloadGeneration: UInt

    func makeCoordinator() -> Coordinator {
        Coordinator(
            resource: resource,
            reloadGeneration: reloadGeneration
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = Self.makeWebView(
            schemeHandler: context.coordinator.schemeHandler
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: resource.entryURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        reloadTerminalPreviewWebView(
            webView,
            ifRequested: reloadGeneration,
            lastGeneration: &context.coordinator.reloadGeneration,
            fallbackURL: resource.entryURL
        )
    }

    static func makeWebView(
        schemeHandler: TerminalPreviewStaticHTMLSchemeHandler
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: TerminalPreviewStaticHTMLResource.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let schemeHandler: TerminalPreviewStaticHTMLSchemeHandler
        private let policy: TerminalPreviewWebLinkPolicy
        fileprivate var reloadGeneration: UInt

        init(
            resource: TerminalPreviewStaticHTMLResource,
            reloadGeneration: UInt = 0,
            openExternalURL: @escaping @MainActor (URL) -> Void = {
                UIApplication.shared.open($0)
            }
        ) {
            self.schemeHandler = resource.makeSchemeHandler()
            self.reloadGeneration = reloadGeneration
            self.policy = TerminalPreviewWebLinkPolicy(
                allowsNavigation: { url in
                    url.scheme == TerminalPreviewStaticHTMLResource.scheme
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
