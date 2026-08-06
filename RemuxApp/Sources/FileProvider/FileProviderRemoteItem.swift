import CryptoKit
import Foundation

struct FileProviderRemoteItem: Equatable, Codable, Sendable {
    let path: FileProviderRemotePath
    let parent: FileProviderRemotePath
    let name: String
    let type: RemuxSFTPFileType
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?
    let symlinkTargetRelativePath: String?

    var contentVersion: Data {
        var data = Data()
        data.appendString(type.rawValue)
        data.appendOptional(size)
        data.appendOptional(modificationDate.map { Int64($0.timeIntervalSince1970) })
        return data
    }

    var metadataVersion: Data {
        var data = contentVersion
        data.appendString(path.relative)
        data.appendString(name)
        data.appendOptional(permissions)
        return Data(SHA256.hash(data: data))
    }

    init(
        path: FileProviderRemotePath,
        metadata: RemuxSFTPFileMetadata,
        symlinkTargetRelativePath: String? = nil
    ) throws {
        let parent = try Self.parent(of: path)
        self.path = path
        self.parent = parent
        self.name = path.relative.split(separator: "/").last.map(String.init) ?? ""
        self.type = metadata.type
        self.size = metadata.size
        self.permissions = metadata.permissions
        self.modificationDate = metadata.modificationDate
        self.symlinkTargetRelativePath = try symlinkTargetRelativePath.map {
            try Self.validatedSymlinkTarget($0, relativeTo: parent)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(FileProviderRemotePath.self, forKey: .path)
        let metadata = RemuxSFTPFileMetadata(
            size: try container.decodeIfPresent(UInt64.self, forKey: .size),
            permissions: try container.decodeIfPresent(UInt32.self, forKey: .permissions),
            modificationDate: try container.decodeIfPresent(Date.self, forKey: .modificationDate),
            type: try container.decode(RemuxSFTPFileType.self, forKey: .type)
        )
        self = try Self(
            path: path,
            metadata: metadata,
            symlinkTargetRelativePath: try container.decodeIfPresent(String.self, forKey: .symlinkTargetRelativePath)
        )
    }

    private static func parent(of path: FileProviderRemotePath) throws -> FileProviderRemotePath {
        guard let separator = path.relative.lastIndex(of: "/") else {
            return .root
        }
        return try FileProviderRemotePath(relative: String(path.relative[..<separator]))
    }

    private static func validatedSymlinkTarget(
        _ target: String,
        relativeTo parent: FileProviderRemotePath
    ) throws -> String {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else {
            throw FileProviderRemotePathError.invalidRelativePath
        }
        guard target != "." else { return target }

        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." }) else {
            throw FileProviderRemotePathError.invalidRelativePath
        }

        var remainingParentComponents = parent.relative.isEmpty
            ? 0
            : parent.relative.split(separator: "/").count
        var encounteredDestinationComponent = false
        for component in components {
            if component == ".." {
                guard !encounteredDestinationComponent, remainingParentComponents > 0 else {
                    throw FileProviderRemotePathError.invalidRelativePath
                }
                remainingParentComponents -= 1
            } else {
                encounteredDestinationComponent = true
            }
        }
        return target
    }
}

struct FileProviderSafeLinkResolver: Sendable {
    func resolve(
        _ canonicalTarget: String,
        home canonicalHome: String,
        for symlinkPath: FileProviderRemotePath
    ) throws -> String {
        let targetComponents = try containedTargetComponents(
            canonicalTarget,
            home: canonicalHome
        )
        var parentComponents = symlinkPath.relative.split(separator: "/").map(String.init)
        if !parentComponents.isEmpty {
            parentComponents.removeLast()
        }

        let sharedComponentCount = zip(parentComponents, targetComponents)
            .prefix { pair in pair.0 == pair.1 }
            .count
        let upwardComponents = Array(
            repeating: "..",
            count: parentComponents.count - sharedComponentCount
        )
        let downwardComponents = Array(targetComponents.dropFirst(sharedComponentCount))
        let projectedComponents = upwardComponents + downwardComponents
        return projectedComponents.isEmpty ? "." : projectedComponents.joined(separator: "/")
    }

    func ensureContained(_ canonicalTarget: String, home canonicalHome: String) throws {
        _ = try containedTargetComponents(canonicalTarget, home: canonicalHome)
    }

    private func containedTargetComponents(
        _ canonicalTarget: String,
        home canonicalHome: String
    ) throws -> [String] {
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalTarget)
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalHome)

        if canonicalHome == "/" {
            return canonicalTarget.split(separator: "/").map(String.init)
        }

        guard canonicalTarget == canonicalHome || canonicalTarget.hasPrefix(canonicalHome + "/") else {
            throw FileProviderRemotePathError.unsafeLinkTarget
        }
        guard canonicalTarget != canonicalHome else { return [] }
        return canonicalTarget.dropFirst(canonicalHome.count + 1)
            .split(separator: "/")
            .map(String.init)
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        appendInteger(UInt64(value.utf8.count))
        append(contentsOf: value.utf8)
    }

    mutating func appendOptional<T: FixedWidthInteger>(_ value: T?) {
        append(value == nil ? 0 : 1)
        if let value {
            appendInteger(value)
        }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
