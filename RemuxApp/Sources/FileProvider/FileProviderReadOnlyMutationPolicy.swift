import Foundation

enum FileProviderReadOnlyMutationPolicy {
    static let rejection = FileProviderErrorMapper.writePermission
}
