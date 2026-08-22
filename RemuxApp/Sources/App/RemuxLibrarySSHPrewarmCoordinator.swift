import Foundation

struct RemuxLibrarySSHPrewarmCurrentContext: Sendable {
    let snapshot: ConnectionLibrarySnapshot
    let isLibraryVisible: Bool
    let activeServerIDs: Set<SavedServer.ID>
    let terminalSettings: TerminalSettings
}

@MainActor
final class RemuxLibrarySSHPrewarmCoordinator {
    typealias AuthResolver = @Sendable (
        _ server: SavedServer,
        _ snapshot: ConnectionLibrarySnapshot
    ) async throws -> ResolvedSSHAuth
    typealias SSHConnectionPrewarmer = @Sendable (TmuxConnectionTarget) async -> Void
    typealias CurrentContextProvider = @MainActor @Sendable () -> RemuxLibrarySSHPrewarmCurrentContext?
    typealias EligibleTargetHandler = @MainActor @Sendable (TmuxConnectionTarget) -> Void

    private let limit: Int
    private let authResolver: AuthResolver
    private let sshConnectionPrewarmer: SSHConnectionPrewarmer
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        limit: Int,
        authResolver: @escaping AuthResolver,
        sshConnectionPrewarmer: @escaping SSHConnectionPrewarmer
    ) {
        self.limit = limit
        self.authResolver = authResolver
        self.sshConnectionPrewarmer = sshConnectionPrewarmer
    }

    deinit {
        task?.cancel()
    }

    func schedule(
        snapshot: ConnectionLibrarySnapshot,
        activeServerIDs: Set<SavedServer.ID>,
        terminalSettings: TerminalSettings,
        currentContext: @escaping CurrentContextProvider,
        onEligibleTarget: @escaping EligibleTargetHandler
    ) {
        let candidates = RemuxLibrarySSHPrewarmPlanner.candidates(
            in: snapshot,
            excludingServerIDs: activeServerIDs,
            limit: limit
        )
        guard !candidates.isEmpty else {
            cancel()
            return
        }

        cancel()
        let capturedGeneration = generation
        let authResolver = authResolver
        let sshConnectionPrewarmer = sshConnectionPrewarmer
        task = Task.detached(priority: .utility) { [weak self] in
            GhosttyRuntimeTrace.latency("library.prewarm scheduled count=\(candidates.count)")
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                do {
                    let sshAuth = try await authResolver(candidate.server, snapshot)
                    let target = TmuxConnectionTarget(
                        server: candidate.server,
                        workspace: candidate.workspace,
                        sshAuth: sshAuth,
                        terminalSettings: terminalSettings
                    )
                    await sshConnectionPrewarmer(target)
                    guard !Task.isCancelled else { return }
                    await self?.prepareIfStillEligible(
                        authResolver: authResolver,
                        candidate: candidate,
                        target: target,
                        capturedGeneration: capturedGeneration,
                        currentContext: currentContext,
                        onEligibleTarget: onEligibleTarget
                    )
                } catch is SSHAuthResolverError {
                    await MainActor.run {
                        self?.traceSkipped(
                            candidate: candidate,
                            reason: RemuxLibrarySSHPrewarmSkipReason.missingAuth.rawValue
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    NSLog(
                        "Remux library SSH prewarm failed for %@: %@",
                        candidate.server.displayName,
                        String(describing: error)
                    )
                }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func prepareIfStillEligible(
        authResolver: AuthResolver,
        candidate: RemuxLibrarySSHPrewarmCandidate,
        target: TmuxConnectionTarget,
        capturedGeneration: UInt64,
        currentContext: CurrentContextProvider,
        onEligibleTarget: EligibleTargetHandler
    ) async {
        guard let context = currentContext() else { return }
        let currentServer = context.snapshot.server(id: candidate.server.id)
        let currentWorkspace = context.snapshot.workspace(id: candidate.workspace.id)
        let hasActiveSessionOnServer = currentServer.map {
            context.activeServerIDs.contains($0.id)
        } ?? false
        let currentTarget: TmuxConnectionTarget?
        if let currentServer, let currentWorkspace {
            do {
                currentTarget = TmuxConnectionTarget(
                    server: currentServer,
                    workspace: currentWorkspace,
                    sshAuth: try await authResolver(currentServer, context.snapshot),
                    terminalSettings: context.terminalSettings
                )
            } catch {
                currentTarget = nil
            }
        } else {
            currentTarget = nil
        }

        switch RemuxLibrarySSHPrewarmPlanner.eligibility(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            isLibraryVisible: context.isLibraryVisible,
            candidate: candidate,
            capturedTarget: target,
            currentServer: currentServer,
            currentWorkspace: currentWorkspace,
            currentTarget: currentTarget,
            currentTerminalSettings: context.terminalSettings,
            hasActiveSessionOnServer: hasActiveSessionOnServer
        ) {
        case .eligible(let eligibleTarget):
            onEligibleTarget(eligibleTarget)
        case .skipped(let reason):
            traceSkipped(candidate: candidate, reason: reason.rawValue)
        }
    }

    private func traceSkipped(
        candidate: RemuxLibrarySSHPrewarmCandidate,
        reason: String
    ) {
        GhosttyRuntimeTrace.latency(
            "library.prewarm skipped reason=\(reason) serverID=\(candidate.server.id.uuidString) workspaceID=\(candidate.workspace.id.uuidString)"
        )
    }
}
