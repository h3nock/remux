enum SSHTmuxControlCommandBuilder {
    static let tmuxNotFoundMarker = "remux: tmux executable not found"
    static let tmuxNotExecutableMarker = "remux: tmux executable cannot be executed"

    private static let fallbackRemotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
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

    static func listSessionsCommand(tmuxExecutable: String) -> String {
        // Discovery runs through an ordinary SSH exec channel, never the
        // control-mode channel. Keep the configured executable out of the
        // login shell just as the attach command does.
        [
            "exec /bin/sh -c '\(discoveryScript)' remux",
            octalEncodedArgument(tmuxExecutable),
        ].joined(separator: " ")
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

    private static let discoveryScript = [
        #"PATH="${PATH:+$PATH:}\#(fallbackRemotePath)""#,
        "export PATH",
        "LC_ALL=C",
        "export LC_ALL",
        #"tmux=$(printf %b "$1")"#,
        #"resolved=$(command -v "$tmux" 2> /dev/null)"#,
        "if [ -x \"$resolved\" ]; then exec \"$resolved\" list-sessions -F \"#{session_name}\"; fi",
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
}
