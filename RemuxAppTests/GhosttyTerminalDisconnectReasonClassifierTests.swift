@preconcurrency import Citadel
import NIO
import XCTest
@preconcurrency import NIOSSH
@testable import Remux

final class GhosttyTerminalDisconnectReasonClassifierTests: XCTestCase {
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

    func testTmuxUnavailableRequiresLauncherMarker() {
        let cases = [
            (
                127,
                SSHTmuxControlCommandBuilder.tmuxNotFoundMarker,
                "Install tmux on this server or update Executable Path."
            ),
            (
                126,
                SSHTmuxControlCommandBuilder.tmuxNotExecutableMarker,
                "Check the tmux executable and its permissions, then try again."
            ),
        ]

        for (status, marker, message) in cases {
            let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.remoteExit(
                    status,
                    diagnostics: diagnostics(stderr: "\(marker): /usr/bin/tmux\\x0A")
                )
            )
            XCTAssertEqual(reason.kind, .tmuxUnavailable)
            XCTAssertEqual(reason.message, message)
        }
    }

    func testShellFailuresAreNotReportedAsTmuxUnavailable() {
        for (status, stderr) in [
            (127, "fish: Unknown command: export\\x0A"),
            (126, "fish: exec: /bin/sh: Permission denied\\x0A"),
        ] {
            let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.remoteExit(
                    status,
                    diagnostics: diagnostics(stderr: stderr)
                )
            )
            XCTAssertEqual(reason.kind, .remoteExit)
        }
    }

    private func diagnostics(stderr: String) -> SSHTmuxStartupDiagnostics {
        SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: stderr.utf8.count,
            extendedDataByteCount: 0,
            stderrPreview: stderr,
            extendedDataPreview: nil
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
