import Foundation

enum TmuxSessionDiscoveryError: Error, Equatable, LocalizedError {
    case invalidUTF8
    case remoteExit(status: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "The tmux session list was not valid UTF-8."
        case .remoteExit(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "tmux exited with status \(status)."
                : detail
        }
    }
}

enum TmuxSessionDiscovery {
    static func discover(
        using claimedRoot: RemuxSSHClaimedRoot,
        tmuxExecutable: String,
        trace: RemuxTransportStartupTrace
    ) async throws -> [String] {
        let result = try await RemuxSSHExecSession.run(
            using: claimedRoot,
            command: SSHTmuxControlCommandBuilder.listSessionsCommand(
                tmuxExecutable: tmuxExecutable
            ),
            stdin: nil,
            trace: trace
        )
        return try sessionNames(from: result)
    }

    static func sessionNames(from result: RemuxSSHExecResult) throws -> [String] {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        guard result.exitStatus == 0 else {
            if isMissingTmuxServer(exitStatus: result.exitStatus, stderr: stderr) {
                return []
            }
            throw TmuxSessionDiscoveryError.remoteExit(
                status: result.exitStatus,
                stderr: stderr
            )
        }
        return try parseSessionNames(result.stdout)
    }

    static func parseSessionNames(_ output: Data) throws -> [String] {
        guard let text = String(data: output, encoding: .utf8) else {
            throw TmuxSessionDiscoveryError.invalidUTF8
        }

        var names: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let name = String(rawLine)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    private static func isMissingTmuxServer(exitStatus: Int, stderr: String) -> Bool {
        guard exitStatus == 1 else { return false }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.hasPrefix("no server running on ")
            || (
                message.hasPrefix("error connecting to ")
                    && message.hasSuffix("(No such file or directory)")
            )
    }
}
