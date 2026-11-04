import NIO
import XCTest
@testable import Remux

/// The panel over a session that couldn't open or stopped, for each way that happens, from the reason the
/// session reports.
final class GhosttyRepairPanelContentTests: XCTestCase {
    private static let server = SavedServer(displayName: "Lab", host: "lab.example.test", username: "builder")

    private func panel(_ reason: TerminalDisconnectReason?) -> GhosttyRepairPanelContent {
        GhosttyRepairPanelContent(reason: reason, sessionName: "main", serverName: Self.server.displayName)
    }

    private func titles(_ content: GhosttyRepairPanelContent) -> [String] {
        content.actions.map(\.title)
    }

    func testAServerSeenForTheFirstTimeShowsItsKey() {
        let challenge = hostKeyChallenge(.unknown, key: Self.validKey)
        let content = panel(TerminalDisconnectReason(kind: .hostKey, message: "trust required", hostKeyChallenge: challenge))

        XCTAssertEqual(content.title, "Verify Server")
        XCTAssertEqual(
            content.message,
            "First connection to lab.example.test. Trust it only if this fingerprint matches the server."
        )
        XCTAssertEqual(content.hostKey, "ssh-ed25519 \(challenge.receivedKeyFingerprint!)")
        XCTAssertEqual(titles(content), ["Cancel", "Trust Server"])
        XCTAssertEqual(content.actions.last?.isPrimary, true)
    }

    func testAChangedKeyIsTrustedAsANewKey() {
        let content = panel(TerminalDisconnectReason(
            kind: .hostKey,
            message: "trust required",
            hostKeyChallenge: hostKeyChallenge(.changed, key: Self.validKey)
        ))

        XCTAssertEqual(content.title, "Host Key Changed")
        XCTAssertEqual(
            content.message,
            "lab.example.test has a different key than last time. Trust it only if you expected this."
        )
        XCTAssertEqual(titles(content), ["Cancel", "Trust New Key"])
    }

    func testAKeyRemuxCannotReadCannotBeTrusted() {
        let content = panel(TerminalDisconnectReason(
            kind: .hostKey,
            message: "trust required",
            hostKeyChallenge: hostKeyChallenge(.unknown, key: "not-a-key")
        ))

        XCTAssertEqual(content.message, "Remux couldn't read the key lab.example.test offered, so it can't be trusted.")
        XCTAssertNil(content.hostKey)
        XCTAssertEqual(titles(content), ["Cancel"])
    }

    /// A key Remux can't read, or trust that changed while connecting, has no key to review; reconnecting asks
    /// again when there is one.
    func testAHostKeyFailureWithoutAKeyToReviewSaysSo() {
        for error in [
            TrustedHostStoreError.invalidHostKey,
            TrustedHostStoreError.staleHostKeyTrust(host: "lab.example.test"),
        ] {
            let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error))
            XCTAssertEqual(content.title, "Disconnected", "\(error)")
            XCTAssertEqual(content.message, "Remux couldn't verify this server's key.", "\(error)")
            XCTAssertNil(content.hostKey)
            XCTAssertEqual(titles(content), ["Reconnect"])
        }
    }

    /// Credentials the server turned down and a key made on this device that can't be used here are both fixed by
    /// updating them, and neither is said to be the server's rejection.
    func testFailedCredentialsOfferUpdatingThemWithoutBlamingTheServer() {
        for error: any Error in [Failure("Permission denied"), SecureEnclaveSSHError.keyUnusable] {
            let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error))

            XCTAssertEqual(content.title, "Authentication Failed", "\(error)")
            XCTAssertEqual(content.message, "Check the saved credentials for Lab.", "\(error)")
            XCTAssertEqual(content.actions.map(\.kind), [.updateCredentials], "\(error)")
            XCTAssertEqual(titles(content), ["Update Credentials"], "\(error)")
        }
    }

    /// Tailscale's check ran out of time: retrying gets a new one, and the credentials aren't the problem.
    func testAnExpiredTailscaleVerificationOffersARetry() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            TailscaleSSHCheckError.verificationTimedOut
        ))

        XCTAssertEqual(content.title, "Verification Expired")
        XCTAssertEqual(content.message, "Tailscale verification wasn't completed in time.")
        XCTAssertEqual(titles(content), ["Retry"])
        XCTAssertEqual(content.actions.first?.accessibilityIdentifier, "terminal.status.verificationExpired.retry")
    }

    func testAnUnreachableServerSaysWhatToCheck() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            ChannelError.connectTimeout(.seconds(30))
        ))

        XCTAssertEqual(content.title, "Server Unreachable")
        XCTAssertEqual(content.message, "Check the address, port, network, or VPN.")
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
    }

    func testAMissingBackendShowsItsOwnPanel() {
        let content = panel(BackendProblem.notFound.disconnectReason(for: .herdr))

        XCTAssertEqual(content.title, "Herdr Unavailable")
        XCTAssertEqual(
            content.message,
            "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
        )
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
        XCTAssertEqual(content.actions.map(\.accessibilityIdentifier), [
            "terminal.status.herdr.retry",
            "terminal.status.herdr.editServer",
        ])
    }

    /// The terminal library closes a session on a tmux older than it supports; a reconnect would fail the
    /// same way, and a path to a newer tmux fixes it.
    func testATmuxTooOldIsTmuxUnavailable() {
        let content = panel(TmuxSessionController.CloseReason.unsupportedVersion("3.0a").terminalDisconnectReason)

        XCTAssertEqual(content.title, "tmux Unavailable")
        XCTAssertEqual(content.message, "tmux 3.0a on this server is too old. Remux needs 3.1 or later.")
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])
    }

    func testALoginShellThatFailsShowsTheServersWords() {
        let content = panel(GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(
            SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics("This account is currently not available.\n")),
            tmuxPath: nil
        ))

        XCTAssertEqual(content.title, "Disconnected")
        XCTAssertEqual(content.message, "The server closed the connection before tmux started.")
        XCTAssertEqual(content.detail, "This account is currently not available.")
        XCTAssertEqual(titles(content), ["Reconnect"])
    }

    /// Herdr says why it stopped; a live update's reason says to reconnect.
    func testHerdrStoppingNamesTheServerAndKeepsHerdrsReason() {
        let reason = "live update in progress; reconnect after handoff completes"
        let content = panel(HerdrConnectionError.serverShutdown(reason: reason).terminalDisconnectReason(on: Self.server))

        XCTAssertEqual(content.title, "Disconnected")
        XCTAssertEqual(content.message, "Herdr stopped on Lab.")
        XCTAssertEqual(content.detail, reason)
        XCTAssertEqual(titles(content), ["Reconnect"])

        XCTAssertNil(panel(HerdrConnectionError.serverShutdown(reason: nil).terminalDisconnectReason(on: Self.server)).detail)
    }

    /// Herdr's client asks to update and restart a server older than it supports: the install may already be
    /// new while the old server keeps running.
    func testAnOldRunningHerdrSaysToUpdateAndRestartIt() {
        let content = panel(HerdrConnectionError.outdated(serverVersion: "0.9.2").terminalDisconnectReason(on: Self.server))

        XCTAssertEqual(content.title, "Herdr Unavailable")
        XCTAssertEqual(content.message, "Herdr 0.9.2 is running on Lab. Update Herdr, then restart its server.")
        XCTAssertEqual(titles(content), ["Retry", "Edit Server"])

        XCTAssertEqual(
            panel(HerdrConnectionError.outdated(serverVersion: nil).terminalDisconnectReason(on: Self.server)).message,
            "An older Herdr is running on Lab. Update Herdr, then restart its server."
        )
    }

    /// A Herdr that refuses the hello says why in its own words.
    func testAHerdrThatDoesNotWorkWithRemuxSaysSo() {
        let refused = panel(HerdrConnectionError.rejected(code: "unsupported_generation", message: "endpoint generation 1 is not supported")
            .terminalDisconnectReason(on: Self.server))
        XCTAssertEqual(refused.title, "Herdr Unavailable")
        XCTAssertEqual(refused.message, "Herdr on Lab doesn't work with this version of Remux.")
        XCTAssertEqual(refused.detail, "endpoint generation 1 is not supported")

        let incompatible = panel(HerdrConnectionError.incompatible("it speaks endpoint generation 2").terminalDisconnectReason(on: Self.server))
        XCTAssertEqual(incompatible.message, "Herdr on Lab doesn't work with this version of Remux.")
        XCTAssertNil(incompatible.detail)
    }

    func testALoginShellThatFailsBeforeHerdrShowsTheServersWords() {
        let content = panel(HerdrBridgeError.remoteExit(status: 1, stderr: "This account is currently not available.\n")
            .terminalDisconnectReason(on: Self.server))

        XCTAssertEqual(content.title, "Disconnected")
        XCTAssertEqual(content.message, "The server closed the connection before Herdr started.")
        XCTAssertEqual(content.detail, "This account is currently not available.")
    }

    /// The session is gone from the server: close it, or start a new one with its name.
    func testASessionThatEndedOffersCloseAndRestart() {
        let content = panel(TmuxSessionController.DetachReason.sessionEnded.terminalDisconnectReason)

        XCTAssertEqual(content.title, "Session Ended")
        XCTAssertEqual(content.message, "main is no longer running on Lab.")
        XCTAssertEqual(titles(content), ["Close", "Restart"])
        XCTAssertEqual(content.actions.map(\.kind), [.close, .restart])
        XCTAssertEqual(content.actions.first?.isPrimary, true)
        XCTAssertFalse(TmuxSessionController.DetachReason.sessionEnded.terminalDisconnectReason.allowsAutomaticReconnect)
    }

    /// tmux ending the client is a lost connection: Remux reconnects, which attaches if the session is still
    /// there.
    func testTmuxEndingTheClientReconnects() {
        for reason in [
            TmuxSessionController.DetachReason.serverExited(nil),
            .serverExited("too far behind"),
            .serverExited("server exited unexpectedly"),
        ] {
            let disconnect = reason.terminalDisconnectReason
            XCTAssertEqual(disconnect.kind, .transportIO, "\(reason)")
            XCTAssertTrue(disconnect.allowsAutomaticReconnect, "\(reason)")
            XCTAssertEqual(panel(disconnect).message, "The connection was lost.")
        }
    }

    func testALostConnectionSaysSo() {
        let content = panel(TmuxSessionController.DetachReason.transportClosed.terminalDisconnectReason)

        XCTAssertEqual(content.message, "The connection was lost.")
        XCTAssertEqual(titles(content), ["Reconnect"])
    }

    /// What Remux knows about its own failures goes to its diagnostics, not the screen.
    func testRemuxsOwnFailuresDoNotShowTheirInternals() {
        let reasons: [TerminalDisconnectReason?] = [
            TmuxSessionController.DetachReason.channelAborted.terminalDisconnectReason,
            TmuxSessionController.DetachReason.outOfMemory.terminalDisconnectReason,
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.controlSessionNoResponse(.seconds(15))
            ),
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(Failure("connection fizzled")),
            HerdrConnectionError.wire(.invalidSurfaceUpdate("surface delta without a baseline"))
                .terminalDisconnectReason(on: Self.server),
            nil,
        ]
        for reason in reasons {
            let content = panel(reason)
            XCTAssertEqual(content.title, "Disconnected", String(describing: reason))
            XCTAssertEqual(content.message, "Something went wrong with this session.", String(describing: reason))
            XCTAssertNil(content.detail)
            XCTAssertEqual(titles(content), ["Reconnect"])
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let validKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"

    private func hostKeyChallenge(_ kind: SSHHostKeyTrustChallenge.Kind, key: String) -> SSHHostKeyTrustChallenge {
        SSHHostKeyTrustChallenge(
            kind: kind,
            serverID: Self.server.id,
            host: "lab.example.test",
            trustedKeyType: nil,
            trustedOpenSSHPublicKey: nil,
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: key
        )
    }

    private func diagnostics(_ messages: String) -> SSHTmuxStartupDiagnostics {
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
}
