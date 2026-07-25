import FileProvider
import Foundation
import NIOCore
import NIOPosix

enum FileProviderErrorMapper {
    static func map(
        _ error: Error,
        itemIdentifier: NSFileProviderItemIdentifier? = nil
    ) -> NSError {
        if error is SSHAuthResolverError || error is TrustedHostStoreError {
            return fileProviderError(.notAuthenticated)
        }

        if let snapshotError = error as? FileProviderSnapshotStoreError {
            if case .syncAnchorExpired = snapshotError {
                return fileProviderError(.syncAnchorExpired)
            }
        }

        if let sftpError = error as? RemuxSFTPClientError {
            switch sftpError {
            case .noSuchFile:
                var userInfo: [String: Any] = [:]
                if let itemIdentifier {
                    userInfo[NSFileProviderErrorItemKey] = itemIdentifier
                }
                return NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.noSuchItem.rawValue,
                    userInfo: userInfo
                )
            case .operationTimedOut, .sessionUnavailable:
                return fileProviderError(.serverUnreachable)
            case .invalidReadLength, .oversizedReadResult:
                break
            }
        }

        if error is NIOConnectionError || isConnectTimeout(error) || isNetworkURL(error) {
            return fileProviderError(.serverUnreachable)
        }

        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid)
    }

    static var writePermission: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }

    private static func fileProviderError(_ code: NSFileProviderError.Code) -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }

    private static func isConnectTimeout(_ error: Error) -> Bool {
        guard let error = error as? ChannelError,
              case .connectTimeout = error
        else {
            return false
        }
        return true
    }

    private static func isNetworkURL(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }

        return switch error.code {
        case .badServerResponse,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            true
        default:
            false
        }
    }
}
