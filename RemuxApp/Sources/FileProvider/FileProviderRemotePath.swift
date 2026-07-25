import FileProvider
import Foundation

enum FileProviderRemotePathError: Error, Equatable {
    case invalidRelativePath
    case invalidCanonicalPath
    case invalidItemIdentifier
    case unsafeLinkTarget
}

struct FileProviderRemotePath: Hashable, Codable, Sendable {
    static let root = FileProviderRemotePath(validatedRelative: "")

    let relative: String

    init(relative: String) throws {
        guard !relative.contains("\0"), !relative.hasPrefix("/") else {
            throw FileProviderRemotePathError.invalidRelativePath
        }

        var components: [Substring] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                throw FileProviderRemotePathError.invalidRelativePath
            default:
                components.append(component)
            }
        }

        self.init(validatedRelative: components.joined(separator: "/"))
    }

    func remotePath(beneath canonicalHome: String) throws -> String {
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalHome)

        guard !relative.isEmpty else { return canonicalHome }
        guard canonicalHome != "/" else { return "/\(relative)" }
        return "\(canonicalHome)/\(relative)"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(relative: container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(relative)
    }

    private init(validatedRelative: String) {
        self.relative = validatedRelative
    }
}

struct FileProviderItemIdentifierCodec: Sendable {
    private static let itemPrefix = "i:"

    func identifier(
        for identity: FileProviderItemIdentity
    ) -> NSFileProviderItemIdentifier {
        switch identity {
        case .root:
            return .rootContainer
        case .item(let id):
            return NSFileProviderItemIdentifier(
                rawValue: Self.itemPrefix + id.uuidString.lowercased()
            )
        }
    }

    func identity(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderItemIdentity {
        guard identifier != .rootContainer else { return .root }
        let raw = identifier.rawValue
        guard raw.hasPrefix(Self.itemPrefix),
              let id = UUID(uuidString: String(raw.dropFirst(2)))
        else {
            throw FileProviderRemotePathError.invalidItemIdentifier
        }
        return .item(id)
    }
}

enum FileProviderPathValidation {
    static func validateCanonicalAbsolute(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw FileProviderRemotePathError.invalidCanonicalPath
        }

        guard path != "/" else { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "",
              components.dropFirst().allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
              })
        else {
            throw FileProviderRemotePathError.invalidCanonicalPath
        }
    }
}
