import Foundation

/// How Remux runs Herdr on a server: `exec /bin/sh -c '<script>' remux <arguments>`, with the script in
/// single quotes and every argument octal-encoded, so the user's login shell parses no argument. The
/// script uses no single quote of its own.
///
/// The script first prints Herdr's ready marker on its own line, as Herdr's own client does, so text
/// the server's startup files print can be told apart from the command's output. It then finds the
/// executable on PATH, then where Herdr's client looks, and exits 127 or 126 with a marker when it's
/// missing or can't run. The rest of the script runs it as `$resolved`; the arguments after the
/// executable are `$2`, `$3`, and so on, still encoded.
enum HerdrRemoteCommand {
    static let readyMarker = "herdr-remote-output-ready:1"
    static let notFoundMarker = "remux: herdr executable not found"
    static let notExecutableMarker = "remux: herdr executable cannot be executed"

    /// After the user's PATH: the places Herdr's client looks for itself, then the system directories
    /// the script's tools live in. Herdr also looks in mise's install directory for its own version;
    /// Remux has no version to look for there.
    static let fallbackPath = [
        "$HOME/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "$HOME/.nix-profile/bin",
        "/etc/profiles/per-user/${USER:-}/bin",
        "/nix/var/nix/profiles/default/bin",
        "/run/current-system/sw/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func command(herdrExecutable: String, arguments: [String] = [], body: [String]) -> String {
        let script = (prelude + body).joined(separator: "; ")
        return (
            ["exec /bin/sh -c '\(script)' remux", RemoteShellArgument.octalEncoded(herdrExecutable)]
                + arguments.map(RemoteShellArgument.octalEncoded)
        ).joined(separator: " ")
    }

    private static let prelude = [
        #"printf "\n%s\n" "\#(readyMarker)""#,
        #"PATH="${PATH:+$PATH:}\#(fallbackPath)""#,
        "export PATH",
        #"herdr=$(printf %b "$1")"#,
        #"resolved=$(command -v "$herdr" 2> /dev/null)"#,
        #"if [ ! -x "$resolved" ]; then if [ -e "$herdr" ]; then echo "\#(notExecutableMarker): $herdr" >&2; exit 126; fi; echo "\#(notFoundMarker): $herdr" >&2; exit 127; fi"#,
    ]

    /// Skips a stream up to the end of the ready marker's line, as Herdr's client does: the first line
    /// that is exactly the marker, optionally ending in a carriage return.
    struct ReadyLine {
        private static let marker = Array(HerdrRemoteCommand.readyMarker.utf8)
        private(set) var isFound = false
        private var matched = 0
        private var matching = true

        /// The bytes after the marker's line; nothing until it has been seen.
        mutating func output(from bytes: some Collection<UInt8>) -> [UInt8] {
            guard !isFound else { return Array(bytes) }
            var index = bytes.startIndex
            while index != bytes.endIndex {
                let byte = bytes[index]
                index = bytes.index(after: index)
                if byte == 0x0A {
                    if matching, matched == Self.marker.count {
                        isFound = true
                        return Array(bytes[index...])
                    }
                    matched = 0
                    matching = true
                } else if matching, matched < Self.marker.count, byte == Self.marker[matched] {
                    matched += 1
                } else if matching, matched != Self.marker.count || byte != 0x0D {
                    matching = false
                }
            }
            return []
        }
    }
}
