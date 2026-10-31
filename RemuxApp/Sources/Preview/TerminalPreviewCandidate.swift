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
    /// The URL as printed, retaining its encoded path, query and fragment.
    let url: URL
    /// The SSH forwarding destination, resolved on the remote machine.
    let host: String
    let port: Int

    init?(selection value: String) {
        var components = URLComponents(string: value)
        let scheme = components?.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            // Existing bare host:port forms use the same URL parser for their suffix.
            let authority = value.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            let hostPort = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard hostPort.count == 2, Self.connectHost(for: String(hostPort[0])) != nil else { return nil }
            components = URLComponents(string: "http://" + value)
        }
        guard var components,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = components.host, let host = Self.connectHost(for: rawHost)
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...Int(UInt16.max)).contains(port) else { return nil }
        components.scheme = scheme
        guard let url = components.url else { return nil }
        self.url = url
        self.host = host
        self.port = port
    }

    var displayName: String {
        "localhost:\(port)"
    }

    /// Host classification is independent of whether a Preview URL can be constructed.
    static func connectHost(for rawHost: String) -> String? {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" { return host }
        if host == "0.0.0.0" { return "127.0.0.1" }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127",
              octets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) && UInt8($0) != nil })
        else { return nil }
        return host
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

        if let localhost = TerminalPreviewLocalhostTarget(selection: value) {
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
              let host = url.host, !host.isEmpty,
              TerminalPreviewLocalhostTarget.connectHost(for: host) == nil,
              url.port.map({ (1...Int(UInt16.max)).contains($0) }) != false
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
