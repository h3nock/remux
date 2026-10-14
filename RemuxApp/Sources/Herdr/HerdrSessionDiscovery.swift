import Foundation

struct HerdrDiscoveredSession: Equatable, Sendable {
    let name: String
    /// Stopped sessions are listed too; opening one starts it.
    let isRunning: Bool
}

struct HerdrVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// The oldest Herdr whose endpoint and CLI Remux supports.
    static let minimumSupported = HerdrVersion(major: 0, minor: 9, patch: 3)

    /// Parses the first `X.Y.Z` in `herdr --version` output, e.g. "herdr 0.9.3".
    init?(versionOutput: String) {
        guard let match = versionOutput.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1),
              let minor = Int(match.2),
              let patch = Int(match.3)
        else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: HerdrVersion, rhs: HerdrVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }
}

enum HerdrSessionDiscoveryError: Error, Equatable, LocalizedError {
    case unsupportedVersion(HerdrVersion)
    case unreadableVersion(String)
    /// The command ended before the ready marker, so nothing it printed can be told apart from the
    /// server's startup files.
    case incompleteOutput
    case invalidSessionList
    case invalidUTF8
    case remoteExit(status: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Herdr \(version) is older than \(HerdrVersion.minimumSupported). Update Herdr on this server."
        case .unreadableVersion(let output):
            return "Couldn't read the Herdr version from \"\(output)\"."
        case .incompleteOutput:
            return "The Herdr command on this server ended before its output."
        case .invalidSessionList:
            return "The Herdr session list couldn't be read."
        case .invalidUTF8:
            return "The Herdr session list was not valid UTF-8."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "herdr exited with status \(status)."
                : detail
        }
    }
}

enum HerdrSessionDiscovery {
    static func discover(
        using claimedRoot: RemuxSSHClaimedRoot,
        herdrExecutable: String,
        trace: RemuxTransportStartupTrace
    ) async throws -> [HerdrDiscoveredSession] {
        let result = try await RemuxSSHExecSession.run(
            using: claimedRoot,
            command: listSessionsCommand(herdrExecutable: herdrExecutable),
            stdin: nil,
            trace: trace
        )
        return try sessions(from: result)
    }

    /// One exec prints the first line of `herdr --version`, then the
    /// `session list --json` document (`HerdrRemoteCommand`).
    static func listSessionsCommand(herdrExecutable: String) -> String {
        HerdrRemoteCommand.command(herdrExecutable: herdrExecutable, body: [
            "LC_ALL=C",
            "export LC_ALL",
            #"version=$("$resolved" --version) || exit $?"#,
            #"printf "%s\n" "$version" | head -n 1"#,
            #"exec "$resolved" session list --json"#,
        ])
    }

    /// A server without Herdr has no Herdr sessions. A Herdr that fails, or is
    /// older than the supported minimum, is an error.
    static func sessions(from result: RemuxSSHExecResult) throws -> [HerdrDiscoveredSession] {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        guard result.exitStatus == 0 else {
            if result.exitStatus == 127, stderr.contains(HerdrRemoteCommand.notFoundMarker) {
                return []
            }
            throw HerdrSessionDiscoveryError.remoteExit(status: result.exitStatus, stderr: stderr)
        }
        var readyLine = HerdrRemoteCommand.ReadyLine()
        let output = readyLine.output(from: result.stdout)
        guard readyLine.isFound else { throw HerdrSessionDiscoveryError.incompleteOutput }
        guard let text = String(data: Data(output), encoding: .utf8) else {
            throw HerdrSessionDiscoveryError.invalidUTF8
        }

        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let versionLine = parts.first.map(String.init) ?? ""
        guard let version = HerdrVersion(versionOutput: versionLine) else {
            throw HerdrSessionDiscoveryError.unreadableVersion(versionLine)
        }
        guard version >= .minimumSupported else {
            throw HerdrSessionDiscoveryError.unsupportedVersion(version)
        }
        guard parts.count == 2,
              let list = try? JSONDecoder().decode(SessionList.self, from: Data(parts[1].utf8))
        else {
            throw HerdrSessionDiscoveryError.invalidSessionList
        }
        return list.sessions.map {
            HerdrDiscoveredSession(name: $0.name, isRunning: $0.running)
        }
    }

    private struct SessionList: Decodable {
        struct Session: Decodable {
            let name: String
            let running: Bool
        }

        let sessions: [Session]
    }

}
