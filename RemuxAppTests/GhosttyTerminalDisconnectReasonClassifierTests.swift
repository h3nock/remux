@preconcurrency import Citadel
import NIO
import LocalAuthentication
import XCTest
@preconcurrency import NIOSSH
@testable import Remux

final class GhosttyTerminalDisconnectReasonClassifierTests: XCTestCase {
    func testLocalUnlockFailureDoesNotSuggestRejectedCredentials() {
        for error: any Error in [LAError(.authenticationFailed), LAError(.userCancel), SecureEnclaveSSHError.appNotActive] {
            let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
            XCTAssertEqual(reason.kind, .keyUnlock)
            XCTAssertFalse(reason.allowsAutomaticReconnect)
            XCTAssertEqual(reason.message, error.localizedDescription)
        }
    }

    func testTransportStartFailureMapsKnownBoundaryErrors() {
        let hostKeyChallenge = SSHHostKeyTrustChallenge(
            kind: .changed,
            serverID: UUID(),
            host: "example.com",
            trustedKeyType: "ssh-ed25519",
            trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 received"
        )
        let changedReason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            TrustedHostStoreError.hostKeyTrustRequired(hostKeyChallenge)
        )
        XCTAssertEqual(
            changedReason.kind,
            .hostKey
        )
        XCTAssertEqual(changedReason.hostKeyChallenge, hostKeyChallenge)

        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                TrustedHostStoreError.invalidHostKey
            ).kind,
            .hostKey
        )
    }

    func testTransportStartFailureMapsSSHErrors() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.remoteExit(1)
            ).kind,
            .remoteExit
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.channelRequestFailed(.exec)
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.closed
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.stalePreparedConnection
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.alreadyStarted
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.unsupportedInboundChannel
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.controlSessionNoResponse(.seconds(15))
            ).kind,
            .profile
        )
    }

    /// The launch runs on a pty, so what the script and the shell print arrives as startup output, with
    /// carriage returns. Where nothing can run, the words depend on whether a path is set.
    func testATmuxThatIsNotThereIsUnavailable() {
        let failure = SSHTmuxControlTransportError.remoteExit(
            127,
            diagnostics: diagnostics(messages: "remux: not found: tmux\r\n")
        )

        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(failure, tmuxPath: nil),
            TerminalDisconnectReason(
                kind: .backendUnavailable(.tmux),
                message: "Remux couldn't find tmux on this server. Install it, or set its path in Edit Server."
            )
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(failure, tmuxPath: "/opt/tools/tmux"),
            TerminalDisconnectReason(
                kind: .backendUnavailable(.tmux),
                message: "Remux can't run tmux from /opt/tools/tmux. Check the path in Edit Server."
            )
        )
    }

    /// The shell's own line, captured on Debian with dash, follows both copies of the ready marker.
    func testATmuxTheServerCannotStartShowsTheServersWords() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(
            SSHTmuxControlTransportError.remoteExit(
                126,
                diagnostics: diagnostics(
                    messages: "\r\nremux-ready:1\r\n\r\nremux-ready:1\r\nsh: 1: exec: /opt/tools/tmux: Exec format error\r\n"
                )
            ),
            tmuxPath: "/opt/tools/tmux"
        )

        XCTAssertEqual(reason, TerminalDisconnectReason(
            kind: .backendUnavailable(.tmux),
            message: "Running /opt/tools/tmux failed.",
            detail: "sh: 1: exec: /opt/tools/tmux: Exec format error"
        ))
    }

    /// The login shell failed before the script ran: not tmux's failure, so it's an exit, with the end of
    /// what the shell printed under it.
    func testALoginShellThatFailsIsAnExitNotTmuxUnavailable() {
        let fish = "fish: Unknown command: export\r\n~/.config/fish/config.fish (line 1):\r\nexport LANG=C\r\n^~~~~^\r\n"
        for (status, output, words) in [
            (127, fish, "fish: Unknown command: export\n~/.config/fish/config.fish (line 1):\nexport LANG=C\n^~~~~^"),
            (126, "Welcome to lab\r\n\r\nfish: exec: /bin/sh: Permission denied  \r\n", "Welcome to lab\nfish: exec: /bin/sh: Permission denied"),
            (1, "This account is currently not available.\n", "This account is currently not available."),
            (1, (1...8).map { "line \($0)" }.joined(separator: "\n"), (3...8).map { "line \($0)" }.joined(separator: "\n")),
        ] {
            let reason = GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(
                SSHTmuxControlTransportError.remoteExit(status, diagnostics: diagnostics(messages: output)),
                tmuxPath: nil
            )
            XCTAssertEqual(reason, TerminalDisconnectReason(
                kind: .remoteExit,
                message: "The server closed the connection before tmux started.",
                detail: words
            ))
        }

        let silent = GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(
            SSHTmuxControlTransportError.remoteExit(1, diagnostics: nil),
            tmuxPath: nil
        )
        XCTAssertNil(silent.detail)
    }

    private func diagnostics(messages: String) -> SSHTmuxStartupDiagnostics {
        SSHTmuxStartupDiagnostics(
            stdoutByteCount: messages.utf8.count,
            stderrByteCount: 0,
            extendedDataByteCount: 0,
            stderrPreview: nil,
            extendedDataPreview: nil,
            startupOutputPreview: nil,
            messages: messages
        )
    }

    func testTransportStartFailureMapsAuthenticationTextFallbacks() {
        for message in [
            "authentication failed",
            "bad password",
            "Permission denied",
        ] {
            XCTAssertEqual(
                GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                    DescribedError(message)
                ).kind,
                .authentication,
                message
            )
        }
    }

    func testTransportStartFailureMapsConnectTimeoutAsServerUnreachable() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            ChannelError.connectTimeout(.seconds(30))
        )

        XCTAssertEqual(reason.kind, .serverUnreachable)
    }

    /// New credentials can't fix an expired Tailscale check, so it isn't an authentication failure.
    func testTailscaleCheckTimeoutIsAnExpiredVerification() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            TailscaleSSHCheckError.verificationTimedOut
        )

        XCTAssertEqual(reason.kind, .verificationExpired)
        XCTAssertEqual(
            reason.message,
            TailscaleSSHCheckError.verificationTimedOut.localizedDescription
        )
    }

    func testTransportStartFailureMapsUnknownFallback() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            DescribedError("connection fizzled")
        )

        XCTAssertEqual(reason.kind, .unknown)
        XCTAssertEqual(reason.message, "connection fizzled")
    }

    func testForegroundMissingHostUsesCurrentMessage() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost(),
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport unavailable after foreground"
            )
        )
    }
}

final class TrustedHostStoreTests: XCTestCase {
    func testTrustHostKeyRejectsChallengeWithoutFingerprint() throws {
        let root = temporaryRoot()
        let store = TrustedHostStore(rootURL: root)
        let challenge = SSHHostKeyTrustChallenge(
            kind: .unknown,
            serverID: UUID(),
            host: "server.example.com",
            trustedKeyType: nil,
            trustedOpenSSHPublicKey: nil,
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 not-base64"
        )

        XCTAssertThrowsError(try store.trustHostKey(challenge)) { error in
            guard case TrustedHostStoreError.invalidHostKey = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("trusted-hosts.json").path
            )
        )
    }

    func testValidatorRequiresExplicitTrustForUnknownHostKey() throws {
        let root = temporaryRoot()
        let server = SavedServer(
            id: UUID(),
            displayName: "Server",
            host: "server.example.com",
            username: "macbook",
            identityID: UUID()
        )
        let hostKey = try makeHostKey(comment: "unknown")
        let expectedOpenSSHKey = String(openSSHPublicKey: hostKey)
        let store = TrustedHostStore(rootURL: root)

        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        store.validator(for: server).validateHostKey(
            hostKey: hostKey,
            validationCompletePromise: promise
        )

        var capturedChallenge: SSHHostKeyTrustChallenge?
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            guard case TrustedHostStoreError.hostKeyTrustRequired(let challenge) = error else {
                return XCTFail("unexpected error: \(error)")
            }

            capturedChallenge = challenge
            XCTAssertEqual(challenge.kind, .unknown)
            XCTAssertEqual(challenge.serverID, server.id)
            XCTAssertEqual(challenge.host, server.host)
            XCTAssertNil(challenge.trustedKeyType)
            XCTAssertNil(challenge.trustedOpenSSHPublicKey)
            XCTAssertEqual(challenge.receivedKeyType, "ssh-ed25519")
            XCTAssertEqual(challenge.receivedOpenSSHPublicKey, expectedOpenSSHKey)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("trusted-hosts.json").path)
        )

        try store.trustHostKey(try XCTUnwrap(capturedChallenge))

        let acceptedPromise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        store.validator(for: server).validateHostKey(
            hostKey: hostKey,
            validationCompletePromise: acceptedPromise
        )
        XCTAssertNoThrow(try acceptedPromise.futureResult.wait())
    }

    func testTrustHostKeyUpdatesOnlyMatchingTrustedKey() throws {
        let root = temporaryRoot()
        let serverID = UUID()
        let trusted = TrustedHostIdentity(
            serverID: serverID,
            host: "server.example.com",
            keyType: "ssh-ed25519",
            openSSHPublicKey: "ssh-ed25519 trusted",
            trustedAt: Date(timeIntervalSince1970: 1)
        )
        try saveIdentities([trusted], root: root)

        let store = TrustedHostStore(rootURL: root)
        try store.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .changed,
                serverID: serverID,
                host: "server.example.com",
                trustedKeyType: "ssh-ed25519",
                trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
                receivedKeyType: "ecdsa-sha2-nistp256",
                receivedOpenSSHPublicKey: "ecdsa-sha2-nistp256 cmVjZWl2ZWQ="
            )
        )

        let identities = try loadIdentities(root: root)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].serverID, serverID)
        XCTAssertEqual(identities[0].host, "server.example.com")
        XCTAssertEqual(identities[0].keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(
            identities[0].openSSHPublicKey,
            "ecdsa-sha2-nistp256 cmVjZWl2ZWQ="
        )
    }

    func testTrustHostKeyRejectsStaleChange() throws {
        let root = temporaryRoot()
        let serverID = UUID()
        let current = TrustedHostIdentity(
            serverID: serverID,
            host: "server.example.com",
            keyType: "ssh-ed25519",
            openSSHPublicKey: "ssh-ed25519 current",
            trustedAt: Date(timeIntervalSince1970: 1)
        )
        try saveIdentities([current], root: root)

        let store = TrustedHostStore(rootURL: root)

        XCTAssertThrowsError(
            try store.trustHostKey(
                SSHHostKeyTrustChallenge(
                    kind: .changed,
                    serverID: serverID,
                    host: "server.example.com",
                    trustedKeyType: "ssh-ed25519",
                    trustedOpenSSHPublicKey: "ssh-ed25519 stale",
                    receivedKeyType: "ecdsa-sha2-nistp256",
                    receivedOpenSSHPublicKey: "ecdsa-sha2-nistp256 cmVjZWl2ZWQ="
                )
            )
        ) { error in
            guard case TrustedHostStoreError.staleHostKeyTrust(host: "server.example.com") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try loadIdentities(root: root), [current])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func saveIdentities(_ identities: [TrustedHostIdentity], root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(identities)
        try data.write(to: root.appendingPathComponent("trusted-hosts.json"), options: .atomic)
    }

    private func loadIdentities(root: URL) throws -> [TrustedHostIdentity] {
        let data = try Data(contentsOf: root.appendingPathComponent("trusted-hosts.json"))
        return try JSONDecoder().decode([TrustedHostIdentity].self, from: data)
    }

    private func makeHostKey(comment: String) throws -> NIOSSHPublicKey {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: comment)
        return try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyLine)
    }
}

private struct DescribedError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
