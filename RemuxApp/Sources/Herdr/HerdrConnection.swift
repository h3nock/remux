import Foundation

/// The byte stream to a Herdr server: the bridge's stdin and stdout. Reads are pulled: the next
/// bytes are read only when the connection asks, so a screen that falls behind holds the server back
/// instead of buffering without bound.
protocol HerdrBridgeTransport: Sendable {
    /// The next bytes from the server, or nil at the end of the stream. A stream that ended badly
    /// throws its reason, with text for the user where the transport has it.
    func read() async throws -> [UInt8]?
    func write(_ bytes: [UInt8]) async throws
    /// Ends the stream at once: a pending read returns nil, and the call doesn't wait for the other
    /// side. `reusable` is false when the connection saw the path go silent, so whatever carries the
    /// stream shouldn't be reused.
    func close(reusable: Bool) async
}

/// What a connection hands to its screen, in wire order.
enum HerdrConnectionEvent: Sendable {
    case snapshot(HerdrSnapshot)
    /// For the surface decoder, which must see every surface message in order, also while hidden.
    case surface(HerdrSurfaceDecoder.Message)
    case bell(count: UInt16)
    case notification(HerdrSemanticNotification)
    /// Base64 of a program's OSC 52 clipboard write.
    case clipboard(base64: String)
    /// Herdr refused an input message (a paste over its limit); the connection stays.
    case inputRefused(message: String)
    /// The connection ended; nothing follows.
    case ended(HerdrConnectionError)
}

enum HerdrConnectionError: Error, Equatable, LocalizedError {
    /// The server rejected the hello (`unsupported_generation`, `no_common_core`, `invalid_surface`,
    /// `invalid_hello`).
    case rejected(code: String, message: String)
    case incompatible(String)
    case handshakeTimedOut
    case wire(HerdrWireError)
    case serverShutdown(reason: String?)
    case closed
    /// The stream failed; the text is for the user.
    case transport(String)
    /// No bytes arrived for a while after a health ping, or no snapshot after connecting.
    case unresponsive

    var errorDescription: String? {
        switch self {
        case .rejected(_, let message):
            return "Herdr refused the connection: \(message)"
        case .incompatible(let reason):
            return "This Herdr server isn't compatible with Remux: \(reason)."
        case .handshakeTimedOut:
            return "Herdr didn't answer."
        case .wire(let error):
            return error.errorDescription
        case .serverShutdown:
            return "The Herdr server stopped."
        case .closed:
            return "The connection to Herdr closed."
        case .transport(let detail):
            return detail
        case .unresponsive:
            return "Herdr stopped responding."
        }
    }
}

enum HerdrCommandError: Error, Equatable, LocalizedError {
    /// The server doesn't advertise the method; only this action is unavailable.
    case unsupported(method: String)
    case noSnapshot
    /// No reply in time. As in Herdr's client, the lane frees and the late reply is dropped when it
    /// comes; until the server finishes, another command may get `endpoint_busy`.
    case timedOut(method: String)
    /// `client_shell.surface.set` answered with the other state.
    case notAcknowledged
    case failed(code: String, message: String)
    case connectionEnded

    var errorDescription: String? {
        switch self {
        case .unsupported(let method):
            return "This Herdr server doesn't support \(method)."
        case .noSnapshot:
            return "Herdr hasn't sent its session yet."
        case .timedOut:
            return "Herdr didn't answer in time."
        case .notAcknowledged:
            return "Herdr didn't switch the session."
        case .failed(_, let message):
            return message
        case .connectionEnded:
            return "The connection to Herdr ended."
        }
    }
}

/// Input Remux doesn't send. Over either of Herdr's per-message limits, Herdr refuses a pure paste or
/// closes the connection.
enum HerdrInputError: Error, Equatable, LocalizedError {
    /// Herdr drops input from a client that isn't showing the session.
    case inactive
    case connectionEnded
    case tooManyEvents(Int)
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .inactive:
            return "This Herdr session isn't on screen."
        case .connectionEnded:
            return "The connection to Herdr ended."
        case .tooManyEvents:
            return "That's more input than Herdr accepts at once."
        case .tooLarge(let bytes):
            return "That's \(bytes) bytes; Herdr accepts up to 1 MiB at once."
        }
    }
}

/// One endpoint connection to a Herdr server (generation 1).
///
/// It sends Remux's hello and checks the welcome, then reads server messages in order and hands them to
/// its screen, reading again only after the screen has taken them. All writes go through one ordered
/// writer. Commands run one at a time; `client_shell.surface.set` bypasses that lane, because Herdr
/// answers it even while a command is in flight. Timings and rules follow Herdr's own client unless a
/// comment gives Remux's reason.
actor HerdrConnection {
    struct Timing: Sendable {
        /// Remux's SSH channel is open before this starts. Herdr allows 60 s because its window also
        /// covers the SSH connect; what remains here is bounded by the bridge, which gives up after 5 s
        /// if the server won't start and reads a running server's status within 0.5 s.
        var welcome: Duration = .seconds(10)
        /// Herdr's health rule: a ping after this long with nothing received, and the connection fails
        /// when nothing arrives this long after it, or when no snapshot has come this long after
        /// connecting.
        var pingAfterSilence: Duration = .seconds(5)
        var unansweredPing: Duration = .seconds(10)
        var firstSnapshot: Duration = .seconds(10)
        /// How often health is checked; adds at most this much to the rules above.
        var healthTick: Duration = .seconds(1)
        /// Herdr's command timeout.
        var command: Duration = .seconds(60)
        /// Herdr's activation timeout, for `surface.set`.
        var activation: Duration = .seconds(5)
    }

    struct Negotiated: Equatable, Sendable {
        let serverVersion: String
        let methods: Set<String>
        let delta: Bool
        let scroll: Bool
    }

    static let maxInputEvents = 4096
    static let maxInputBytes = 1024 * 1024
    static let surfaceSetMethod = "client_shell.surface.set"

    nonisolated let negotiated: Negotiated
    private let transport: any HerdrBridgeTransport
    private let timing: Timing
    private let onEvent: @Sendable (HerdrConnectionEvent) async -> Void
    private let openedAt = ContinuousClock.now

    private var splitter: HerdrFrameSplitter
    private var bootID: String?
    private var isActive = false
    private var ended = false
    /// Why the connection ended, for the reader to report; nil after a close Remux asked for.
    private var endReason: HerdrConnectionError?
    private var appActive = false
    /// When bytes last arrived, or reading resumed after the screen took the previous ones.
    private var lastProgress = ContinuousClock.now
    /// The screen is taking messages, so nothing is read; that time isn't server silence.
    private var delivering = false
    private var outstandingPing: (data: String, sentAt: ContinuousClock.Instant)?
    private var pongWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var nextID: UInt64 = 0

    private var writeQueue: [[UInt8]] = []
    private var isWriting = false

    /// A request awaiting its final chunk. After a timeout or cancellation nobody waits any more, but
    /// the entry stays so the late reply is recognised and dropped.
    private struct Pending {
        var continuation: CheckedContinuation<Data, Error>?
        var data: [UInt8] = []
        var holdsLane: Bool
    }

    private var pending: [String: Pending] = [:]
    private var laneBusy = false
    private var nextTicket: UInt64 = 0
    private var laneWaiters: [(ticket: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var healthTask: Task<Void, Never>?

    // MARK: - Opening

    /// Sends the hello, waits for the welcome and starts reading. `appActive` starts the health check
    /// when the app is in the foreground (`setAppActive`).
    static func open(
        transport: any HerdrBridgeTransport,
        hello: HerdrHello,
        appActive: Bool,
        timing: Timing = Timing(),
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) async throws -> HerdrConnection {
        // A failed write ends the stream, and the read below then reports why.
        try? await transport.write(HerdrClientMessage.hello(hello).frame)
        // A read doesn't end when its task is cancelled, so the timeout and a cancelled open close the
        // transport, which ends the read. A timeout means the path may be dead.
        let timer = Task {
            try await Task.sleep(for: timing.welcome)
            await transport.close(reusable: false)
        }
        let welcome: HerdrWelcome
        let splitter: HerdrFrameSplitter
        do {
            (welcome, splitter) = try await withTaskCancellationHandler {
                try await readWelcome(from: transport)
            } onCancel: {
                Task { await transport.close(reusable: true) }
            }
            timer.cancel()
            try validate(welcome)
            try Task.checkCancellation()
        } catch {
            timer.cancel()
            if case .success = await timer.result {
                throw HerdrConnectionError.handshakeTimedOut
            }
            await transport.close(reusable: true)
            throw Task.isCancelled ? CancellationError() : Self.connectionError(error)
        }
        let connection = HerdrConnection(
            transport: transport,
            negotiated: Negotiated(
                serverVersion: welcome.serverVersion,
                methods: Set(welcome.methods),
                delta: welcome.capabilities.contains("surface_delta"),
                scroll: welcome.capabilities.contains("surface_scroll")
            ),
            splitter: splitter,
            surfaceActive: hello.surfaceActive,
            timing: timing,
            onEvent: onEvent
        )
        await connection.start(appActive: appActive)
        return connection
    }

    private init(
        transport: any HerdrBridgeTransport,
        negotiated: Negotiated,
        splitter: HerdrFrameSplitter,
        surfaceActive: Bool,
        timing: Timing,
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) {
        self.transport = transport
        self.negotiated = negotiated
        self.splitter = splitter
        self.isActive = surfaceActive
        self.timing = timing
        self.onEvent = onEvent
    }

    private static func readWelcome(
        from transport: any HerdrBridgeTransport
    ) async throws -> (HerdrWelcome, HerdrFrameSplitter) {
        var splitter = HerdrFrameSplitter()
        while true {
            if let payload = try splitter.nextPayload() {
                let message = try HerdrServerMessage.decode(payload)
                // A server older than the endpoint protocol answers with the binary welcome; Herdr's
                // client says to update it.
                if case .unused(tag: 0) = message {
                    throw HerdrConnectionError.incompatible("its Herdr needs an update")
                }
                guard case .control(let kind, let data) = message,
                      kind == HerdrControlKind.welcome,
                      case .welcome(let welcome) = try HerdrEndpointControl.parse(kind: kind, data: data)
                else {
                    throw HerdrConnectionError.incompatible("its first message wasn't a welcome")
                }
                return (welcome, splitter)
            }
            guard let chunk = try await transport.read() else { throw HerdrConnectionError.closed }
            splitter.append(chunk)
        }
    }

    /// Herdr's client checks the same fields, then refuses a remote server without surface activation
    /// or health checks. Herdr's surface activation also requires the presentation fence; Remux doesn't
    /// use the fence, so it doesn't require it.
    private static func validate(_ welcome: HerdrWelcome) throws {
        if let error = welcome.error {
            throw HerdrConnectionError.rejected(code: error.code, message: error.message)
        }
        guard welcome.generation == 1 else {
            throw HerdrConnectionError.incompatible("it speaks endpoint generation \(welcome.generation)")
        }
        guard welcome.snapshotCodec == HerdrControlKind.snapshot,
              welcome.surfaceCodec == "shell.surface.v1",
              welcome.inputCodec == "shell.input.semantic.v1",
              welcome.blobCodec == "shell.blob.v1"
        else {
            throw HerdrConnectionError.incompatible("it uses other codecs")
        }
        guard welcome.capabilities.contains("surface_interest"),
              welcome.capabilities.contains("health_check"),
              welcome.methods.contains(surfaceSetMethod)
        else {
            throw HerdrConnectionError.incompatible("its Herdr \(welcome.serverVersion) needs an update")
        }
    }

    private static func connectionError(_ error: Error) -> HerdrConnectionError {
        switch error {
        case let error as HerdrConnectionError:
            return error
        case let error as HerdrWireError:
            return .wire(error)
        case let error as LocalizedError:
            return .transport(error.errorDescription ?? "The connection to Herdr failed.")
        default:
            return .transport("The connection to Herdr failed: \(String(describing: error)).")
        }
    }

    private func start(appActive: Bool) {
        Task { await self.readLoop() }
        setAppActive(appActive)
    }

    // MARK: - Reading

    /// The only place events go out, so `.ended` follows whatever the screen was given and never
    /// overlaps it.
    private func readLoop() async {
        do {
            try await deliverBuffered()
            while !ended {
                guard let chunk = try await transport.read() else {
                    throw HerdrConnectionError.closed
                }
                guard !ended else { break }
                lastProgress = .now
                splitter.append(chunk)
                try await deliverBuffered()
            }
        } catch {
            await end(Self.connectionError(error))
        }
        if let endReason {
            await onEvent(.ended(endReason))
        }
    }

    /// Hands every complete message to the screen before the next read.
    private func deliverBuffered() async throws {
        delivering = true
        defer {
            delivering = false
            lastProgress = .now
        }
        while !ended, let payload = try splitter.nextPayload() {
            try await route(try HerdrServerMessage.decode(payload))
        }
    }

    /// While the session is hidden, bells, clipboard writes and input refusals are dropped, as in
    /// Herdr's client; surfaces still go to the decoder.
    private func route(_ message: HerdrServerMessage) async throws {
        switch message {
        case .control(let kind, let data):
            switch try HerdrEndpointControl.parse(kind: kind, data: data) {
            case .snapshot(let snapshot):
                bootID = snapshot.bootID
                await onEvent(.snapshot(snapshot))
            case .surfaceReuse(let reuse):
                await onEvent(.surface(.reuse(reuse)))
            case .surfaceDelta(let delta):
                await onEvent(.surface(.delta(delta)))
            case .surfaceScroll(let scroll):
                await onEvent(.surface(.scroll(scroll)))
            case .healthPong(let data):
                if outstandingPing?.data == data { outstandingPing = nil }
                pongWaiters.removeValue(forKey: data)?.resume(returning: true)
            case .welcome, .ignored:
                break
            }
        case .paneSurface(let surface):
            await onEvent(.surface(.full(surface)))
        case .paneSurfacePatch(let patch):
            await onEvent(.surface(.patch(patch)))
        case .responseChunk(let chunk):
            receive(chunk)
        case .terminalBell(let count):
            if isActive { await onEvent(.bell(count: count)) }
        case .semanticNotification(let notification):
            await onEvent(.notification(notification))
        case .clipboard(let base64):
            if isActive { await onEvent(.clipboard(base64: base64)) }
        case .clientShellError(let message):
            if isActive { await onEvent(.inputRefused(message: message)) }
        case .serverShutdown(let reason):
            throw HerdrConnectionError.serverShutdown(reason: reason)
        case .mouseCapture, .keyboardReportAll, .windowTitle, .reloadSoundConfig, .notify, .unused:
            // Remux reads mouse state from each pane's surface flags, encodes no keys itself, shows no
            // outer title and plays no terminal sounds.
            break
        }
    }

    // MARK: - Writing

    private func enqueue(_ message: HerdrClientMessage) {
        guard !ended else { return }
        writeQueue.append(message.frame)
        guard !isWriting else { return }
        isWriting = true
        Task { await self.drainWrites() }
    }

    private func drainWrites() async {
        while !ended, !writeQueue.isEmpty {
            let frame = writeQueue.removeFirst()
            do {
                try await transport.write(frame)
            } catch {
                await end(Self.connectionError(error))
            }
        }
        isWriting = false
    }

    // MARK: - Showing and hiding

    /// Shows the session as Herdr's own client does: the tab takes this size (at least one cell each
    /// way), the surface activates, then the phone takes focus. Returns the projection floor from
    /// `surface.set`; the next full surface is at least that revision. If Herdr doesn't acknowledge it
    /// within the activation timeout, the show is rolled back as Herdr's client rolls it back.
    func show(_ geometry: HerdrSurfaceGeometry) async throws -> UInt64 {
        let size = HerdrSurfaceGeometry(
            cellWidthPx: geometry.cellWidthPx,
            cellHeightPx: geometry.cellHeightPx,
            cols: max(geometry.cols, 1),
            rows: max(geometry.rows, 1)
        )
        let (id, request) = try surfaceSet(active: true)
        isActive = true
        do {
            let data = try await reply(
                to: id,
                method: Self.surfaceSetMethod,
                holdsLane: false,
                timeout: timing.activation,
                sending: [.shellResize(size), request, .focus(true)]
            )
            return try Self.acknowledgedRevision(from: data, active: true)
        } catch {
            rollBackShow()
            throw error
        }
    }

    /// Hides the session. Focus goes first, while still active: deactivation keeps the stored focus,
    /// so without it the next show's focus would be ignored.
    func hide() async throws {
        let (id, request) = try surfaceSet(active: false)
        isActive = false
        let data = try await reply(
            to: id,
            method: Self.surfaceSetMethod,
            holdsLane: false,
            timeout: timing.activation,
            sending: [.focus(false), request]
        )
        _ = try Self.acknowledgedRevision(from: data, active: false)
    }

    private func rollBackShow() {
        isActive = false
        guard let release = try? surfaceSet(active: false) else { return }
        enqueue(.focus(false))
        enqueue(release.message)
    }

    private func surfaceSet(active: Bool) throws -> (id: String, message: HerdrClientMessage) {
        guard let bootID else { throw HerdrCommandError.noSnapshot }
        let id = makeID("s")
        let message = try HerdrClientMessage.endpointRequest(
            bootID: bootID,
            id: id,
            method: Self.surfaceSetMethod,
            params: ["active": active]
        )
        return (id, message)
    }

    /// As in Herdr's client, the reply must confirm the requested state.
    private static func acknowledgedRevision(from data: Data, active: Bool) throws -> UInt64 {
        struct Reply: Decodable {
            struct Result: Decodable {
                let active: Bool
                let projectionRevision: UInt64

                private enum CodingKeys: String, CodingKey {
                    case active
                    case projectionRevision = "projection_revision"
                }
            }

            let result: Result
        }
        guard let result = try? JSONDecoder().decode(Reply.self, from: data).result else {
            throw HerdrConnectionError.incompatible("its surface.set reply couldn't be read")
        }
        guard result.active == active else { throw HerdrCommandError.notAcknowledged }
        return result.projectionRevision
    }

    // MARK: - Input

    /// Sends input to a pane. Fails without sending while the session is hidden or when the message is
    /// over Herdr's limits.
    func send(_ events: [HerdrInputEvent], toPane paneID: String) throws {
        try checkCanSend(events)
        enqueue(.paneInput(paneID: paneID, events: events))
    }

    func send(_ events: [HerdrInputEvent], toPopup terminalID: String) throws {
        try checkCanSend(events)
        enqueue(.popupInput(terminalID: terminalID, events: events))
    }

    /// Herdr stores the update and applies it when this client is in front, so it is sent even while
    /// hidden.
    func reportHostTheme(_ update: HerdrHostThemeUpdate) {
        enqueue(.hostTheme(update))
    }

    private func checkCanSend(_ events: [HerdrInputEvent]) throws {
        guard !ended else { throw HerdrInputError.connectionEnded }
        guard isActive else { throw HerdrInputError.inactive }
        try Self.checkLimits(events)
    }

    /// Herdr's counting: a key counts its repeats, a vertical wheel event its lines, anything else one;
    /// paste text, typed text and key text count toward the byte limit.
    static func checkLimits(_ events: [HerdrInputEvent]) throws {
        var expanded = 0
        var bytes = 0
        for event in events {
            switch event {
            case .key(let key):
                let repeats = max(Int(key.repeatCount), 1)
                expanded += repeats
                bytes += (key.generatedText?.utf8.count ?? 0) * repeats
            case .text(let text), .paste(let text):
                expanded += 1
                bytes += text.utf8.count
            case .mouse(let mouse):
                switch mouse.kind {
                case .scrollUp, .scrollDown: expanded += max(Int(mouse.lines), 1)
                default: expanded += 1
                }
            }
        }
        guard expanded <= maxInputEvents else { throw HerdrInputError.tooManyEvents(expanded) }
        guard bytes <= maxInputBytes else { throw HerdrInputError.tooLarge(bytes: bytes) }
    }

    // MARK: - Commands

    /// Runs one endpoint command and returns its reply JSON (`{"id", "result"}`). Commands run one at a
    /// time, as in Herdr's client; a later one waits for the lane, which frees when the reply arrives or
    /// the command times out. A command cancelled while it waits is never sent; one cancelled after it
    /// was sent stops waiting, and its reply or timeout still frees the lane.
    func command(_ method: String, params: some Encodable & Sendable) async throws -> Data {
        guard negotiated.methods.contains(method) else { throw HerdrCommandError.unsupported(method: method) }
        try await acquireLane()
        let id = makeID("c")
        let message: HerdrClientMessage
        do {
            try Task.checkCancellation()
            guard !ended else { throw HerdrCommandError.connectionEnded }
            guard let bootID else { throw HerdrCommandError.noSnapshot }
            message = try HerdrClientMessage.endpointRequest(bootID: bootID, id: id, method: method, params: params)
        } catch {
            releaseLane()
            throw error
        }
        return try await reply(to: id, method: method, holdsLane: true, timeout: timing.command, sending: [message])
    }

    /// Registers the reply for `id`, then queues `messages` in order, all before any other actor work,
    /// so a step's messages go out together and its reply can't arrive unregistered.
    private func reply(
        to id: String,
        method: String,
        holdsLane: Bool,
        timeout: Duration,
        sending messages: [HerdrClientMessage]
    ) async throws -> Data {
        guard !ended else { throw HerdrCommandError.connectionEnded }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(continuation: continuation, holdsLane: holdsLane)
                messages.forEach(enqueue)
                Task {
                    try? await Task.sleep(for: timeout)
                    await self.expire(id, method: method)
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(for: id) }
        }
    }

    /// Herdr's client retires a request that didn't answer in time: the caller fails, the lane frees,
    /// and the late reply is dropped.
    private func expire(_ id: String, method: String) {
        guard var request = pending[id] else { return }
        request.continuation?.resume(throwing: HerdrCommandError.timedOut(method: method))
        request.continuation = nil
        if request.holdsLane {
            request.holdsLane = false
            releaseLane()
        }
        pending[id] = request
    }

    private func stopWaiting(for id: String) {
        guard var request = pending[id], let continuation = request.continuation else { return }
        request.continuation = nil
        pending[id] = request
        continuation.resume(throwing: CancellationError())
    }

    private func receive(_ chunk: HerdrResponseChunk) {
        guard var request = pending[chunk.requestID] else { return }
        if request.continuation != nil {
            request.data += chunk.data
        }
        guard chunk.isFinal else {
            pending[chunk.requestID] = request
            return
        }
        pending[chunk.requestID] = nil
        if request.holdsLane { releaseLane() }
        guard let continuation = request.continuation else { return }
        let data = Data(request.data)
        struct Failure: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }

            let error: Body?
        }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let error = failure.error {
            continuation.resume(throwing: HerdrCommandError.failed(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: data)
        }
    }

    /// Takes the lane, waiting in line while it's busy. A waiter whose task is cancelled leaves the
    /// line without the lane.
    private func acquireLane() async throws {
        guard laneBusy else {
            laneBusy = true
            return
        }
        nextTicket += 1
        let ticket = nextTicket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                laneWaiters.append((ticket, continuation))
            }
        } onCancel: {
            Task { await self.leaveLine(ticket) }
        }
    }

    private func leaveLine(_ ticket: UInt64) {
        guard let index = laneWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        laneWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Passes the lane straight to the next waiter.
    private func releaseLane() {
        if laneWaiters.isEmpty {
            laneBusy = false
        } else {
            laneWaiters.removeFirst().continuation.resume()
        }
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    // MARK: - Health

    /// While the app is open, Herdr's health rule runs (`Timing`). Two differences, each with a Remux
    /// reason: any bytes count, not only whole messages, because a picture can be a 32 MiB message
    /// still arriving over cellular; and time the screen spends taking messages doesn't count, since
    /// nothing is read then. In the background nothing is sent: pings from a suspended phone would keep
    /// a bridge that isn't reading alive.
    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        healthTask?.cancel()
        healthTask = nil
        outstandingPing = nil
        guard active, !ended else { return }
        healthTask = Task { await self.monitorHealth() }
    }

    /// Sends a ping with a fresh id and reports whether its own reply came back: the check before
    /// showing a session again after the app returns. It gives up once nothing has arrived for
    /// `unansweredPing`, not counting time the screen spends taking the backlog queued ahead of the
    /// reply.
    func confirmAlive() async -> Bool {
        guard !ended else { return false }
        let data = makeID("alive")
        let sentAt = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            pongWaiters[data] = continuation
            enqueue(.healthPing(data: data))
            Task { await self.expireWhenSilent(data, sentAt: sentAt) }
        }
    }

    private func expireWhenSilent(_ data: String, sentAt: ContinuousClock.Instant) async {
        while pongWaiters[data] != nil {
            try? await Task.sleep(for: timing.healthTick)
            if delivering { continue }
            if ContinuousClock.now - max(sentAt, lastProgress) >= timing.unansweredPing {
                pongWaiters.removeValue(forKey: data)?.resume(returning: false)
            }
        }
    }

    private func monitorHealth() async {
        while appActive, !ended, !Task.isCancelled {
            try? await Task.sleep(for: timing.healthTick)
            guard appActive, !ended, !Task.isCancelled else { return }
            if delivering { continue }
            let now = ContinuousClock.now
            if bootID == nil, now - openedAt >= timing.firstSnapshot {
                await end(.unresponsive)
                return
            }
            if let ping = outstandingPing {
                if lastProgress > ping.sentAt {
                    outstandingPing = nil
                } else if now - ping.sentAt >= timing.unansweredPing {
                    await end(.unresponsive)
                    return
                }
            } else if now - lastProgress >= timing.pingAfterSilence {
                let data = makeID("ping")
                outstandingPing = (data, now)
                enqueue(.healthPing(data: data))
            }
        }
    }

    // MARK: - Ending

    /// Ends the connection; no `ended` event follows. Nothing is written first: Herdr removes an
    /// endpoint client whose stream ends just as one that sends `Detach`, and the bridge passes the end
    /// of its input on.
    func close() async {
        guard !ended else { return }
        finish()
        await transport.close(reusable: true)
    }

    /// The reader reports `error` once the screen has taken what it was given.
    private func end(_ error: HerdrConnectionError) async {
        guard !ended else { return }
        endReason = error
        finish()
        await transport.close(reusable: error != .unresponsive)
    }

    private func finish() {
        ended = true
        isActive = false
        healthTask?.cancel()
        healthTask = nil
        writeQueue.removeAll()
        for request in pending.values {
            request.continuation?.resume(throwing: HerdrCommandError.connectionEnded)
        }
        pending.removeAll()
        for waiter in pongWaiters.values {
            waiter.resume(returning: false)
        }
        pongWaiters.removeAll()
        let waiters = laneWaiters
        laneWaiters.removeAll()
        laneBusy = false
        waiters.forEach { $0.continuation.resume(throwing: HerdrCommandError.connectionEnded) }
    }
}
