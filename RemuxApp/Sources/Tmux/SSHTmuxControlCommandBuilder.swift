import Foundation

enum SSHTmuxRemotePlatform: Equatable, Sendable, CustomStringConvertible {
    case posix
    case windows

    var description: String {
        switch self {
        case .posix: "posix"
        case .windows: "windows"
        }
    }
}

enum SSHTmuxRemotePlatformDetectionError: Error, Equatable {
    case missingExitStatus
    case unexpectedSuccessfulOutput
}

enum SSHTmuxRemotePlatformDetector {
    static let windowsProbeCommand = "cmd.exe /d /c echo REMUX_WINDOWS_%OS%"
    private static let windowsMarker = "REMUX_WINDOWS_Windows_NT"

    static func platform(exitStatus: Int?, stdout: Data) throws -> SSHTmuxRemotePlatform {
        guard let exitStatus else {
            throw SSHTmuxRemotePlatformDetectionError.missingExitStatus
        }
        guard exitStatus == 0 else {
            return .posix
        }
        guard let output = String(data: stdout, encoding: .utf8),
              output.split(whereSeparator: \.isNewline).contains(Substring(windowsMarker))
        else {
            throw SSHTmuxRemotePlatformDetectionError.unexpectedSuccessfulOutput
        }
        return .windows
    }
}

enum SSHTmuxControlCommandBuilder {
    static let tmuxNotFoundMarker = "remux: tmux executable not found"
    static let tmuxNotExecutableMarker = "remux: tmux executable cannot be executed"

    private static let fallbackRemotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
        platform: SSHTmuxRemotePlatform = .posix,
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        switch platform {
        case .posix:
            posixAttachOrCreateControlSessionCommand(
                tmuxExecutable: tmuxExecutable,
                sessionName: sessionName,
                initialViewport: initialViewport
            )
        case .windows:
            windowsAttachOrCreateControlSessionCommand(
                tmuxExecutable: tmuxExecutable,
                sessionName: sessionName,
                initialViewport: initialViewport
            )
        }
    }

    private static func posixAttachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        // The SSH login shell only parses this wrapper. /bin/sh owns the PATH
        // expression so fish and csh do not need to understand POSIX syntax.
        [
            "exec /bin/sh -c '\(launchScript)' remux",
            octalEncodedArgument(tmuxExecutable),
            octalEncodedArgument(sessionName),
            "\(initialViewport.columns)",
            "\(initialViewport.rows)",
        ].joined(separator: " ")
    }

    private static func windowsAttachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        // Windows resolves a bare `tmux` executable as `tmux.exe`. Keep the
        // command behind cmd.exe so an OpenSSH server configured with
        // PowerShell does not try to interpret the POSIX launcher.
        let command = [
            windowsQuotedArgument(tmuxExecutable),
            "-u",
            "-CC",
            "new-session",
            "-A",
            "-s",
            windowsQuotedArgument(sessionName),
            "-x",
            "\(initialViewport.columns)",
            "-y",
            "\(initialViewport.rows)",
        ].joined(separator: " ")
        return "cmd.exe /d /s /c \"\(command)\""
    }

    private static let launchScript = [
        #"PATH="${PATH:+$PATH:}\#(fallbackRemotePath)""#,
        "export PATH",
        "TERM=xterm-256color",
        "export TERM",
        #"tmux=$(printf %b "$1")"#,
        #"session=$(printf %b "$2")"#,
        #"resolved=$(command -v "$tmux" 2> /dev/null)"#,
        #"if [ -x "$resolved" ]; then exec "$resolved" -u -C new-session -A -s "$session" -x "$3" -y "$4"; fi"#,
        #"if [ -e "$tmux" ]; then echo "\#(tmuxNotExecutableMarker): $tmux" >&2; exit 126; fi"#,
        #"echo "\#(tmuxNotFoundMarker): $tmux" >&2"#,
        "exit 127",
    ].joined(separator: "; ")

    private static func octalEncodedArgument(_ value: String) -> String {
        let bytes = value.utf8.map { byte in
            let digits = String(byte, radix: 8)
            return "\\0" + String(repeating: "0", count: 3 - digits.count) + digits
        }
        return "'\(bytes.joined())'"
    }

    private static func windowsQuotedArgument(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
