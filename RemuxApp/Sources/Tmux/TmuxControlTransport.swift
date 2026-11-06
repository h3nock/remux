import Foundation

protocol TmuxControlTransport: Sendable {
    var receivedBytes: AsyncThrowingStream<Data, Error> { get }

    /// Starts authentication/root transport work that does not allocate the
    /// terminal session channel and does not depend on the terminal viewport.
    /// Implementations must keep this idempotent; `start()` remains the point
    /// where the transport becomes usable and queued writes may flush.
    func prepare() async
    func start(initialViewport: TmuxControlViewport?) async throws
    func send(_ data: Data) async throws
    func close(disposition: TmuxControlTransportCloseDisposition) async
}

protocol TmuxControlTransportLivenessChecking: Sendable {
    func isControlChannelActive() async -> Bool
}

/// The control-mode command Remux sends to end its own tmux client. tmux then
/// flushes the client's pending output and closes the channel; transports that
/// emulate tmux finish their inbound stream when they see it.
enum TmuxControlClientExit {
    static let command = "detach-client"

    static func isRequested(in data: Data) -> Bool {
        data.split(separator: UInt8(ascii: "\n")).contains(Data(command.utf8))
    }
}

enum TmuxControlTransportCloseDisposition: Equatable, Sendable {
    case reusable
    case invalidated
}

extension TmuxControlTransport {
    func prepare() async {}
}
