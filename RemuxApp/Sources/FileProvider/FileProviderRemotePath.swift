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
    private static let pathPrefix = "p:"

    func identifier(for path: FileProviderRemotePath) -> NSFileProviderItemIdentifier {
        guard path != .root else { return .rootContainer }

        let encoded = Data(path.relative.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier(rawValue: Self.pathPrefix + encoded)
    }

    func path(for identifier: NSFileProviderItemIdentifier) throws -> FileProviderRemotePath {
        guard identifier == .rootContainer else {
            let rawValue = identifier.rawValue
            guard rawValue.hasPrefix(Self.pathPrefix) else {
                throw FileProviderRemotePathError.invalidItemIdentifier
            }

            let encoded = String(rawValue.dropFirst(Self.pathPrefix.count))
            guard !encoded.isEmpty,
                  encoded.unicodeScalars.allSatisfy(Self.isURLSafeBase64Scalar)
            else {
                throw FileProviderRemotePathError.invalidItemIdentifier
            }

            let standardBase64 = encoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let paddingLength = (4 - standardBase64.count % 4) % 4
            let paddedBase64 = standardBase64 + String(repeating: "=", count: paddingLength)
            guard let data = Data(base64Encoded: paddedBase64),
                  let relative = String(data: data, encoding: .utf8)
            else {
                throw FileProviderRemotePathError.invalidItemIdentifier
            }

            let path: FileProviderRemotePath
            do {
                path = try FileProviderRemotePath(relative: relative)
            } catch {
                throw FileProviderRemotePathError.invalidItemIdentifier
            }

            guard path != .root, self.identifier(for: path) == identifier else {
                throw FileProviderRemotePathError.invalidItemIdentifier
            }
            return path
        }

        return .root
    }

    private static func isURLSafeBase64Scalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
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
