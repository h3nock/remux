import SwiftUI

struct SSHPublicKeyInstallSheet: View {
    let onSuccess: (SSHPublicKeyInstallCompletion) -> Void

    private let target: SSHPublicKeyInstallTarget
    private let setupSessionID: UUID
    @StateObject private var coordinator: SSHPublicKeyInstallCoordinator
    @State private var operationTask: Task<Void, Never>?
    @State private var didComplete = false

    init(
        draft: TmuxConnectionDraft,
        target: SSHPublicKeyInstallTarget,
        setupSessionID: UUID,
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
        ) throws -> Void,
        onSuccess: @escaping (SSHPublicKeyInstallCompletion) -> Void
    ) {
        self.target = target
        self.setupSessionID = setupSessionID
        self.onSuccess = onSuccess
        _coordinator = StateObject(
            wrappedValue: SSHPublicKeyInstallCoordinator(
                draft: draft,
                onPreflight: onPreflight,
                onAppend: onAppend,
                onVerify: onVerify,
                onTrustHostKey: onTrustHostKey
            )
        )
    }

    var body: some View {
        Form {
            Section {
                phaseContent
            }
        }
        .navigationTitle("Install on Host")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            start {
                await coordinator.preflight()
            }
        }
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
            coordinator.cancel()
        }
        .onChange(of: coordinator.phase) { _, phase in
            switch phase {
            case .alreadyInstalled:
                complete(.alreadyInstalled)
            case .installed:
                complete(.installed)
            default:
                break
            }
        }
        .alert(
            hostTrustTitle,
            isPresented: hostTrustIsPresented
        ) {
            if coordinator.pendingTrust?.challenge.receivedKeyFingerprint != nil {
                Button(hostTrustActionTitle) {
                    confirmHostTrust()
                }
                .accessibilityIdentifier("connection.private-key.host-trust-confirm")
            }

            Button("Cancel", role: .cancel) {
                coordinator.rejectHostTrust()
            }
        } message: {
            Text(hostTrustMessage)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.phase {
        case .idle, .preflighting:
            ProgressView("Checking public key")

        case .passwordRequired:
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the server password once to install this public key.")
                    .foregroundStyle(.secondary)

                SecureField("Server password", text: $coordinator.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.private-key.install-password")

                if let passwordError = coordinator.passwordError {
                    Text(passwordError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button("Install Public Key") {
                    start {
                        await coordinator.submitPassword()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.password.isEmpty)
                .accessibilityIdentifier("connection.private-key.install-confirm")
            }
            .padding(.vertical, 4)

        case .appending:
            ProgressView("Installing public key")

        case .verifying:
            ProgressView("Verifying public key")

        case .alreadyInstalled:
            installStatus("Already installed")

        case .installed:
            installStatus("Installed on host")

        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("connection.private-key.install-status")
        }
    }

    private func installStatus(_ message: String) -> some View {
        Label {
            Text(message)
                .accessibilityIdentifier("connection.private-key.install-status")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func start(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            await operation()
        }
    }

    private func complete(_ success: SSHPublicKeyInstallSuccess) {
        guard !didComplete else { return }
        didComplete = true
        onSuccess(
            SSHPublicKeyInstallCompletion(
                success: success,
                target: target,
                setupSessionID: setupSessionID
            )
        )
    }

    private var hostTrustIsPresented: Binding<Bool> {
        Binding(
            get: { coordinator.pendingTrust != nil },
            set: { isPresented in
                if !isPresented, coordinator.pendingTrust != nil {
                    coordinator.rejectHostTrust()
                }
            }
        )
    }

    private var hostTrustTitle: String {
        guard let challenge = coordinator.pendingTrust?.challenge else {
            return "Verify Server"
        }

        switch challenge.kind {
        case .unknown:
            return "Verify Server"
        case .changed:
            return "Host Key Changed"
        }
    }

    private var hostTrustActionTitle: String {
        guard coordinator.pendingTrust?.challenge.kind == .changed else {
            return "Trust Server"
        }
        return "Update Trust"
    }

    private var hostTrustMessage: String {
        guard let challenge = coordinator.pendingTrust?.challenge else {
            return ""
        }

        guard let fingerprint = challenge.receivedKeyFingerprint else {
            return "Remux couldn’t verify the SSH host key for \(challenge.host), so trust is unavailable."
        }
        let verification = "Received \(challenge.receivedKeyType) \(fingerprint)"

        switch challenge.kind {
        case .unknown:
            return "This is the first time Remux has seen the SSH host key for \(challenge.host). Trust it only if this fingerprint matches the server you expect.\n\n\(verification)"
        case .changed:
            return "The SSH host key for \(challenge.host) changed. Update trust only if this matches the server you expect.\n\n\(verification)"
        }
    }

    private func confirmHostTrust() {
        guard let retryPhase = coordinator.trustPendingHostKey() else {
            return
        }
        start {
            await coordinator.retryTrustedPhase(retryPhase)
        }
    }

}
