@preconcurrency import Citadel
import Foundation
import NIOCore
import UIKit

enum RemuxConnectionTimeouts {
    static let terminalSSHConnect: TimeAmount = .seconds(10)
    static let tailscaleSSHAuthentication: TimeAmount = .minutes(5)
    static let publicKeyInstallSSHConnect: TimeAmount = .seconds(10)
    static let tmuxControlNoResponse: TimeAmount = .seconds(15)
    static let sftpSSHConnect: TimeAmount = .seconds(15)
    static let sftpOperation: TimeAmount = .seconds(15)
}

enum SSHAccessVerificationError: Error, Equatable, LocalizedError {
    case commandFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            "The server accepted the login but couldn't run a command (exit status \(status))."
        }
    }
}

struct RemuxAppDependencies: Sendable {
    private struct TailscaleSSHCheckConfiguration {
        let authenticationTimeout: TimeAmount
        let onEvent: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
    }

    let profileRepository: any ConnectionProfileRepository
    let settingsRepository: any TerminalSettingsRepository
    let shortcutRepository: any ShortcutRepository
    let credentialStore: any SSHCredentialStore
    let trustedHostStore: TrustedHostStore
    let publicKeyInstaller: SSHPublicKeyInstaller
    /// The zooms Remux made on Herdr servers, which a session's end takes off, kept by one session model at
    /// a time.
    let herdrZoomKeepers: HerdrZoomKeepers
    private let sshRootService: RemuxSSHRootService
    private let transportFactory: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) -> any TmuxControlTransport
    private let sshConnectionPrewarmer: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async -> Void
    private let attachmentTransferServiceFactory: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) -> any GhosttyAttachmentTransferService
    private let tmuxSessionDiscoverer: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async throws -> SessionListing
    private let herdrSessionDiscoverer: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async throws -> SessionListing
    private let sshAccessVerifier: @Sendable (
        _ target: SessionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async throws -> Void
    private let herdrBridgeOpener: @Sendable (
        _ target: SessionTarget,
        _ kind: HerdrBridgeKind,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async throws -> any HerdrBridgeTransport
    private let debugConnectionSeeder: @Sendable (
        _ profileRepository: any ConnectionProfileRepository,
        _ credentialStore: any SSHCredentialStore
    ) async throws -> Bool

    init(
        profileRepository: any ConnectionProfileRepository,
        settingsRepository: any TerminalSettingsRepository,
        shortcutRepository: any ShortcutRepository,
        credentialStore: any SSHCredentialStore,
        trustedHostStore: TrustedHostStore,
        publicKeyInstaller: SSHPublicKeyInstaller,
        herdrOwnedZoomStore: any HerdrOwnedZoomStore = InMemoryHerdrOwnedZoomStore(),
        sshRootService: RemuxSSHRootService = RemuxSSHRootService(),
        transportFactory: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) -> any TmuxControlTransport = RemuxAppDependencies.liveTransport,
        sshConnectionPrewarmer: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async -> Void = RemuxAppDependencies.liveSSHConnectionPrewarmer,
        attachmentTransferServiceFactory: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) -> any GhosttyAttachmentTransferService = RemuxAppDependencies.liveAttachmentTransferService,
        tmuxSessionDiscoverer: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async throws -> SessionListing = RemuxAppDependencies.liveTmuxSessionDiscoverer,
        herdrSessionDiscoverer: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async throws -> SessionListing = RemuxAppDependencies.liveHerdrSessionDiscoverer,
        sshAccessVerifier: @escaping @Sendable (
            _ target: SessionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async throws -> Void = RemuxAppDependencies.liveSSHAccessVerifier,
        herdrBridgeOpener: @escaping @Sendable (
            _ target: SessionTarget,
            _ kind: HerdrBridgeKind,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async throws -> any HerdrBridgeTransport = RemuxAppDependencies.liveHerdrBridgeOpener,
        debugConnectionSeeder: @escaping @Sendable (
            _ profileRepository: any ConnectionProfileRepository,
            _ credentialStore: any SSHCredentialStore
        ) async throws -> Bool = RemuxAppDependencies.liveDebugConnectionSeeder
    ) {
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.shortcutRepository = shortcutRepository
        self.credentialStore = credentialStore
        self.trustedHostStore = trustedHostStore
        self.publicKeyInstaller = publicKeyInstaller
        self.herdrZoomKeepers = HerdrZoomKeepers(store: herdrOwnedZoomStore)
        self.sshRootService = sshRootService
        self.transportFactory = transportFactory
        self.sshConnectionPrewarmer = sshConnectionPrewarmer
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
        self.tmuxSessionDiscoverer = tmuxSessionDiscoverer
        self.herdrSessionDiscoverer = herdrSessionDiscoverer
        self.sshAccessVerifier = sshAccessVerifier
        self.herdrBridgeOpener = herdrBridgeOpener
        self.debugConnectionSeeder = debugConnectionSeeder
    }

    @MainActor
    static func launch() -> Result<RemuxAppDependencies, Error> {
        Result {
#if DEBUG || REMUX_LIVE_UI_TESTING
            if ProcessInfo.processInfo.environment["REMUX_UI_TESTING"] == "1" {
                return try uiTesting()
            }
#endif
            return try live()
        }
    }

    @MainActor
    static func live() throws -> RemuxAppDependencies {
#if DEBUG || REMUX_LIVE_UI_TESTING
        let environment = ProcessInfo.processInfo.environment
        let usesEphemeralDebugStorage = environment[DebugLiveEnvironmentKey.ephemeralStorage] == "1"
        let root: URL
        let credentialStore: any SSHCredentialStore
        if usesEphemeralDebugStorage {
            root = try ApplicationStorage.remuxRoot(
                overridePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RemuxLiveDebug-\(UUID().uuidString)", isDirectory: true)
                    .path
            )
            credentialStore = InMemorySSHCredentialStore()
        } else {
            root = try ApplicationStorage.remuxRoot()
            credentialStore = KeychainSSHCredentialStore()
        }
#else
        let root = try ApplicationStorage.remuxRoot()
        let credentialStore: any SSHCredentialStore = KeychainSSHCredentialStore()
#endif
        let trustedHostStore = TrustedHostStore(rootURL: root)
        return RemuxAppDependencies(
            profileRepository: FileBackedConnectionProfileRepository(rootURL: root),
            settingsRepository: FileBackedTerminalSettingsRepository(
                rootURL: root,
                defaultZoomMultipaneWindows: deviceDefaultZoomMultipaneWindows
            ),
            shortcutRepository: FileBackedShortcutRepository(rootURL: root),
            credentialStore: credentialStore,
            trustedHostStore: trustedHostStore,
            publicKeyInstaller: try SSHPublicKeyInstaller(
                trustedHostStore: trustedHostStore
            ),
            herdrOwnedZoomStore: FileBackedHerdrOwnedZoomStore(rootURL: root)
        )
    }

    @MainActor
    private static var deviceDefaultZoomMultipaneWindows: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Applies the user's host-key policy. Enabling registers legacy `ssh-rsa`
    /// host-key support process-wide (see `RemuxSSHAlgorithmRegistration`).
    /// NIOSSH keeps a registration for the life of the process, so disabling
    /// takes effect at the next launch.
    func applyHostKeyPolicy(allowInsecureRSA: Bool) {
        if allowInsecureRSA {
            RemuxSSHAlgorithmRegistration.ensureRegistered()
        }
    }

    func makeTransport(for target: SessionTarget) -> any TmuxControlTransport {
        transportFactory(target, trustedHostStore, sshRootService)
    }

    var tailscaleSSHCheckEvents: AsyncStream<TailscaleSSHCheckEvent> {
        sshRootService.tailscaleSSHCheckChallengeBroker.events
    }

    func prewarmSSHConnection(for target: SessionTarget) async {
        await sshConnectionPrewarmer(target, trustedHostStore, sshRootService)
    }

    func makeAttachmentTransferService(for target: SessionTarget) -> any GhosttyAttachmentTransferService {
        attachmentTransferServiceFactory(target, trustedHostStore, sshRootService)
    }

    func discoverTmuxSessions(for target: SessionTarget) async throws -> SessionListing {
        try await tmuxSessionDiscoverer(target, trustedHostStore, sshRootService)
    }

    func discoverHerdrSessions(for target: SessionTarget) async throws -> SessionListing {
        try await herdrSessionDiscoverer(target, trustedHostStore, sshRootService)
    }

    /// Checks that Remux can sign in to the server and run a command, without
    /// requiring tmux or any other multiplexer there.
    func verifySSHAccess(for target: SessionTarget) async throws {
        try await sshAccessVerifier(target, trustedHostStore, sshRootService)
    }

    /// Opens a bridge of `kind` to the target's Herdr session.
    func openHerdrBridge(for target: SessionTarget, kind: HerdrBridgeKind) async throws -> any HerdrBridgeTransport {
        try await herdrBridgeOpener(target, kind, trustedHostStore, sshRootService)
    }

    func closeIdleSSHConnections(forServerID serverID: SavedServer.ID) {
        Task {
            await sshRootService.closeIdleConnections(forServerID: serverID)
        }
    }

    private static func liveTransport(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) -> any TmuxControlTransport {
        SSHTmuxControlTransport(
            configuration: sshConfiguration(
                for: target,
                trustedHostStore: trustedHostStore,
                tailscaleSSHCheckChallengeBroker: sshRootService.tailscaleSSHCheckChallengeBroker,
                traceFlowID: "session.open.\(target.workspace.id.uuidString)"
            ),
            sshRootService: sshRootService
        )
    }

    private static func liveSSHConnectionPrewarmer(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async {
        guard target.sshAuth.credential != .none else {
            return
        }

        let trace = RemuxTransportStartupTrace(flowID: nil)
        let configuration = sshConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: sshRootService.tailscaleSSHCheckChallengeBroker,
            traceFlowID: nil
        )
        guard let rootKey = configuration.sshRootKey else { return }

        await sshRootService.prewarmConnection(
            for: rootKey,
            configuration: configuration.sshRootConfiguration,
            trace: trace,
            reason: "library"
        )
    }

    static func sshConfiguration(
        for target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        tailscaleSSHCheckChallengeBroker: TailscaleSSHCheckChallengeBroker? = nil,
        traceFlowID: String?
    ) -> SSHTmuxControlConfiguration {
        let tailscaleSSHCheck = tailscaleSSHCheckConfiguration(
            credential: target.sshAuth.credential,
            broker: tailscaleSSHCheckChallengeBroker
        )
        return SSHTmuxControlConfiguration(
            host: target.server.host,
            port: target.server.port,
            authenticationMethod: {
                try SSHAuthenticationMethodFactory.make(
                    username: target.sshAuth.username,
                    credential: target.sshAuth.credential
                )
            },
            hostKeyValidator: trustedHostStore.validator(for: target.server),
            connectTimeout: RemuxConnectionTimeouts.terminalSSHConnect,
            authenticationTimeout: tailscaleSSHCheck?.authenticationTimeout,
            onTailscaleSSHCheck: tailscaleSSHCheck?.onEvent,
            controlNoResponseTimeout: RemuxConnectionTimeouts.tmuxControlNoResponse,
            tmuxExecutable: target.server.tmuxExecutablePath ?? "tmux",
            sessionName: target.workspace.sessionName,
            sessionOpening: target.opening,
            traceFlowID: traceFlowID,
            sshRootKey: RemuxSSHRootKey(target: target)
        )
    }

    static func attachmentSSHRootConfiguration(
        for target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        tailscaleSSHCheckChallengeBroker: TailscaleSSHCheckChallengeBroker? = nil
    ) -> RemuxSSHRootConfiguration {
        sshRootConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: tailscaleSSHCheckChallengeBroker,
            connectTimeout: RemuxConnectionTimeouts.sftpSSHConnect
        )
    }

    private static func liveAttachmentTransferService(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) -> any GhosttyAttachmentTransferService {
        let rootConfiguration = attachmentSSHRootConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: sshRootService.tailscaleSSHCheckChallengeBroker
        )
        let provider = RemuxCitadelSFTPClientProvider(
            sshRootService: sshRootService,
            rootKey: RemuxSSHRootKey(target: target),
            rootConfiguration: rootConfiguration,
            operationTimeout: RemuxConnectionTimeouts.sftpOperation
        )
        return GhosttyAttachmentSFTPClientProviderTransferService(provider: provider)
    }

    private static func liveTmuxSessionDiscoverer(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async throws -> SessionListing {
        try await withClaimedSSHRoot(
            for: target,
            trustedHostStore: trustedHostStore,
            sshRootService: sshRootService
        ) { claimedRoot, configuration, trace in
            try await TmuxSessionDiscovery.discover(
                using: claimedRoot,
                tmuxExecutable: configuration.tmuxExecutable,
                trace: trace
            )
        }
    }

    private static func liveHerdrSessionDiscoverer(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async throws -> SessionListing {
        try await withClaimedSSHRoot(
            for: target,
            trustedHostStore: trustedHostStore,
            sshRootService: sshRootService
        ) { claimedRoot, _, trace in
            try await HerdrSessionDiscovery.discover(
                using: claimedRoot,
                herdrExecutable: target.server.herdrExecutablePath ?? "herdr",
                trace: trace
            )
        }
    }

    private static func liveSSHAccessVerifier(
        target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async throws {
        try await withClaimedSSHRoot(
            for: target,
            trustedHostStore: trustedHostStore,
            sshRootService: sshRootService
        ) { claimedRoot, _, trace in
            let result = try await RemuxSSHExecSession.run(
                using: claimedRoot,
                command: "exit 0",
                stdin: nil,
                trace: trace
            )
            guard result.exitStatus == 0 else {
                throw SSHAccessVerificationError.commandFailed(status: result.exitStatus)
            }
        }
    }

    /// Claims the server's pooled SSH connection, as a tmux session does, and runs the bridge on it; the
    /// bridge gives the connection back when it closes. An opening cancelled before the bridge runs gives
    /// it back at once.
    private static func liveHerdrBridgeOpener(
        target: SessionTarget,
        kind: HerdrBridgeKind,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async throws -> any HerdrBridgeTransport {
        let trace = RemuxTransportStartupTrace(flowID: "session.open.\(target.workspace.id.uuidString)")
        let preparedRoot = await sshRootService.preparedRoot(
            for: RemuxSSHRootKey(target: target),
            configuration: sshRootConfiguration(
                for: target,
                trustedHostStore: trustedHostStore,
                tailscaleSSHCheckChallengeBroker: sshRootService.tailscaleSSHCheckChallengeBroker,
                connectTimeout: RemuxConnectionTimeouts.terminalSSHConnect
            ),
            trace: trace
        )
        let claimedRoot: RemuxSSHClaimedRoot
        do {
            let sshRoot = try await trace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
            try Task.checkCancellation()
            claimedRoot = try await preparedRoot.claim(sshRoot, trace: trace)
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }
        guard !Task.isCancelled else {
            await claimedRoot.release(.reusable)
            throw CancellationError()
        }
        return try await HerdrSSHBridge.open(
            using: claimedRoot,
            herdrExecutable: target.server.herdrExecutablePath ?? "herdr",
            session: target.workspace.sessionName,
            kind: kind,
            trace: trace
        )
    }

    /// Connects, verifies the host key and authenticates through a prepared
    /// SSH root, runs `operation` on the claimed root, then releases it.
    private static func withClaimedSSHRoot<Result>(
        for target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService,
        operation: (
            RemuxSSHClaimedRoot,
            SSHTmuxControlConfiguration,
            RemuxTransportStartupTrace
        ) async throws -> Result
    ) async throws -> Result {
        let trace = RemuxTransportStartupTrace(
            flowID: "session.discovery.\(target.server.id.uuidString)"
        )
        let configuration = sshConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            tailscaleSSHCheckChallengeBroker: sshRootService.tailscaleSSHCheckChallengeBroker,
            traceFlowID: nil
        )
        guard let rootKey = configuration.sshRootKey else {
            preconditionFailure("Server exec requires an SSH root key")
        }

        let preparedRoot = await sshRootService.preparedRoot(
            for: rootKey,
            configuration: configuration.sshRootConfiguration,
            trace: trace
        )
        do {
            let sshRoot = try await preparedRoot.sshRoot()
            let claimedRoot = try await preparedRoot.claim(sshRoot, trace: trace)
            let result = try await operation(claimedRoot, configuration, trace)
            await preparedRoot.cancelAndCleanup()
            return result
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }
    }

    private static func sshRootConfiguration(
        for target: SessionTarget,
        trustedHostStore: TrustedHostStore,
        tailscaleSSHCheckChallengeBroker: TailscaleSSHCheckChallengeBroker?,
        connectTimeout: TimeAmount
    ) -> RemuxSSHRootConfiguration {
        let tailscaleSSHCheck = tailscaleSSHCheckConfiguration(
            credential: target.sshAuth.credential,
            broker: tailscaleSSHCheckChallengeBroker
        )
        return RemuxSSHRootConfiguration(
            host: target.server.host,
            port: target.server.port,
            authenticationMethod: {
                try SSHAuthenticationMethodFactory.make(
                    username: target.sshAuth.username,
                    credential: target.sshAuth.credential
                )
            },
            hostKeyValidator: trustedHostStore.validator(for: target.server),
            connectTimeout: connectTimeout,
            authenticationTimeout: tailscaleSSHCheck?.authenticationTimeout,
            onTailscaleSSHCheck: tailscaleSSHCheck?.onEvent
        )
    }

    private static func tailscaleSSHCheckConfiguration(
        credential: ResolvedSSHAuth.Credential,
        broker: TailscaleSSHCheckChallengeBroker?
    ) -> TailscaleSSHCheckConfiguration? {
        guard credential == .none else { return nil }

        let onEvent: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
        if let broker {
            onEvent = { event in
                broker.handle(event)
            }
        } else {
            onEvent = nil
        }

        return TailscaleSSHCheckConfiguration(
            authenticationTimeout: RemuxConnectionTimeouts.tailscaleSSHAuthentication,
            onEvent: onEvent
        )
    }

#if DEBUG || REMUX_LIVE_UI_TESTING
    private enum DebugLiveEnvironmentKey {
        static let ephemeralStorage = "REMUX_DEBUG_EPHEMERAL_STORAGE"
    }

    private enum DebugPublicKeyInstallOutcome: String {
        case passwordRequired
        case alreadyInstalled
    }

    private actor DebugPublicKeyInstallState {
        let requiresPassword: Bool
        var didAppend = false

        init(requiresPassword: Bool) {
            self.requiresPassword = requiresPassword
        }

        func run(
            credential: SSHCredential
        ) throws -> RemuxSSHExecResult {
            switch credential {
            case .password:
                didAppend = true
            case .privateKey:
                if requiresPassword, !didAppend {
                    throw SSHClientError.allAuthenticationOptionsFailed
                }
            }

            return RemuxSSHExecResult(
                exitStatus: 0,
                stdout: Data(),
                stderr: Data()
            )
        }
    }

    @MainActor
    static func uiTesting() throws -> RemuxAppDependencies {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxUITesting", isDirectory: true)
        let trustedHostStore = TrustedHostStore(rootURL: root)
        let publicKeyInstallOutcome = ProcessInfo.processInfo.environment[
            "REMUX_UI_TEST_PUBLIC_KEY_INSTALL_OUTCOME"
        ].flatMap(DebugPublicKeyInstallOutcome.init(rawValue:)) ?? .alreadyInstalled
        let publicKeyInstallState = DebugPublicKeyInstallState(
            requiresPassword: publicKeyInstallOutcome == .passwordRequired
        )
        let tailscaleSSHCheckChallenge = ProcessInfo.processInfo.environment[
            "REMUX_UI_TEST_TAILSCALE_CHECK_BANNER"
        ].flatMap(TailscaleSSHCheckChallenge.parse(from:))
        let simulatesMissingTmux = ProcessInfo.processInfo.environment[
            "REMUX_UI_TEST_TMUX_MISSING"
        ] == "1"

        return RemuxAppDependencies(
            profileRepository: InMemoryConnectionProfileRepository(),
            settingsRepository: InMemoryTerminalSettingsRepository(
                settings: {
                    var settings = TerminalSettings.default
                    settings.zoomMultipaneWindowsByDefault = deviceDefaultZoomMultipaneWindows
                    return settings
                }()
            ),
            shortcutRepository: InMemoryShortcutRepository(),
            credentialStore: InMemorySSHCredentialStore(),
            trustedHostStore: trustedHostStore,
            publicKeyInstaller: SSHPublicKeyInstaller(
                installationCommand: "exit 0",
                commandRunner: { _, credential, _, _ in
                    try await publicKeyInstallState.run(credential: credential)
                }
            ),
            transportFactory: { _, _, _ in
                DeterministicTmuxControlTransport(
                    chunks: uiTestingTransportChunks()
                )
            },
            sshConnectionPrewarmer: { _, _, _ in
            },
            // UI tests reach no real server: discovery and verification
            // answer like a server that signs in and whose tmux has only the
            // seeded session, if any.
            tmuxSessionDiscoverer: { target, _, sshRootService in
                if target.sshAuth.credential == .none, let tailscaleSSHCheckChallenge {
                    try await simulateTailscaleSSHCheck(
                        tailscaleSSHCheckChallenge,
                        sshRootService: sshRootService
                    )
                    return uiTestingTmuxListing(sessionNames: [])
                }
                if simulatesMissingTmux {
                    throw RemoteProgramFailure.notFound
                }
                return uiTestingTmuxListing(
                    sessionNames: DebugConnectionProfileSeeder.seededSessionName().map { [$0] } ?? []
                )
            },
            herdrSessionDiscoverer: { _, _, _ in
                throw RemoteProgramFailure.notFound
            },
            sshAccessVerifier: { target, _, sshRootService in
                if target.sshAuth.credential == .none, let tailscaleSSHCheckChallenge {
                    try await simulateTailscaleSSHCheck(
                        tailscaleSSHCheckChallenge,
                        sshRootService: sshRootService
                    )
                }
            },
            // The simulated server has no Herdr, as its discovery reports. Like the live bridge, the channel
            // opens and its first read reports it.
            herdrBridgeOpener: { _, _, _, _ in
                UITestingMissingHerdrBridge()
            }
        )
    }

    private static func uiTestingTmuxListing(sessionNames: [String]) -> SessionListing {
        SessionListing(
            executablePath: "/usr/bin/tmux",
            sessions: sessionNames.map { DiscoveredSession(name: $0, isRunning: true) }
        )
    }

    private struct UITestingMissingHerdrBridge: HerdrBridgeTransport {
        func read() async throws -> [UInt8]? {
            throw HerdrBridgeError.program(.notFound)
        }

        func write(_ bytes: [UInt8]) async throws {}

        func close(_ cause: HerdrBridgeCloseCause) async {}
    }

    /// Presents `challenge` as the server's Tailscale SSH check and waits
    /// until the user cancels it.
    private static func simulateTailscaleSSHCheck(
        _ challenge: TailscaleSSHCheckChallenge,
        sshRootService: RemuxSSHRootService
    ) async throws {
        let suspension = AsyncThrowingStream.makeStream(of: Void.self)
        let request = TailscaleSSHCheckRequest(
            id: UUID(),
            challenge: challenge,
            cancel: {
                suspension.continuation.finish(throwing: CancellationError())
            }
        )
        sshRootService.tailscaleSSHCheckChallengeBroker.handle(.presented(request))
        defer {
            sshRootService.tailscaleSSHCheckChallengeBroker.handle(.finished(request.id))
            suspension.continuation.finish()
        }
        for try await _ in suspension.stream {
        }
    }

    private static func uiTestingTransportChunks() -> [Data] {
        guard ProcessInfo.processInfo.environment["REMUX_UI_TEST_INPUT_READY"] == "1" else {
            return []
        }

        // Answers GhosttyKit's `list-panes -s -F` request. The line needs every
        // field of that format, through pane_current_command and
        // pane_current_path, or the client rejects the attach.
        let paneState = "%0;83;44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;43;8,16;zsh;/home/demo\n"
        let window = "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 window-0\n"
        let transcript = "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n"
            + "%begin 2 2 1\n3.1\n%end 2 2 1\n"
            + "%begin 3 3 1\n%end 3 3 1\n"
            + "%begin 4 4 1\n\(window)%end 4 4 1\n"
            + "%begin 5 5 1\n\(paneState)%end 5 5 1\n"
            + (6...9).map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }.joined()
        return [Data(transcript.utf8)]
    }
#endif

#if DEBUG || REMUX_LIVE_UI_TESTING
    @discardableResult
    func seedDebugConnectionIfRequested() async throws -> Bool {
        try await debugConnectionSeeder(profileRepository, credentialStore)
    }

    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        try await DebugConnectionProfileSeeder.seedIfRequested(
            profileRepository: profileRepository,
            credentialStore: credentialStore
        )
    }
#else
    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        false
    }
#endif
}

#if DEBUG || REMUX_LIVE_UI_TESTING
private actor InMemoryConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer] = []
    private var workspaces: [SavedWorkspace] = []
    private var identities: [SSHIdentity] = []

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let serverIDs = Set(servers.map(\.id))
        return ConnectionLibrarySnapshot(
            servers: serverOrder.isEmpty ? servers.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            } : servers,
            workspaces: workspaces.filter { serverIDs.contains($0.serverID) },
            identities: identities.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        ).orderingServers(by: serverOrder)
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServerOrder(_ ids: [SavedServer.ID]) async throws {
        serverOrder = ids
    }

    private var serverOrder: [SavedServer.ID] = []

    func saveServer(_ server: SavedServer) async throws {
        upsert(server, into: &servers)
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        upsert(workspace, into: &workspaces)
    }

    func saveIdentity(_ identity: SSHIdentity) async throws {
        upsert(identity, into: &identities)
    }

    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws {
        upsert(identity, into: &identities)
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func deleteIdentity(id: SSHIdentity.ID) async throws {
        identities.removeAll { $0.id == id }
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}

private actor InMemoryTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings: TerminalSettings

    init(settings: TerminalSettings = .default) {
        self.settings = settings
    }

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        self.settings = settings
    }
}

private actor InMemoryShortcutRepository: ShortcutRepository {
    private var snapshot: ShortcutStoreSnapshot
    private let starters: [StarterShortcut]

    init(
        snapshot: ShortcutStoreSnapshot = ShortcutStoreSnapshot(),
        starters: [StarterShortcut] = StarterShortcuts.all
    ) {
        self.snapshot = snapshot
        self.starters = starters
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        snapshot.installMissingStarters(starters)
        return snapshot
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        self.snapshot = snapshot
    }
}

private actor InMemorySSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential] = [:]

    func loadCredential(identityID: SSHIdentity.ID) async throws -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) async throws {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: SSHIdentity.ID) async throws {
        credentials.removeValue(forKey: identityID)
    }
}
#endif
