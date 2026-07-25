@preconcurrency import Citadel
import FileProvider
import Foundation
import NIOCore
import NIOPosix

enum FileProviderErrorMapper {
    static func map(_ error: Error) -> NSError {
        if case .noSuchFile = error as? RemuxSFTPClientError {
            return sanitizedError()
        }
        return map(error, itemIdentifier: nil)
    }

    static func map(
        _ error: Error,
        itemIdentifier: NSFileProviderItemIdentifier
    ) -> NSError {
        map(error, itemIdentifier: Optional(itemIdentifier))
    }

    private static func map(
        _ error: Error,
        itemIdentifier: NSFileProviderItemIdentifier?
    ) -> NSError {
        if error is CancellationError {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }

        if error is SSHAuthResolverError || error is TrustedHostStoreError {
            return fileProviderError(.notAuthenticated)
        }

        if let sshClientError = error as? SSHClientError {
            switch sshClientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication:
                return fileProviderError(.notAuthenticated)
            case .unsupportedHostBasedAuthentication, .channelCreationFailed:
                break
            }
        }

        if let snapshotError = error as? FileProviderSnapshotStoreError {
            if case .syncAnchorExpired = snapshotError {
                return fileProviderError(.syncAnchorExpired)
            }
            if case .itemIdentityNotFound = snapshotError,
               let itemIdentifier
            {
                return NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.noSuchItem.rawValue,
                    userInfo: [
                        NSFileProviderErrorNonExistentItemIdentifierKey: itemIdentifier,
                    ]
                )
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

        if error is NIOConnectionError || isNetworkChannelError(error) || isNetworkURL(error) {
            return fileProviderError(.serverUnreachable)
        }

        return sanitizedError()
    }

    static var writePermission: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }

    private static func fileProviderError(_ code: NSFileProviderError.Code) -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }

    private static func sanitizedError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid)
    }

    private static func isNetworkChannelError(_ error: Error) -> Bool {
        guard let error = error as? ChannelError else { return false }

        switch error {
        case .connectTimeout,
             .eof,
             .ioOnClosedChannel,
             .alreadyClosed,
             .inputClosed,
             .outputClosed:
            return true
        default:
            return false
        }
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
