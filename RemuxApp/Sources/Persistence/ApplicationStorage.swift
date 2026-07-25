import Foundation

enum FileProviderSharedConfigurationError: Error, Sendable {
    case missingSharedContainer
    case missingApplicationKeychainAccessGroup
    case missingKeychainAccessGroup
}

enum FileProviderSharedConfiguration {
    static let appGroupIdentifier = "group.dev.remux"
    static let credentialService = "dev.remux.ssh-credentials"

    static func applicationKeychainAccessGroup(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> String {
        guard let value = infoDictionary["RemuxApplicationKeychainAccessGroup"] as? String,
              !value.isEmpty else {
            throw FileProviderSharedConfigurationError.missingApplicationKeychainAccessGroup
        }
        return value
    }

    static func keychainAccessGroup(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> String {
        guard let value = infoDictionary["RemuxSharedKeychainAccessGroup"] as? String,
              !value.isEmpty else {
            throw FileProviderSharedConfigurationError.missingKeychainAccessGroup
        }
        return value
    }
}

enum ApplicationStorage {
    static func remuxRoot(
        overridePath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root: URL
        if let overridePath {
            root = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            root = try fileManager
                .url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("Remux", isDirectory: true)
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func sharedRemuxRoot(
        appGroupIdentifier: String = FileProviderSharedConfiguration.appGroupIdentifier,
        fileManager: FileManager = .default,
        containerURL: @Sendable (String) -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: $0
            )
        }
    ) throws -> URL {
        guard let containerURL = containerURL(appGroupIdentifier) else {
            throw FileProviderSharedConfigurationError.missingSharedContainer
        }

        return containerURL.appendingPathComponent("Remux", isDirectory: true)
    }
}
