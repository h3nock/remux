import Foundation
import GhosttyKit

/// Connects one `TmuxControlTransport` to one `TmuxSessionController`:
/// inbound SSH bytes feed the client on its writer queue, outbound
/// wire bytes are written to the SSH channel strictly in order (a
/// single consumer task drains an ordered stream fed from the writer
/// queue), and transport loss closes this attachment promptly.
///
/// Viewport ownership stays in the screen model. The link only passes the
/// already-known viewport to the SSH attach command's initial `-x -y`.
actor TmuxSessionLink {
    let controller: TmuxSessionController

    private let transport: any TmuxControlTransport
    private let outboundDrainTimeout: Duration
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outbound: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var transportClosed = false
    private var transportCloseDisposition = TmuxControlTransportCloseDisposition.reusable
    private var stopped = false

    init(
        controller: TmuxSessionController,
        transport: any TmuxControlTransport,
        outboundDrainTimeout: Duration = .seconds(2)
    ) {
        self.controller = controller
        self.transport = transport
        self.outboundDrainTimeout = outboundDrainTimeout

        var continuation: AsyncStream<Data>.Continuation!
        self.outbound = AsyncStream { continuation = $0 }
        self.outboundContinuation = continuation
    }

    /// Establish the control channel before creating the native client. This
    /// order prevents its initial refresh/list batch from racing transport
    /// opening; the controller reconciles any newer viewport in its startup.
    func start(viewport: TmuxControlViewport?) async throws {
        guard !stopped else { throw LinkError.stopped }
        guard let viewport else { throw LinkError.missingInitialViewport }

        // Idempotent transport prewarm (auth/root channel) before the
        // session channel opens.
        await transport.prepare()
        guard !stopped else { throw LinkError.stopped }

        // Re-target the controller's wire bytes at this link. `yield`
        // is synchronous on the writer queue, preserving order into
        // the single consumer below.
        controller.setOutboundSink { [outboundContinuation] data in
            outboundContinuation.yield(data)
        }

        // Single ordered writer for the session's wire bytes.
        writeTask = Task { [weak self, transport, outbound] in
            for await data in outbound {
                do {
                    try await transport.send(data)
                } catch {
                    await self?.invalidateTransportAfterWriteFailure()
                    break
                }
            }
        }

        try await transport.start(initialViewport: viewport)
        guard !stopped else { throw LinkError.stopped }
        try await withCheckedThrowingContinuation { continuation in
            controller.start(
                initialSize: TmuxSessionController.ClientSize(
                    cols: UInt32(viewport.columns),
                    rows: UInt32(viewport.rows)
                )
            ) { result in
                continuation.resume(with: result)
            }
        }
        guard !stopped else { throw LinkError.stopped }

        readTask = Task { [weak self, transport, controller] in
            do {
                for try await data in transport.receivedBytes {
                    controller.pump(data)
                }
            } catch {
                // Fall through: any stream end is a transport loss.
            }
            guard !Task.isCancelled else { return }
            await self?.invalidateTransportAfterReadEnd()
        }
    }

    func controlChannelIsActive() async -> Bool? {
        guard let transport = transport as? any TmuxControlTransportLivenessChecking else {
            return nil
        }
        return await transport.isControlChannelActive()
    }

    func invalidateTransport() async {
        await closeTransport(disposition: .invalidated)
        controller.transportClosed()
    }

    /// Tear this one-shot attachment down. Replacement reconnect creates a
    /// new model, controller, client, and transport.
    func stop() async {
        guard !stopped else { return }
        stopped = true

        let pendingReadTask = readTask
        let pendingWriteTask = writeTask
        self.readTask = nil
        self.writeTask = nil

        pendingReadTask?.cancel()
        _ = await pendingReadTask?.result
        await controller.finishOutbound()
        outboundContinuation.finish()
        await finishWriteTask(pendingWriteTask)
        await closeTransport(disposition: .reusable)
    }

    private func finishWriteTask(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        let timeout = outboundDrainTimeout
        let deadline = Task { [weak self, task] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await self.closeTransport(disposition: .invalidated)
            task.cancel()
        }
        _ = await task.result
        deadline.cancel()
        _ = await deadline.result
    }

    private func invalidateTransportAfterWriteFailure() async {
        await closeTransport(disposition: .invalidated)
        controller.transportClosed()
    }

    private func invalidateTransportAfterReadEnd() async {
        await closeTransport(disposition: .invalidated)
        controller.transportClosed()
    }

    private func closeTransport(disposition: TmuxControlTransportCloseDisposition) async {
        if disposition == .invalidated {
            transportCloseDisposition = .invalidated
        }
        guard !transportClosed else { return }

        transportClosed = true
        await transport.close(disposition: transportCloseDisposition)
    }
}

private enum LinkError: Error {
    case missingInitialViewport
    case stopped
}
