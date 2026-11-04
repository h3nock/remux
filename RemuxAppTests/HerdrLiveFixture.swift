import Foundation
import XCTest
@testable import Remux

/// The live SSH host and the official Herdr binary on it. `REMUX_LIVE_HERDR_CONFIG` names a JSON file
/// with these fields (pass it to `xcodebuild test` as `TEST_RUNNER_REMUX_LIVE_HERDR_CONFIG`); without
/// it the live Herdr tests skip.
struct HerdrLiveConfiguration: Decodable {
    let host: String
    let port: Int
    let username: String
    let privateKeyPEM: String
    /// The host's key as an OpenSSH public key line, trusted for these tests only.
    let hostKey: String
    /// The official Herdr release binaries on the host, by version ("0.9.3", "0.9.5"). A binary's
    /// digest is checked before use.
    let herdrBinaries: [String: String]

    static func load() throws -> HerdrLiveConfiguration {
        guard let path = ProcessInfo.processInfo.environment["REMUX_LIVE_HERDR_CONFIG"], !path.isEmpty else {
            throw XCTSkip("Set REMUX_LIVE_HERDR_CONFIG to run the live Herdr tests.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

struct HerdrLiveError: Error, CustomStringConvertible {
    let description: String
}

/// An isolated Herdr server on the live host. A fresh folder holds its HOME, XDG directories, TMPDIR and
/// config, and `herdr-isolated` in that folder runs the pinned official binary with nothing else in its
/// environment, so the host's own Herdr sessions and settings are never touched. Every command uses a
/// new SSH connection, because a dedicated connection closes when its command ends.
///
/// The folder name stays short: the server's client socket is
/// `<root>/config/herdr/sessions/<session>/herdr-client.sock`, and a socket path longer than
/// `sun_path` (104 bytes on macOS) keeps the server from starting.
final class HerdrLiveFixture: @unchecked Sendable {
    /// The official release assets' digests, as GitHub lists them, by version and `uname -sm`.
    static let releaseDigests = [
        "0.9.3": [
            "Darwin arm64": "5173a3e0ae42d5d1ab7ebfa5d5e6329f7c3d23f8e1a3677c7ce3231da2884157",
            "Darwin x86_64": "db62d548ff3e832b087a96b1894a08d26be3905f1830309cd556783f215d4054",
            "Linux aarch64": "4de7aa3e25678812e92960de64f7c2aaa1bca1f0f80a3c5e559837e231e1f5c0",
            "Linux x86_64": "18a8dc65f1c2fa485884344356dea1cfd911c6f06cf46fa78e193f4087f4dba7",
        ],
        "0.9.5": [
            "Darwin arm64": "fb77c2232a05a8035421382c894392f4174e4e38a18e48af3dd0290157c3a7e2",
            "Darwin x86_64": "5fb0a908ec7f6745e3e245738b06bfad56c46391c391ab3c0955fbead01f1369",
            "Linux aarch64": "17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c",
            "Linux x86_64": "14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d",
        ],
    ]

    let configuration: HerdrLiveConfiguration
    let root: String
    let session = "remux-live"
    var executable: String { root + "/herdr-isolated" }

    private let trustedHostRoot: URL
    private let serverID = UUID()

    private init(configuration: HerdrLiveConfiguration) {
        self.configuration = configuration
        let id = UUID().uuidString.lowercased()
        root = "/tmp/remux-herdr-\(id.prefix(8))"
        trustedHostRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrLiveFixture-\(id)")
    }

    /// Creates the folder and the wrapper for Herdr `version`, with `ui` as the `[ui]` settings of its
    /// config (TOML lines). The caller owns the fixture and must `tearDown()` it. A failed setup leaves
    /// nothing on the host: the script creates the folder only if it doesn't exist and removes it again
    /// when a later step fails.
    static func start(
        _ configuration: HerdrLiveConfiguration,
        version: String = "0.9.3",
        ui: [String] = []
    ) async throws -> HerdrLiveFixture {
        guard let binary = configuration.herdrBinaries[version], let digests = releaseDigests[version] else {
            throw XCTSkip("Add Herdr \(version) to herdrBinaries to run this live Herdr test.")
        }
        let fixture = HerdrLiveFixture(configuration: configuration)
        do {
            let setup = try await fixture.runScript(
                setupScript(version: version, digests: digests),
                arguments: [fixture.root, binary, (["[ui]"] + ui).joined(separator: "\n")]
            )
            guard setup.exitStatus == 0 else {
                throw HerdrLiveError(
                    description: "The live Herdr fixture could not start: \(String(decoding: setup.stderr, as: UTF8.self))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: fixture.trustedHostRoot)
            throw error
        }
        return fixture
    }

    /// Runs `herdr-isolated` with `arguments` for this fixture's session.
    func herdr(_ arguments: [String], trace: RemuxTransportStartupTrace) async throws -> RemuxSSHExecResult {
        let command = ([executable, "--session", session] + arguments)
            .map(RemoteShellArgument.octalEncoded)
            .map { "\"$(printf %b \($0))\"" }
            .joined(separator: " ")
        return try await RemuxSSHExecSession.run(
            using: try await claimRoot(trace: trace),
            command: "exec /bin/sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))'",
            stdin: nil,
            trace: trace
        )
    }

    /// Runs `script` with `/bin/sh` on the live host, with `arguments` as its positional parameters.
    func run(_ script: String, arguments: [String] = []) async throws -> RemuxSSHExecResult {
        try await runScript(script, arguments: arguments)
    }

    /// Stops this fixture's server and removes its folder, and returns what went wrong, if anything. A
    /// server that doesn't stop keeps its folder, which holds what stopping it by hand needs. Safe to
    /// call more than once.
    func tearDown() async -> [String] {
        defer { try? FileManager.default.removeItem(at: trustedHostRoot) }
        do {
            let result = try await runScript(Self.teardownScript, arguments: [root, session])
            guard result.exitStatus == 0 else {
                return ["The live Herdr fixture at \(root) was not cleaned up: \(String(decoding: result.stderr, as: UTF8.self))"]
            }
            return []
        } catch {
            return ["The live Herdr fixture at \(root) was not cleaned up: \(error)"]
        }
    }

    /// A new dedicated SSH connection to the live host.
    func claimRoot(trace: RemuxTransportStartupTrace) async throws -> RemuxSSHClaimedRoot {
        let keyParts = configuration.hostKey.split(separator: " ")
        guard keyParts.count >= 2 else {
            throw HerdrLiveError(description: "hostKey must be an OpenSSH public key line")
        }
        let trustedHostStore = TrustedHostStore(rootURL: trustedHostRoot)
        let savedServer = SavedServer(
            id: serverID,
            displayName: "herdr-live",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            identityID: serverID
        )
        try trustedHostStore.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: serverID,
                host: configuration.host,
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: String(keyParts[0]),
                receivedOpenSSHPublicKey: "\(keyParts[0]) \(keyParts[1])"
            )
        )
        let username = configuration.username
        let credential = SSHPrivateKeyCredential(privateKeyPEM: configuration.privateKeyPEM)
        let prepared = RemuxSSHPreparedRoot.dedicated(
            configuration: RemuxSSHRootConfiguration(
                host: configuration.host,
                port: configuration.port,
                authenticationMethod: {
                    try SSHAuthenticationMethodFactory.make(username: username, credential: .privateKey(credential))
                },
                hostKeyValidator: trustedHostStore.validator(for: savedServer),
                connectTimeout: .seconds(10)
            ),
            trace: trace
        )
        do {
            return try await prepared.claim(try await prepared.sshRoot(), trace: trace)
        } catch {
            await prepared.cancelAndCleanup()
            throw error
        }
    }

    private func runScript(_ script: String, arguments: [String]) async throws -> RemuxSSHExecResult {
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-script")
        let command = (["exec /bin/sh -s --"] + arguments.map(RemoteShellArgument.octalEncoded))
            .joined(separator: " ")
        return try await RemuxSSHExecSession.run(
            using: try await claimRoot(trace: trace),
            command: command,
            stdin: Data(script.utf8),
            trace: trace
        )
    }

    /// Checks the binary against the pinned release digest, then writes the folder and the wrapper. The
    /// config turns off Herdr's update checks, gives panes a plain non-login `/bin/sh` with a `$ `
    /// prompt, so pane output doesn't depend on the host's shell setup, and ends with the `[ui]` table. The wrapper starts in the
    /// isolated HOME, because the server opens its first pane in the directory it starts from.
    private static func setupScript(version: String, digests: [String: String]) -> String {
        let digestCases = digests
            .sorted { $0.key < $1.key }
            .map { #""\#($0.key)") want=\#($0.value) ;;"# }
            .joined(separator: " ")
        return #"""
        set -eu
        root=$(printf %b "$1")
        binary=$(printf %b "$2")
        ui=$(printf %b "$3")
        case "$binary" in *"'"*) echo "the Herdr binary path can't contain a single quote" >&2; exit 5 ;; esac
        case "$(uname -sm)" in \#(digestCases) *) echo "no pinned Herdr digest for $(uname -sm)" >&2; exit 3 ;; esac
        if command -v sha256sum > /dev/null 2>&1; then have=$(sha256sum "$binary" | cut -d " " -f 1); else have=$(shasum -a 256 "$binary" | cut -d " " -f 1); fi
        [ "$have" = "$want" ] || { echo "$binary is not the official Herdr v\#(version) release" >&2; exit 4; }
        umask 077
        mkdir "$root"
        trap 'rm -rf -- "$root"' EXIT
        mkdir "$root/home" "$root/config" "$root/state" "$root/data" "$root/runtime" "$root/tmp"
        printf '%s\n' '[update]' 'version_check = false' 'manifest_check = false' '' '[terminal]' 'default_shell = "/bin/sh"' 'shell_mode = "non_login"' '' "$ui" > "$root/herdr.toml"
        {
          echo '#!/bin/sh'
          echo "cd '$root/home' || exit 1"
          echo "exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 SHELL=/bin/sh PS1='\$ ' HOME='$root/home' XDG_CONFIG_HOME='$root/config' XDG_STATE_HOME='$root/state' XDG_DATA_HOME='$root/data' XDG_RUNTIME_DIR='$root/runtime' TMPDIR='$root/tmp/' HERDR_CONFIG_PATH='$root/herdr.toml' '$binary' \"\$@\""
        } > "$root/herdr-isolated"
        chmod 700 "$root/herdr-isolated"
        trap - EXIT
        """#
    }

    /// Stops the session's server if it has one (its API socket exists; `server stop` returns once the
    /// server's sockets are gone), then removes the folder only if that worked.
    private static let teardownScript = #"""
        set -u
        root=$(printf %b "$1")
        session=$(printf %b "$2")
        if [ -S "$root/config/herdr/sessions/$session/herdr.sock" ]; then
          "$root/herdr-isolated" --session "$session" server stop || exit 1
        fi
        rm -rf -- "$root"
        """#
}
