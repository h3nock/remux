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
                return try await TerminalPreviewStaticHTMLResource.open(
                    remotePath: remotePath,
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

/// A previewed page is shown the way a desktop browser shows a local file: it renders and runs its scripts, and it
/// can use the scripts, styles and images in its folder, but it cannot read the bytes of other files, and nothing
/// outside its folder is served. Scripts and styles it loads do reveal what they define (a stylesheet's values, a
/// script's functions), as in a browser, and the page can still reach the internet. Having an origin of its own, it
/// has no storage, workers or frames.
final class TerminalPreviewStaticHTMLResource: @unchecked Sendable, Equatable {
    static let scheme = "remux-static-preview"

    let entryURL: URL
    private let resolver: TerminalPreviewStaticHTMLPathResolver
    private let transport: TerminalPreviewStaticHTMLTransport

    /// Opens the preview of the page at `remotePath`. The folder it may read is pinned as the server's real path of
    /// the selected page's folder (a page that is a symlink doesn't move it), and the page itself is checked like
    /// any file it loads; both lookups share one round trip.
    static func open(
        remotePath: String,
        readLease: TerminalPreviewStaticHTMLReadLease
    ) async throws -> TerminalPreviewStaticHTMLResource {
        let resolver = try TerminalPreviewStaticHTMLPathResolver(entryRemotePath: remotePath)
        async let folder = readLease.realPath(resolver.documentRoot)
        async let entry = readLease.lookUp(resolver.entryPath)
        guard let folderRealPath = TerminalPreviewRemotePath.normalized(try await folder) else {
            throw TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot
        }
        let entryFile = try TerminalPreviewStaticHTMLServedFile(
            lookup: try await entry,
            folderRealPath: folderRealPath
        )
        let maximumByteCount = TerminalPreviewFileLoader<RemuxSessionCitadelSFTPClientProvider>.defaultMaximumByteCount
        if let size = entryFile.metadata.size, size > maximumByteCount {
            throw TerminalPreviewFileError.tooLarge(maximumByteCount: maximumByteCount)
        }
        return TerminalPreviewStaticHTMLResource(
            resolver: resolver,
            folderRealPath: folderRealPath,
            entry: entryFile,
            readLease: readLease
        )
    }

    private init(
        resolver: TerminalPreviewStaticHTMLPathResolver,
        folderRealPath: String,
        entry: TerminalPreviewStaticHTMLServedFile,
        readLease: TerminalPreviewStaticHTMLReadLease
    ) {
        self.entryURL = resolver.entryURL
        self.resolver = resolver
        self.transport = TerminalPreviewStaticHTMLTransport(
            entryURL: resolver.entryURL,
            folderRealPath: folderRealPath,
            entry: entry,
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
    case resourceNotAFile

    var errorDescription: String? {
        switch self {
        case .invalidEntryPath:
            return "The HTML preview path is invalid."
        case .invalidResourceURL:
            return "The HTML preview requested an invalid resource."
        case .resourceOutsideDocumentRoot:
            return "The HTML preview cannot read outside its document folder."
        case .resourceNotAFile:
            return "The HTML preview can only open files."
        }
    }
}

/// Remote paths as the preview handles them: by their bytes, without asking anything of the phone's own files. A
/// server's file names are bytes, so two spellings Swift counts as one string (a composed é and an e followed by a
/// combining accent) can name different folders.
enum TerminalPreviewRemotePath {
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// `path` with empty and `.` components dropped and each `..` applied, or nil unless it is absolute and free of
    /// NUL, CR and LF. A `..` at the top stays at `/`.
    static func normalized(_ path: String) -> String? {
        let bytes = Array(path.utf8)
        guard bytes.first == slash,
              !bytes.contains(0),
              !bytes.contains(UInt8(ascii: "\n")),
              !bytes.contains(UInt8(ascii: "\r"))
        else { return nil }
        var components: [ArraySlice<UInt8>] = []
        for component in bytes.split(separator: slash) {
            if component.elementsEqual([dot]) { continue }
            if component.elementsEqual([dot, dot]) {
                _ = components.popLast()
                continue
            }
            components.append(component)
        }
        guard !components.isEmpty else { return "/" }
        var normalized: [UInt8] = []
        for component in components {
            normalized.append(slash)
            normalized.append(contentsOf: component)
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    /// Whether normalized `path` is normalized `folder` or inside it.
    static func isInside(_ path: String, folder: String) -> Bool {
        let path = Array(path.utf8)
        let folder = Array(folder.utf8)
        if folder == [slash] { return path.first == slash }
        guard path.starts(with: folder) else { return false }
        return path.count == folder.count || path[folder.count] == slash
    }

    /// The folder holding normalized `path`.
    static func parent(of path: String) -> String {
        let bytes = Array(path.utf8)
        guard let lastSlash = bytes.lastIndex(of: slash), lastSlash > 0 else { return "/" }
        return String(decoding: bytes[..<lastSlash], as: UTF8.self)
    }
}

/// What the server reported for a requested path: where it really is, and what it is.
struct TerminalPreviewStaticHTMLLookup: Sendable {
    let realPath: String
    let metadata: RemuxSFTPFileMetadata
}

/// A file the preview may serve: a regular file whose real path on the server is inside the preview's folder.
/// It is read through that real path, and typed by that path's name.
struct TerminalPreviewStaticHTMLServedFile: Sendable {
    let path: String
    let metadata: RemuxSFTPFileMetadata

    init(lookup: TerminalPreviewStaticHTMLLookup, folderRealPath: String) throws {
        guard let path = TerminalPreviewRemotePath.normalized(lookup.realPath),
              TerminalPreviewRemotePath.isInside(path, folder: folderRealPath)
        else { throw TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot }
        // Only what the server says is a regular file: opening a named pipe would hold the session, and a server
        // that sends no file type leaves nothing to go on.
        guard let mode = lookup.metadata.permissions, mode & 0o170000 == 0o100000 else {
            throw TerminalPreviewStaticHTMLError.resourceNotAFile
        }
        self.path = path
        self.metadata = lookup.metadata
    }
}

/// What each response tells WebKit: the file's type, and the rules that keep the page from reading the files beside
/// it (see `TerminalPreviewStaticHTMLResource`).
enum TerminalPreviewStaticHTMLResponse {
    /// `sandbox` gives the page an origin of its own, so it can show and run what its folder holds but not read
    /// it. The other directives close what WebKit leaves open under the sandbox alone, where a synchronous
    /// XMLHttpRequest still read a neighbouring file: no connections, frames, workers or plugins from the folder.
    /// The page may still load from and send to the internet.
    static let contentSecurityPolicy = "default-src 'self' https: http: data: blob: 'unsafe-inline' 'unsafe-eval'; "
        + "connect-src https: http: wss: ws:; frame-src 'none'; child-src 'none'; worker-src 'none'; "
        + "object-src 'none'; sandbox allow-scripts allow-popups allow-forms allow-modals"

    /// No Content-Length: the reader reads on past a size that changed after the lookup, which a declared length
    /// would cut off.
    static func make(url: URL, servedPath: String) -> HTTPURLResponse? {
        let type = contentType(forPath: servedPath)
        var headers = [
            "Content-Type": type.mimeType,
            "Content-Security-Policy": contentSecurityPolicy,
            // Scripts and styles load only when typed as such, so a data file next to the page (a .env of
            // NAME="value" lines) can't run as a script and give up its values.
            "X-Content-Type-Options": "nosniff",
        ]
        if type.isScript {
            // The sandboxed page loads module scripts across origins; only scripts, which run rather than read.
            headers["Access-Control-Allow-Origin"] = "*"
        }
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
    }

    /// The type a file is served as, by its name: web types explicitly, then the system's, then a type nothing runs.
    static func contentType(forPath path: String) -> (mimeType: String, isScript: Bool) {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "mjs", "cjs":
            return ("text/javascript", true)
        case "html", "htm":
            return ("text/html", false)
        case "xhtml":
            return ("application/xhtml+xml", false)
        case "css":
            return ("text/css", false)
        case "json", "map":
            return ("application/json", false)
        case "svg":
            return ("image/svg+xml", false)
        case "wasm":
            return ("application/wasm", false)
        case let pathExtension:
            let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType
            return (mimeType ?? "application/octet-stream", false)
        }
    }
}

/// Maps preview URLs to remote paths by their text alone. This is the first filter; the server's real path of
/// each file is what decides (see `TerminalPreviewStaticHTMLServedFile`).
struct TerminalPreviewStaticHTMLPathResolver: Equatable, Sendable {
    let entryURL: URL
    /// The selected page, normalized.
    let entryPath: String
    /// The selected page's folder, normalized.
    let documentRoot: String

    private let host: String

    init(entryRemotePath: String, identifier: UUID = UUID()) throws {
        guard let entryPath = TerminalPreviewRemotePath.normalized(entryRemotePath), entryPath != "/" else {
            throw TerminalPreviewStaticHTMLError.invalidEntryPath
        }
        let host = identifier.uuidString.lowercased()
        var components = URLComponents()
        components.scheme = TerminalPreviewStaticHTMLResource.scheme
        components.host = host
        components.path = entryPath
        guard let entryURL = components.url else {
            throw TerminalPreviewStaticHTMLError.invalidEntryPath
        }

        self.entryURL = entryURL
        self.entryPath = entryPath
        self.documentRoot = TerminalPreviewRemotePath.parent(of: entryPath)
        self.host = host
    }

    func remotePath(for url: URL) throws -> String {
        guard url.scheme == TerminalPreviewStaticHTMLResource.scheme,
              url.host == host,
              let path = TerminalPreviewRemotePath.normalized(url.path)
        else { throw TerminalPreviewStaticHTMLError.invalidResourceURL }

        guard TerminalPreviewRemotePath.isInside(path, folder: documentRoot) else {
            throw TerminalPreviewStaticHTMLError.resourceOutsideDocumentRoot
        }
        return path
    }
}

struct TerminalPreviewStaticHTMLReadLease: Sendable {
    typealias MetadataHandler = TerminalPreviewRemoteFileReader.MetadataHandler
    typealias ChunkHandler = TerminalPreviewRemoteFileReader.ChunkHandler

    private let realPathHandler: @Sendable (String) async throws -> String
    private let metadataHandler: @Sendable (String) async throws -> RemuxSFTPFileMetadata
    private let streamHandler: @Sendable (
        String,
        RemuxSFTPFileMetadata,
        @escaping MetadataHandler,
        @escaping ChunkHandler
    ) async throws -> Void
    private let closeHandler: @Sendable () async throws -> Void

    /// `stream` reads the file at a path already looked up, whose metadata it is given, calling `onMetadata`
    /// before the first chunk.
    init(
        realPath: @escaping @Sendable (String) async throws -> String,
        metadata: @escaping @Sendable (String) async throws -> RemuxSFTPFileMetadata,
        stream: @escaping @Sendable (
            String,
            RemuxSFTPFileMetadata,
            @escaping MetadataHandler,
            @escaping ChunkHandler
        ) async throws -> Void,
        close: @escaping @Sendable () async throws -> Void
    ) {
        self.realPathHandler = realPath
        self.metadataHandler = metadata
        self.streamHandler = stream
        self.closeHandler = close
    }

    init(lease: RemuxSFTPClientLease<RemuxCitadelSFTPClient>) {
        self.init(
            realPath: { try await lease.client.realPath(atPath: $0) },
            metadata: { try await lease.client.metadata(atPath: $0) },
            stream: { remotePath, metadata, onMetadata, onChunk in
                _ = try await TerminalPreviewRemoteFileReader.stream(
                    client: lease.client,
                    remotePath: remotePath,
                    maximumByteCount: TerminalPreviewFileLoader<
                        RemuxSessionCitadelSFTPClientProvider
                    >.defaultMaximumByteCount,
                    knownMetadata: metadata,
                    onMetadata: onMetadata,
                    onChunk: onChunk
                )
            },
            close: lease.close
        )
    }

    func realPath(_ remotePath: String) async throws -> String {
        try await realPathHandler(remotePath)
    }

    /// The server's real path and metadata for `remotePath`, asked together so they share a round trip. The
    /// metadata follows symlinks, as the real path does.
    func lookUp(_ remotePath: String) async throws -> TerminalPreviewStaticHTMLLookup {
        async let realPath = realPathHandler(remotePath)
        async let metadata = metadataHandler(remotePath)
        return TerminalPreviewStaticHTMLLookup(realPath: try await realPath, metadata: try await metadata)
    }

    func stream(
        _ file: TerminalPreviewStaticHTMLServedFile,
        onMetadata: @escaping MetadataHandler,
        onChunk: @escaping ChunkHandler
    ) async throws {
        try await streamHandler(file.path, file.metadata, onMetadata, onChunk)
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
    private let folderRealPath: String
    /// The page as checked when the preview opened, for its first request only; a reload looks it up again.
    private var entry: TerminalPreviewStaticHTMLServedFile?
    private let readLease: TerminalPreviewStaticHTMLReadLease
    private var operations: [ObjectIdentifier: Operation] = [:]
    private var closed = false

    init(
        entryURL: URL,
        folderRealPath: String,
        entry: TerminalPreviewStaticHTMLServedFile,
        readLease: TerminalPreviewStaticHTMLReadLease
    ) {
        self.entryURL = entryURL
        self.folderRealPath = folderRealPath
        self.entry = entry
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
        let folderRealPath = folderRealPath
        let checkedEntry: TerminalPreviewStaticHTMLServedFile?
        if url == entryURL {
            checkedEntry = entry
            entry = nil
        } else {
            checkedEntry = nil
        }
        let token = UUID()
        let task = Task {
            do {
                guard let url else {
                    throw TerminalPreviewStaticHTMLError.invalidResourceURL
                }
                let requestedPath = try resolver.remotePath(for: url)
                let file: TerminalPreviewStaticHTMLServedFile
                if let checkedEntry {
                    file = checkedEntry
                } else {
                    file = try TerminalPreviewStaticHTMLServedFile(
                        lookup: try await readLease.lookUp(requestedPath),
                        folderRealPath: folderRealPath
                    )
                }
                // Stopped or closed while the server answered: don't start reading.
                try Task.checkCancellation()
                guard !sink.isStopped else { return }
                try await readLease.stream(
                    file,
                    onMetadata: { _ in
                        try Task.checkCancellation()
                        try await sink.receiveResponse(for: url, servedPath: file.path)
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
    func receiveResponse(for url: URL, servedPath: String) throws {
        guard isActive else { return }
        guard let response = TerminalPreviewStaticHTMLResponse.make(url: url, servedPath: servedPath) else {
            throw TerminalPreviewStaticHTMLError.invalidResourceURL
        }
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
