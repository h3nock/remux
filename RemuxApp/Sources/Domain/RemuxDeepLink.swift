import Foundation

/// A `remux://` link that opens a tmux session on a saved server, and
/// optionally a window and pane inside it:
///
///     remux://open?server=<server>&session=<name>[&window=<window>][&pane=<pane>]
///
/// `server` is a saved server's display name, its `user@host[:port]`, its
/// host, or its id. `window` and `pane` use tmux's own target syntax (an
/// index, a window name, `@id` or `%id`), so tmux resolves them exactly as
/// `select-window -t` and `select-pane -t` would.
struct RemuxDeepLink: Equatable, Sendable {
    static let scheme = "remux"

    let server: String
    let sessionName: String
    let window: String?
    let pane: String?

    enum ParseError: Error, Equatable, LocalizedError {
        case unsupportedScheme
        case unsupportedAction(String)
        case missingServer
        case missingSession
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedScheme:
                "This is not a Remux link."
            case .unsupportedAction(let action):
                "Remux links cannot \"\(action)\"."
            case .missingServer:
                "The link does not name a server."
            case .missingSession:
                "The link does not name a tmux session."
            case .invalidValue(let name):
                "The link's \(name) contains characters tmux cannot target."
            }
        }
    }

    init(server: String, sessionName: String, window: String? = nil, pane: String? = nil) {
        self.server = server
        self.sessionName = sessionName
        self.window = window
        self.pane = pane
    }

    init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw ParseError.unsupportedScheme }

        let action = components.host?.lowercased() ?? ""
        guard action == "open" else { throw ParseError.unsupportedAction(action) }

        func value(_ name: String) throws -> String? {
            guard let raw = components.queryItems?.last(where: { $0.name == name })?.value,
                  !raw.isEmpty
            else { return nil }
            guard raw.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else {
                throw ParseError.invalidValue(name)
            }
            return raw
        }

        guard let server = try value("server") else { throw ParseError.missingServer }
        guard let sessionName = try value("session") else { throw ParseError.missingSession }
        self.init(
            server: server,
            sessionName: sessionName,
            window: try value("window"),
            pane: try value("pane")
        )
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "session", value: sessionName),
        ]
        if let window { components.queryItems?.append(URLQueryItem(name: "window", value: window)) }
        if let pane { components.queryItems?.append(URLQueryItem(name: "pane", value: pane)) }
        // URLComponents leaves `+` and `&`-free reserved characters alone;
        // percent-encode `+` so it is not read back as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    enum ServerResolutionError: Error, Equatable, LocalizedError {
        case notFound(String)
        case ambiguous(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let server):
                "No saved server matches \"\(server)\"."
            case .ambiguous(let server):
                "More than one saved server matches \"\(server)\". Link to it by name or id."
            }
        }
    }

    /// How a link should name `server`: its display name when no other saved
    /// server shares it, otherwise its id.
    static func serverReference(for server: SavedServer, among servers: [SavedServer]) -> String {
        let name = server.displayName.lowercased()
        let sharesName = servers.contains { $0.id != server.id && $0.displayName.lowercased() == name }
        return sharesName || server.displayName.isEmpty ? server.id.uuidString : server.displayName
    }

    /// A link to `sessionName` on `server`.
    static func sessionURL(server: SavedServer, sessionName: String, among servers: [SavedServer]) -> URL {
        RemuxDeepLink(
            server: serverReference(for: server, among: servers),
            sessionName: sessionName
        ).url
    }

    /// Finds the saved server the link names. Tries, in order, the server
    /// id, the display name, `user@host[:port]`, then the host alone, and
    /// takes the first rule that matches exactly one server.
    func resolveServer(in servers: [SavedServer]) throws -> SavedServer {
        let reference = server
        let folded = reference.lowercased()
        let rules: [(SavedServer) -> Bool] = [
            { $0.id.uuidString.lowercased() == folded },
            { $0.displayName.lowercased() == folded },
            { "\($0.username)@\($0.host)".lowercased() == folded },
            { "\($0.username)@\($0.host):\($0.port)".lowercased() == folded },
            { $0.host.lowercased() == folded },
        ]
        for rule in rules {
            let matches = servers.filter(rule)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw ServerResolutionError.ambiguous(reference) }
        }
        throw ServerResolutionError.notFound(reference)
    }

    /// The window and pane to select once the session is attached, or nil
    /// when the link names only the session.
    var paneTarget: TmuxTargetSelection? {
        guard window != nil || pane != nil else { return nil }
        return TmuxTargetSelection(sessionName: sessionName, window: window, pane: pane)
    }
}

/// A window and/or pane named in tmux target syntax, resolved by tmux after
/// attach.
struct TmuxTargetSelection: Equatable, Sendable {
    let sessionName: String
    let window: String?
    let pane: String?

    /// The `-t` argument for this selection. A `%id` pane is global, so it
    /// is used on its own and `window` is ignored; anything else is
    /// qualified by the exact session name (`=name`) so tmux does not
    /// prefix-match another session.
    var tmuxTarget: String {
        if let pane, pane.hasPrefix("%") { return pane }
        var target = "=\(sessionName):\(window ?? "")"
        if let pane { target += ".\(pane)" }
        return target
    }

    /// A tmux command that prints the window id, pane id and session name
    /// for `tmuxTarget`.
    var resolveCommand: String {
        "display-message -p -t \(Self.tmuxQuoted(tmuxTarget)) '#{window_id} #{pane_id} #{session_name}'"
    }

    /// Parses `resolveCommand`'s reply, `@<window> %<pane> <session>`, and
    /// accepts it only when the target is in this selection's session.
    func parseResolveReply(_ reply: String) -> (TmuxWindowID, TmuxPaneID)? {
        let fields = reply
            .trimmingCharacters(in: .newlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].hasPrefix("@"), let window = UInt64(fields[0].dropFirst()),
              fields[1].hasPrefix("%"), let pane = UInt64(fields[1].dropFirst()),
              fields[2] == sessionName
        else { return nil }
        return (TmuxWindowID(window), TmuxPaneID(pane))
    }

    /// Double-quotes a value for tmux's command parser, escaping the
    /// characters it expands inside double quotes.
    static func tmuxQuoted(_ value: String) -> String {
        var quoted = "\""
        for character in value {
            switch character {
            case "\\", "\"", "$": quoted.append("\\\(character)")
            default: quoted.append(character)
            }
        }
        quoted.append("\"")
        return quoted
    }
}
