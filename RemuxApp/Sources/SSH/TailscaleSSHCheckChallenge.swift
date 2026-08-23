import Foundation

struct TailscaleSSHCheckChallenge: Equatable, Identifiable, Sendable {
    let verificationURL: URL

    var id: URL {
        verificationURL
    }

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

final class TailscaleSSHCheckChallengeBroker: @unchecked Sendable {
    let challenges: AsyncStream<TailscaleSSHCheckChallenge>
    private let continuation: AsyncStream<TailscaleSSHCheckChallenge>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: TailscaleSSHCheckChallenge.self)
        self.challenges = stream.stream
        self.continuation = stream.continuation
    }

    func present(_ challenge: TailscaleSSHCheckChallenge) {
        continuation.yield(challenge)
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
            "Tailscale SSH verification was not completed. Open the verification link and try again."
        }
    }
}
