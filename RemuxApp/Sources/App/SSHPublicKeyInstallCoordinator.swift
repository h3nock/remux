import Combine
import Foundation

enum SSHPublicKeyInstallPhase: Equatable {
    case idle
    case preflighting
    case passwordRequired
    case appending
    case verifying
    case alreadyInstalled
    case installed
    case failed(String)
}

enum SSHPublicKeyInstallSuccess: Equatable {
    case alreadyInstalled
    case installed

    var message: String {
        switch self {
        case .alreadyInstalled:
            "Already installed"
        case .installed:
            "Installed on host"
        }
    }
}

struct SSHPublicKeyInstallCompletion: Equatable {
    let success: SSHPublicKeyInstallSuccess
    let target: SSHPublicKeyInstallTarget
    let setupSessionID: UUID

    func matchesActiveSetup(
        target activeTarget: SSHPublicKeyInstallTarget,
        setupSessionID activeSetupSessionID: UUID?
    ) -> Bool {
        target == activeTarget
            && setupSessionID == activeSetupSessionID
    }
}

struct SSHPublicKeyInstallConfirmation: Equatable {
    let success: SSHPublicKeyInstallSuccess
    private let host: String
    private let port: Int
    private let username: String
    private let publicKeyLine: String

    init(success: SSHPublicKeyInstallSuccess, target: SSHPublicKeyInstallTarget) {
        self.success = success
        host = target.host
        port = target.port
        username = target.username
        publicKeyLine = target.publicKeyLine
    }

    func matches(_ target: SSHPublicKeyInstallTarget) -> Bool {
        host == target.host
            && port == target.port
            && username == target.username
            && publicKeyLine == target.publicKeyLine
    }
}

struct SSHPublicKeyInstallPendingTrust: Equatable {
    enum Phase: Equatable {
        case preflight
        case append
        case verify
    }

    let challenge: SSHHostKeyTrustChallenge
    let phase: Phase
}

@MainActor
final class SSHPublicKeyInstallCoordinator: ObservableObject {
    typealias PendingTrust = SSHPublicKeyInstallPendingTrust

    struct TrustedRetry {
        fileprivate let phase: PendingTrust.Phase
        fileprivate let password: String?
    }

    @Published var password = ""
    @Published private(set) var phase: SSHPublicKeyInstallPhase = .idle
    @Published private(set) var pendingTrust: PendingTrust?
    @Published private(set) var passwordError: String?

    private let draft: TmuxConnectionDraft
    private let onPreflight: @MainActor (
        TmuxConnectionDraft
    ) async throws -> SSHPublicKeyPreflightOutcome
    private let onAppend: @MainActor (
        TmuxConnectionDraft,
        String
    ) async throws -> Void
    private let onVerify: @MainActor (
        TmuxConnectionDraft
    ) async throws -> Void
    private let onTrustHostKey: @MainActor (
        SSHHostKeyTrustChallenge
    ) throws -> Void
    private var currentOperationID = 0
    private var isActive = true

    init(
        draft: TmuxConnectionDraft,
        onPreflight: @escaping @MainActor (
            TmuxConnectionDraft
        ) async throws -> SSHPublicKeyPreflightOutcome,
        onAppend: @escaping @MainActor (
            TmuxConnectionDraft,
            String
        ) async throws -> Void,
        onVerify: @escaping @MainActor (
            TmuxConnectionDraft
        ) async throws -> Void,
        onTrustHostKey: @escaping @MainActor (
            SSHHostKeyTrustChallenge
        ) throws -> Void
    ) {
        self.draft = draft
        self.onPreflight = onPreflight
        self.onAppend = onAppend
        self.onVerify = onVerify
        self.onTrustHostKey = onTrustHostKey
    }

    func preflight() async {
        await start(.preflight)
    }

    func submitPassword() async {
        await start(.append)
    }

    func confirmHostTrust() async {
        guard let trustedRetry = trustPendingHostKey() else { return }
        await retryTrustedPhase(trustedRetry)
    }

    func trustPendingHostKey() -> TrustedRetry? {
        guard isActive, let pendingTrust else { return nil }

        do {
            try onTrustHostKey(pendingTrust.challenge)
            let retryPassword = pendingTrust.phase == .append
                ? password
                : nil
            password = ""
            self.pendingTrust = nil
            return TrustedRetry(
                phase: pendingTrust.phase,
                password: retryPassword
            )
        } catch {
            if pendingTrust.phase == .append {
                password = ""
            }
            self.pendingTrust = nil
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    func retryTrustedPhase(_ trustedRetry: TrustedRetry) async {
        await start(
            trustedRetry.phase,
            submittedPassword: trustedRetry.password
        )
    }

    func rejectHostTrust() {
        guard isActive, let pendingTrust else { return }
        if pendingTrust.phase == .append {
            password = ""
        }
        self.pendingTrust = nil
        phase = .failed("Server identity was not trusted.")
    }

    func cancel() {
        isActive = false
        currentOperationID += 1
        password = ""
        passwordError = nil
        pendingTrust = nil
        phase = .idle
    }

    private func start(
        _ requestedPhase: PendingTrust.Phase,
        submittedPassword: String? = nil
    ) async {
        guard isActive else { return }
        currentOperationID += 1
        let operationID = currentOperationID
        await retry(
            requestedPhase,
            operationID: operationID,
            submittedPassword: submittedPassword
        )
    }

    private func retry(
        _ requestedPhase: PendingTrust.Phase,
        operationID: Int,
        submittedPassword retryPassword: String? = nil
    ) async {
        guard isCurrent(operationID) else { return }
        pendingTrust = nil
        var submittedPassword = retryPassword

        do {
            switch requestedPhase {
            case .preflight:
                phase = .preflighting
                let outcome = try await onPreflight(draft)
                guard isCurrent(operationID) else { return }

                switch outcome {
                case .alreadyInstalled:
                    password = ""
                    phase = .alreadyInstalled
                case .passwordRequired:
                    passwordError = nil
                    phase = .passwordRequired
                }

            case .append:
                phase = .appending
                submittedPassword = submittedPassword ?? password
                password = ""
                try await onAppend(draft, submittedPassword ?? "")
                guard isCurrent(operationID) else { return }
                submittedPassword = nil
                passwordError = nil
                await retry(
                    .verify,
                    operationID: operationID
                )

            case .verify:
                phase = .verifying
                try await onVerify(draft)
                guard isCurrent(operationID) else { return }
                password = ""
                phase = .installed
            }
        } catch is CancellationError {
            return
        } catch TrustedHostStoreError.hostKeyTrustRequired(let challenge) {
            guard isCurrent(operationID) else { return }
            if requestedPhase == .append, let submittedPassword {
                password = submittedPassword
            }
            pendingTrust = PendingTrust(
                challenge: challenge,
                phase: requestedPhase
            )
        } catch {
            guard isCurrent(operationID) else { return }
            handleFailure(error, during: requestedPhase)
        }
    }

    private func isCurrent(_ operationID: Int) -> Bool {
        isActive
            && operationID == currentOperationID
            && !Task.isCancelled
    }

    private func handleFailure(_ error: Error, during failedPhase: PendingTrust.Phase) {
        if failedPhase == .append {
            password = ""
            if error as? SSHPublicKeyInstallerError == .passwordRejected {
                passwordError = error.localizedDescription
                phase = .passwordRequired
                return
            }
        }

        phase = .failed(error.localizedDescription)
    }
}
