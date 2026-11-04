import Foundation
import XCTest
@testable import Remux

@MainActor
final class SSHPublicKeyInstallCoordinatorTests: XCTestCase {
    func testInstallCompletionMatchesOnlyCapturedTargetAndSetupSession() {
        let setupSessionID = UUID()
        let target = makeInstallTarget(
            host: "example.test",
            port: 22,
            username: "remux",
            publicKeyLine: "ssh-ed25519 AAAA-current"
        )
        let completion = SSHPublicKeyInstallCompletion(
            success: .installed,
            target: target,
            setupSessionID: setupSessionID
        )

        XCTAssertTrue(
            completion.matchesActiveSetup(
                target: target,
                setupSessionID: setupSessionID
            )
        )
        XCTAssertFalse(
            completion.matchesActiveSetup(
                target: makeInstallTarget(host: "other.test"),
                setupSessionID: setupSessionID
            )
        )
        XCTAssertFalse(
            completion.matchesActiveSetup(
                target: target,
                setupSessionID: UUID()
            )
        )
        XCTAssertFalse(
            completion.matchesActiveSetup(
                target: target,
                setupSessionID: nil
            )
        )
    }

    func testInstallConfirmationMatchesOnlyItsNonSecretTargetIdentity() {
        let target = makeInstallTarget(
            host: "example.test",
            port: 22,
            username: "remux",
            publicKeyLine: "ssh-ed25519 AAAA-current"
        )
        let confirmation = SSHPublicKeyInstallConfirmation(
            success: .installed,
            target: target
        )

        XCTAssertTrue(confirmation.matches(target))
        XCTAssertFalse(confirmation.matches(makeInstallTarget(host: "other.test")))
        XCTAssertFalse(confirmation.matches(makeInstallTarget(port: 2222)))
        XCTAssertFalse(confirmation.matches(makeInstallTarget(username: "other")))
        XCTAssertFalse(
            confirmation.matches(
                makeInstallTarget(publicKeyLine: "ssh-ed25519 AAAA-other")
            )
        )
        XCTAssertEqual(SSHPublicKeyInstallSuccess.alreadyInstalled.message, "Already installed")
        XCTAssertEqual(SSHPublicKeyInstallSuccess.installed.message, "Installed on host")
    }

    func testCancelledAppendIgnoresLateHostKeyFailure() async {
        let gate = AsyncGate()
        let draft = TmuxConnectionDraft()
        let challenge = hostKeyChallenge(serverID: draft.serverID)
        let coordinator = makeCoordinator(
            draft: draft,
            append: { _, _ in
                await gate.wait()
                throw TrustedHostStoreError.hostKeyTrustRequired(challenge)
            }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        let appendTask = Task { @MainActor in
            await coordinator.submitPassword()
        }
        await gate.waitUntilBlocked()

        coordinator.cancel()
        appendTask.cancel()
        await gate.open()
        await appendTask.value

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNil(coordinator.pendingTrust)
    }

    func testSupersededPreflightIgnoresLateCompletion() async {
        let gate = AsyncGate()
        var attempt = 0
        let coordinator = makeCoordinator(
            preflight: { _ in
                attempt += 1
                if attempt == 1 {
                    await gate.wait()
                    return .passwordRequired
                }
                return .alreadyInstalled
            }
        )
        let firstPreflight = Task { @MainActor in
            await coordinator.preflight()
        }
        await gate.waitUntilBlocked()

        await coordinator.preflight()
        XCTAssertEqual(coordinator.phase, .alreadyInstalled)

        await gate.open()
        await firstPreflight.value

        XCTAssertEqual(coordinator.phase, .alreadyInstalled)
        XCTAssertNil(coordinator.pendingTrust)
    }

    func testPasswordRejectionClearsPasswordWithoutVerification() async {
        var verificationCount = 0
        let coordinator = makeCoordinator(
            append: { _, _ in
                throw SSHPublicKeyInstallerError.passwordRejected
            },
            verify: { _ in
                verificationCount += 1
            }
        )

        await coordinator.preflight()
        coordinator.password = "rejected-password"
        await coordinator.submitPassword()

        XCTAssertEqual(coordinator.phase, .passwordRequired)
        XCTAssertEqual(coordinator.password, "")
        XCTAssertEqual(
            coordinator.passwordError,
            SSHPublicKeyInstallerError.passwordRejected.localizedDescription
        )
        XCTAssertEqual(verificationCount, 0)
        XCTAssertNil(coordinator.pendingTrust)
    }

    func testAppendFailureClearsPasswordWithoutVerification() async {
        var verificationCount = 0
        let coordinator = makeCoordinator(
            append: { _, _ in
                throw InstallTestError.appendFailed
            },
            verify: { _ in
                verificationCount += 1
            }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        await coordinator.submitPassword()

        XCTAssertEqual(coordinator.phase, .failed("The public key could not be appended."))
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNil(coordinator.passwordError)
        XCTAssertEqual(verificationCount, 0)
        XCTAssertNil(coordinator.pendingTrust)
    }

    func testAppendFailureStateDoesNotRetainReflectedSecrets() async {
        let secrets = [
            "PUBLIC-KEY-STATE-SENTINEL",
            "PASSWORD-STATE-SENTINEL",
            "PRIVATE-KEY-STATE-SENTINEL",
            "PASSPHRASE-STATE-SENTINEL",
        ]
        let target = SSHPublicKeyInstallTarget(
            serverID: UUID(),
            host: "example.test",
            port: 22,
            username: "remux",
            privateKey: SSHPrivateKeyCredential(
                privateKeyPEM: secrets[2],
                passphrase: secrets[3]
            ),
            publicKeyLine: secrets[0]
        )
        let reflectedOutput = secrets.joined(separator: "|")
        let installer = SSHPublicKeyInstaller(
            installationCommand: "install",
            commandRunner: { _, _, _, _ in
                RemuxSSHExecResult(
                    exitStatus: 1,
                    stdout: Data("stdout:\(reflectedOutput)".utf8),
                    stderr: Data("stderr:\(reflectedOutput)".utf8)
                )
            }
        )
        let coordinator = makeCoordinator(
            append: { _, password in
                try await installer.append(target, password: password)
            }
        )

        await coordinator.preflight()
        coordinator.password = secrets[1]
        await coordinator.submitPassword()

        guard case .failed(let retainedError) = coordinator.phase else {
            return XCTFail("expected retained failure state")
        }
        XCTAssertEqual(coordinator.password, "")
        for secret in secrets {
            XCTAssertFalse(retainedError.contains(secret))
            XCTAssertFalse(String(reflecting: coordinator.phase).contains(secret))
        }
    }

    func testRejectingAppendHostKeyClearsPasswordAndDoesNotRetry() async {
        let draft = TmuxConnectionDraft()
        let challenge = hostKeyChallenge(serverID: draft.serverID)
        var appendCount = 0
        var verificationCount = 0
        let coordinator = makeCoordinator(
            draft: draft,
            append: { _, _ in
                appendCount += 1
                throw TrustedHostStoreError.hostKeyTrustRequired(challenge)
            },
            verify: { _ in
                verificationCount += 1
            }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        await coordinator.submitPassword()
        XCTAssertEqual(coordinator.pendingTrust?.phase, .append)
        XCTAssertEqual(coordinator.password, "one-time-password")

        coordinator.rejectHostTrust()

        XCTAssertEqual(coordinator.phase, .failed("Server identity was not trusted."))
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNil(coordinator.pendingTrust)
        XCTAssertEqual(appendCount, 1)
        XCTAssertEqual(verificationCount, 0)
    }

    func testTrustingPreflightHostKeyRetriesPreflightOnly() async {
        let draft = TmuxConnectionDraft()
        let challenge = hostKeyChallenge(serverID: draft.serverID)
        var preflightCount = 0
        var appendCount = 0
        var verificationCount = 0
        var trustedChallenges: [SSHHostKeyTrustChallenge] = []
        let coordinator = makeCoordinator(
            draft: draft,
            preflight: { _ in
                preflightCount += 1
                if preflightCount == 1 {
                    throw TrustedHostStoreError.hostKeyTrustRequired(challenge)
                }
                return .passwordRequired
            },
            append: { _, _ in
                appendCount += 1
            },
            verify: { _ in
                verificationCount += 1
            },
            trust: { trustedChallenges.append($0) }
        )

        await coordinator.preflight()
        XCTAssertEqual(coordinator.pendingTrust?.phase, .preflight)

        await coordinator.confirmHostTrust()

        XCTAssertEqual(trustedChallenges, [challenge])
        XCTAssertEqual(preflightCount, 2)
        XCTAssertEqual(appendCount, 0)
        XCTAssertEqual(verificationCount, 0)
        XCTAssertEqual(coordinator.phase, .passwordRequired)
    }

    func testTrustingAppendHostKeyRetriesAppendThenVerifies() async {
        let draft = TmuxConnectionDraft()
        let challenge = hostKeyChallenge(serverID: draft.serverID)
        var appendCount = 0
        var verificationCount = 0
        var trustedChallenges: [SSHHostKeyTrustChallenge] = []
        let coordinator = makeCoordinator(
            draft: draft,
            append: { _, password in
                appendCount += 1
                XCTAssertEqual(password, "one-time-password")
                if appendCount == 1 {
                    throw TrustedHostStoreError.hostKeyTrustRequired(challenge)
                }
            },
            verify: { _ in
                verificationCount += 1
            },
            trust: { trustedChallenges.append($0) }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        await coordinator.submitPassword()
        XCTAssertEqual(coordinator.pendingTrust?.phase, .append)
        XCTAssertEqual(coordinator.password, "one-time-password")

        let pendingRetry = coordinator.trustPendingHostKey()
        XCTAssertEqual(coordinator.password, "")
        if let pendingRetry {
            await coordinator.retryTrustedPhase(pendingRetry)
        }

        XCTAssertEqual(trustedChallenges, [challenge])
        XCTAssertEqual(appendCount, 2)
        XCTAssertEqual(verificationCount, 1)
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNil(coordinator.pendingTrust)
        XCTAssertEqual(coordinator.phase, .installed)
    }

    func testTrustingVerifyHostKeyRetriesVerifyOnly() async {
        let draft = TmuxConnectionDraft()
        let challenge = hostKeyChallenge(serverID: draft.serverID)
        var appendCount = 0
        var verificationCount = 0
        var trustedChallenges: [SSHHostKeyTrustChallenge] = []
        let coordinator = makeCoordinator(
            draft: draft,
            append: { _, _ in
                appendCount += 1
            },
            verify: { _ in
                verificationCount += 1
                if verificationCount == 1 {
                    throw TrustedHostStoreError.hostKeyTrustRequired(challenge)
                }
            },
            trust: { trustedChallenges.append($0) }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        await coordinator.submitPassword()
        XCTAssertEqual(coordinator.pendingTrust?.phase, .verify)
        XCTAssertEqual(coordinator.password, "")

        await coordinator.confirmHostTrust()

        XCTAssertEqual(trustedChallenges, [challenge])
        XCTAssertEqual(appendCount, 1)
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNil(coordinator.pendingTrust)
        XCTAssertEqual(coordinator.phase, .installed)
    }

    func testInstallSucceedsOnlyAfterFreshVerification() async {
        let gate = AsyncGate()
        let draft = TmuxConnectionDraft()
        var appendedDraft: TmuxConnectionDraft?
        var appendedPassword: String?
        let coordinator = makeCoordinator(
            draft: draft,
            append: { receivedDraft, password in
                appendedDraft = receivedDraft
                appendedPassword = password
            },
            verify: { _ in
                await gate.wait()
            }
        )

        await coordinator.preflight()
        coordinator.password = "one-time-password"
        let appendTask = Task { @MainActor in
            await coordinator.submitPassword()
        }
        await gate.waitUntilBlocked()

        XCTAssertEqual(coordinator.phase, .verifying)
        XCTAssertEqual(coordinator.password, "")
        XCTAssertNotEqual(coordinator.phase, .installed)
        XCTAssertEqual(appendedDraft?.password, "")
        XCTAssertEqual(appendedPassword, "one-time-password")

        await gate.open()
        await appendTask.value

        XCTAssertEqual(coordinator.phase, .installed)
        XCTAssertEqual(coordinator.password, "")
    }

    private func makeCoordinator(
        draft: TmuxConnectionDraft = TmuxConnectionDraft(),
        preflight: @escaping @MainActor (
            TmuxConnectionDraft
        ) async throws -> SSHPublicKeyPreflightOutcome = { _ in .passwordRequired },
        append: @escaping @MainActor (
            TmuxConnectionDraft,
            String
        ) async throws -> Void = { _, _ in },
        verify: @escaping @MainActor (
            TmuxConnectionDraft
        ) async throws -> Void = { _ in },
        trust: @escaping @MainActor (
            SSHHostKeyTrustChallenge
        ) throws -> Void = { _ in }
    ) -> SSHPublicKeyInstallCoordinator {
        SSHPublicKeyInstallCoordinator(
            draft: draft,
            onPreflight: preflight,
            onAppend: append,
            onVerify: verify,
            onTrustHostKey: trust
        )
    }

    private func makeInstallTarget(
        host: String = "example.test",
        port: Int = 22,
        username: String = "remux",
        publicKeyLine: String = "ssh-ed25519 AAAA-current"
    ) -> SSHPublicKeyInstallTarget {
        SSHPublicKeyInstallTarget(
            serverID: UUID(),
            host: host,
            port: port,
            username: username,
            privateKey: SSHPrivateKeyCredential(
                privateKeyPEM: "PRIVATE-KEY-NOT-RETAINED",
                passphrase: "PASSPHRASE-NOT-RETAINED"
            ),
            publicKeyLine: publicKeyLine
        )
    }

    private func hostKeyChallenge(
        serverID: SavedServer.ID
    ) -> SSHHostKeyTrustChallenge {
        SSHHostKeyTrustChallenge(
            kind: .unknown,
            serverID: serverID,
            host: "example.test",
            trustedKeyType: nil,
            trustedOpenSSHPublicKey: nil,
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
        )
    }
}

private enum InstallTestError: LocalizedError {
    case appendFailed

    var errorDescription: String? {
        "The public key could not be appended."
    }
}

private actor AsyncGate {
    private var isBlocked = false
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isBlocked = true
        let waiters = blockWaiters
        blockWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isBlocked {
            return
        }

        await withCheckedContinuation { continuation in
            blockWaiters.append(continuation)
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
