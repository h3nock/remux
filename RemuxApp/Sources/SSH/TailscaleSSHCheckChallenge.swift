import Foundation

struct TailscaleSSHCheckChallenge: Equatable, Sendable {
    let verificationURL: URL

    static func parse(from banner: String) -> Self? {
        guard let range = banner.range(
            of: #"https://login\.tailscale\.com/a/[A-Za-z0-9]+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let candidate = String(banner[range])
        guard let components = URLComponents(string: candidate),
              components.scheme == "https",
              components.host?.lowercased() == "login.tailscale.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let pathComponents = components.path.split(separator: "/")
        guard pathComponents.count == 2,
              pathComponents[0] == "a",
              !pathComponents[1].isEmpty,
              let verificationURL = components.url else {
            return nil
        }

        return Self(verificationURL: verificationURL)
    }
}

struct TailscaleSSHCheckRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let challenge: TailscaleSSHCheckChallenge
}

enum TailscaleSSHCheckEvent: Equatable, Sendable {
    case presented(TailscaleSSHCheckRequest)
    case finished(TailscaleSSHCheckRequest.ID)
}

final class TailscaleSSHCheckChallengeBroker: Sendable {
    let events: AsyncStream<TailscaleSSHCheckEvent>
    private let continuation: AsyncStream<TailscaleSSHCheckEvent>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: TailscaleSSHCheckEvent.self)
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func handle(_ event: TailscaleSSHCheckEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}

enum TailscaleSSHCheckError: LocalizedError, Equatable, Sendable {
    case verificationTimedOut

    var errorDescription: String? {
        switch self {
        case .verificationTimedOut:
            "Tailscale SSH verification expired before it was completed. Try connecting again to get a new verification link."
        }
    }
}
