import Foundation
import NIOCore

struct FileProviderCitadelSFTPClientProvider: FileProviderSFTPClientProviding {
    private let sshRootService: RemuxSSHRootService
    private let trustedHosts: TrustedHostStore
    private let connectTimeout: TimeAmount
    private let operationTimeout: TimeAmount

    init(
        sshRootService: RemuxSSHRootService,
        trustedHosts: TrustedHostStore,
        connectTimeout: TimeAmount = .seconds(15),
        operationTimeout: TimeAmount = .seconds(15)
    ) {
        self.sshRootService = sshRootService
        self.trustedHosts = trustedHosts
        self.connectTimeout = connectTimeout
        self.operationTimeout = operationTimeout
    }

    func withClient<Value: Sendable>(
        server: SavedServer,
        authentication: ResolvedSSHAuth,
        operation: @Sendable (any RemuxSFTPFileProviderClient) async throws -> Value
    ) async throws -> Value {
        let provider = RemuxCitadelSFTPClientProvider(
            sshRootService: sshRootService,
            rootKey: RemuxSSHRootKey(server: server, auth: authentication),
            rootConfiguration: RemuxSSHRootConfiguration(
                host: server.host,
                port: server.port,
                authenticationMethod: {
                    try RemuxSSHAuthenticationMethodFactory.make(for: authentication)
                },
                hostKeyValidator: trustedHosts.validator(for: server),
                connectTimeout: connectTimeout
            ),
            operationTimeout: operationTimeout
        )

        return try await provider.withClient { client in
            try await operation(client)
        }
    }

    func closeIdleConnections(forServerID serverID: SavedServer.ID) async {
        await sshRootService.closeIdleConnections(forServerID: serverID)
    }
}
