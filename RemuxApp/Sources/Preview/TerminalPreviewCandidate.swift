import Foundation

enum TerminalPreviewPath: Equatable, Sendable {
    case absolute(String)
    case relative(String)

    var value: String {
        switch self {
        case .absolute(let value), .relative(let value): value
        }
    }

    func resolved(relativeTo currentDirectory: String) throws -> String {
        switch self {
        case .absolute(let path):
            return path
        case .relative(let path):
            guard currentDirectory.hasPrefix("/"),
                  !currentDirectory.contains("\0"),
                  !currentDirectory.contains("\n"),
                  !currentDirectory.contains("\r")
            else { throw TerminalPreviewPathError.invalidCurrentDirectory }

            let resolved = ((currentDirectory as NSString)
                .appendingPathComponent(path) as NSString)
                .standardizingPath
            guard resolved.hasPrefix("/") else {
                throw TerminalPreviewPathError.invalidCurrentDirectory
            }
            return resolved
        }
    }
}

enum TerminalPreviewPathError: LocalizedError, Equatable, Sendable {
    case invalidCurrentDirectory

    var errorDescription: String? {
        "The terminal's current directory is unavailable."
    }
}

struct TerminalPreviewLocalhostTarget: Equatable, Sendable {
    /// Host the remote server listens on, resolved on the remote machine.
    let host: String
    let port: Int
    let scheme: String
    let pathQuery: String

    var displayName: String {
        "localhost:\(port)"
    }
}

struct TerminalPreviewCandidate: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case file(TerminalPreviewPath)
        case localhost(TerminalPreviewLocalhostTarget)
    }

    let target: Target

    var path: TerminalPreviewPath? {
        guard case .file(let path) = target else { return nil }
        return path
    }

    var remotePath: String? { path?.value }

    var localhostTarget: TerminalPreviewLocalhostTarget? {
        guard case .localhost(let target) = target else { return nil }
        return target
    }

    init?(
        selection: String,
        explicitTarget: String? = nil
    ) {
        let value = (explicitTarget ?? selection).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r")
        else { return nil }

        if let localhost = Self.localhostTarget(from: value) {
            self.target = .localhost(localhost)
            return
        }

        let path: TerminalPreviewPath
        if value.hasPrefix("file:") {
            guard let url = URL(string: value),
                  url.isFileURL,
                  url.host == nil || url.host?.isEmpty == true,
                  url.path.hasPrefix("/")
            else { return nil }
            path = .absolute(url.path)
        } else if value.hasPrefix("/") {
            path = .absolute(value)
        } else {
            guard !value.hasPrefix("~"),
                  value != ".",
                  value != "..",
                  URL(string: value)?.scheme == nil,
                  value.contains("/") || !(value as NSString).pathExtension.isEmpty
            else { return nil }
            path = .relative(value)
        }

        self.target = .file(path)
    }

    var filename: String {
        switch target {
        case .file(let path):
            let component = URL(fileURLWithPath: path.value).lastPathComponent
            return component.isEmpty ? path.value : component
        case .localhost(let target):
            return target.displayName
        }
    }

    private static func localhostTarget(
        from value: String
    ) -> TerminalPreviewLocalhostTarget? {
        if let scheme = URL(string: value)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            guard let components = URLComponents(string: value),
                  let host = components.host?.lowercased(),
                  let connectHost = loopbackConnectHost(host)
            else { return nil }
            let port = components.port ?? (scheme == "https" ? 443 : 80)
            guard (1...Int(UInt16.max)).contains(port) else { return nil }
            var pathQuery = components.percentEncodedPath
            if let query = components.percentEncodedQuery {
                pathQuery += "?\(query)"
            }
            return TerminalPreviewLocalhostTarget(
                host: connectHost,
                port: port,
                scheme: scheme,
                pathQuery: pathQuery
            )
        }

        // Bare "localhost:3000" / "127.0.0.1:8000/path" server-log forms.
        let head = value.prefix { $0 != "/" }
        let pathQuery = String(value.dropFirst(head.count))
        let hostPort = head.split(separator: ":", omittingEmptySubsequences: false)
        guard hostPort.count == 2,
              let connectHost = loopbackConnectHost(String(hostPort[0]).lowercased()),
              let port = Int(hostPort[1]),
              (1...Int(UInt16.max)).contains(port)
        else { return nil }
        return TerminalPreviewLocalhostTarget(
            host: connectHost,
            port: port,
            scheme: "http",
            pathQuery: pathQuery
        )
    }

    private static func loopbackConnectHost(_ rawHost: String) -> String? {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // A fully qualified "localhost." names the same loopback host.
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" { return host }
        if host == "0.0.0.0" { return "127.0.0.1" }
        if host.hasPrefix("127."), host.split(separator: ".").count == 4 {
            return host
        }
        return nil
    }
}

/// A web link the terminal printed, which opens in the system browser rather
/// than in a preview. Loopback URLs stay previews: only the server reaches them.
enum TerminalExternalLink {
    static func url(selection: String, explicitTarget: String? = nil) -> URL? {
        let value = (explicitTarget ?? selection).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r"),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              TerminalPreviewCandidate(selection: value) == nil
        else { return nil }
        return url
    }
}

struct TerminalPreviewSelectionContext: Equatable {
    private var automaticVisibleText: String?
    private var automaticExplicitTarget: String?

    mutating func setAutomaticSelection(
        visibleText: String?,
        explicitTarget: String?
    ) {
        automaticVisibleText = visibleText
        automaticExplicitTarget = explicitTarget
    }

    mutating func selectionDidChange() {
        automaticVisibleText = nil
        automaticExplicitTarget = nil
    }

    func candidate(for selection: String) -> TerminalPreviewCandidate? {
        TerminalPreviewCandidate(
            selection: selection,
            explicitTarget: explicitTarget(for: selection)
        )
    }

    func externalLink(for selection: String) -> URL? {
        TerminalExternalLink.url(
            selection: selection,
            explicitTarget: explicitTarget(for: selection)
        )
    }

    /// Match the renderer's visible label, even when authoritative selection text joins wrapped rows.
    func explicitTarget(for selection: String) -> String? {
        automaticVisibleText == selection ? automaticExplicitTarget : nil
    }
}
