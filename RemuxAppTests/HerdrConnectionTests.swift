import Foundation
import XCTest
@testable import Remux

final class HerdrConnectionTests: XCTestCase {
    private let hello = HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 40, rows: 12, surfaceActive: true)
    /// Long enough that no outcome depends on scheduling delays.
    private let relaxed = HerdrConnection.Timing(
        welcome: .seconds(10),
        pingAfterSilence: .seconds(60),
        unansweredPing: .seconds(60),
        firstSnapshot: .seconds(60),
        deliveryRecheck: .milliseconds(10),
        command: .seconds(10),
        activation: .seconds(10)
    )

    /// Short limits for the tests about a timeout firing; their outcome is the same however late the
    /// scheduler runs.
    private func timing(
        welcome: Duration = .seconds(10),
        pingAfterSilence: Duration = .seconds(60),
        unansweredPing: Duration = .seconds(60),
        firstSnapshot: Duration = .seconds(60),
        deliveryRecheck: Duration = .milliseconds(10),
        command: Duration = .seconds(10),
        activation: Duration = .seconds(10)
    ) -> HerdrConnection.Timing {
        HerdrConnection.Timing(
            welcome: welcome,
            pingAfterSilence: pingAfterSilence,
            unansweredPing: unansweredPing,
            firstSnapshot: firstSnapshot,
            deliveryRecheck: deliveryRecheck,
            command: command,
            activation: activation
        )
    }

    // MARK: - Opening

    /// The recorded all-capabilities session: Remux's hello goes out, the welcome is checked, and the
    /// snapshot and surface reach the screen before the server's shutdown ends the connection.
    func testOpensWithRemuxsHelloAndDeliversTheRecordedSession() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(try Self.recording("herdr-01-handshake-all-caps-A"), inChunksOf: 97)
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: events.record)

        let offered = await connection.negotiated
        let negotiated = try XCTUnwrap(offered)
        XCTAssertEqual(negotiated.methods.count, 40)
        XCTAssertEqual(negotiated.serverVersion, "0.9.3")
        XCTAssertTrue(negotiated.delta)
        XCTAssertTrue(negotiated.scroll)
        let first = try await transport.written(0)
        XCTAssertEqual(first, HerdrClientMessage.hello(hello).frame)

        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "keyboardReportAll(false)", "surface.full", "ended(serverShutdown)"])
    }

    func testARejectedHelloFailsWithTheServersCode() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(try Self.recording("herdr-03-handshake-rejections-gen2"))
        await transport.finishServing()
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let HerdrConnectionError.rejected(code, _) {
            XCTAssertEqual(code, "unsupported_generation")
        }
    }

    func testTheFirstMessageMustBeAWelcome() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame([9, 1]))
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .incompatible("its first message wasn't a welcome"))
        }
        let closed = await transport.isClosed
        XCTAssertTrue(closed)
    }

    func testNoWelcomeTimesOutAndCloses() async throws {
        let transport = FakeBridgeTransport()
        do {
            _ = try await HerdrConnection.open(
                transport: transport,
                hello: hello,
                appActive: false,
                timing: timing(welcome: .milliseconds(100)),
                onEvent: { _ in }
            )
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .handshakeTimedOut)
        }
        // No answer means the path may be dead.
        let closes = await transport.closes
        XCTAssertEqual(closes, [.unresponsive])
    }

    /// The connection owns its bridge from the start: closed by its owner during the handshake, it closes
    /// the bridge once, with the owner's cause, and its opening throws `CancellationError`.
    func testClosingDuringTheHandshakeClosesTheBridgeOnceWithTheOwnersCause() async throws {
        let transport = FakeBridgeTransport()
        let connection = HerdrConnection(transport: transport, timing: timing(), onEvent: { _ in })
        let sentHello = hello
        let opening = Task { try await connection.open(hello: sentHello, appActive: false) }
        _ = try await transport.written(0)

        await connection.close(.givenUpWhileOpening)
        let result = await opening.result
        guard case .failure(let error) = result, error is CancellationError else {
            return XCTFail("expected a cancelled opening, got \(result)")
        }
        try await Task.sleep(for: .milliseconds(50))
        let closes = await transport.closes
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A connection its owner closed before it opened sends nothing and doesn't open.
    func testAConnectionClosedBeforeItOpensSendsNothing() async throws {
        let transport = FakeBridgeTransport()
        let connection = HerdrConnection(transport: transport, timing: timing(), onEvent: { _ in })
        await connection.close(.givenUpWhileOpening)
        do {
            try await connection.open(hello: hello, appActive: false)
            XCTFail("opened")
        } catch is CancellationError {}
        let written = await transport.writtenCount
        let closes = await transport.closes
        XCTAssertEqual(written, 0)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// The deadline covers the hello too: a write that never completes still times out.
    func testAStalledHelloTimesOutAndCloses() async throws {
        let transport = FakeBridgeTransport()
        await transport.stallWrites()
        let (sentHello, shortTiming) = (hello, timing(welcome: .milliseconds(100)))
        let opening = Task {
            try await HerdrConnection.open(transport: transport, hello: sentHello, appActive: false, timing: shortTiming, onEvent: { _ in })
        }
        let returned = expectation(description: "open returned")
        Task {
            if case .failure(let error) = await opening.result {
                XCTAssertEqual(error as? HerdrConnectionError, .handshakeTimedOut)
            } else {
                XCTFail("opened")
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        let closes = await transport.closes
        XCTAssertEqual(closes, [.unresponsive])
    }

    /// Closing the connection while the hello is stalled ends its opening at once.
    func testClosingDuringAStalledHelloEndsTheOpening() async throws {
        let transport = FakeBridgeTransport()
        await transport.stallWrites()
        let connection = HerdrConnection(transport: transport, timing: relaxed, onEvent: { _ in })
        let sentHello = hello
        let opening = Task { try await connection.open(hello: sentHello, appActive: false) }
        await transport.waitForStalledWrites(1)
        await connection.close(.givenUpWhileOpening)
        let returned = expectation(description: "open returned")
        Task {
            if case .failure(let error) = await opening.result {
                XCTAssertTrue(error is CancellationError, "\(error)")
            } else {
                XCTFail("opened")
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
    }

    /// An old server answers the hello with the binary welcome; Herdr's client asks for an update.
    func testAnOldServerIsAskedToUpdate() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame([0, 1, 2]))
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .outdated(serverVersion: nil))
        }
    }

    /// As Herdr's client, a remote server needs surface activation and health checks.
    func testAServerWithoutHealthChecksIsAskedToUpdate() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(try Self.welcome(removing: "health_check"))
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .outdated(serverVersion: "0.9.3"))
        }
    }

    /// The transport's reason for ending, such as the bridge's "Herdr isn't installed", reaches the
    /// user as written.
    func testTheTransportsReasonReachesTheUser() async throws {
        let transport = FakeBridgeTransport()
        await transport.finishServing(throwing: NotInstalled())
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .transport(NotInstalled.text))
            XCTAssertEqual(error.localizedDescription, NotInstalled.text)
        }
    }

    /// The live bridge opens before Herdr's executable is looked up, so a missing Herdr is reported by the
    /// first read. It keeps its kind: Herdr unavailable, which Edit Server fixes, not a lost connection.
    func testABridgeThatReportsHerdrMissingOnItsFirstReadKeepsItsKind() async throws {
        for bridgeError in [HerdrBridgeError.program(.notFound), .program(.couldNotStart("sh: 1: exec: herdr: Permission denied"))] {
            let transport = FakeBridgeTransport()
            await transport.finishServing(throwing: bridgeError)
            do {
                _ = try await HerdrConnection.open(
                    transport: transport,
                    hello: hello,
                    appActive: false,
                    timing: relaxed,
                    onEvent: { _ in }
                )
                XCTFail("opened")
            } catch let error as HerdrConnectionError {
                XCTAssertEqual(error, .bridge(bridgeError))
                XCTAssertEqual(error.terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")).kind, .backendUnavailable(.herdr))
                XCTAssertEqual(error.localizedDescription, bridgeError.errorDescription)
            }
        }
    }

    /// Herdr answered, refusing the hello: the bridge closes once, keeping the path for the next opening.
    func testARefusedHelloClosesTheBridgeOnceAsFinished() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(try Self.recording("herdr-03-handshake-rejections-gen2"))
        await transport.finishServing()
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch is HerdrConnectionError {}
        let closes = await transport.closes
        XCTAssertEqual(closes, [.finished])
    }

    // MARK: - Showing, hiding and input

    /// As Herdr's client, a new size goes only to the session on screen, also while its show is being
    /// answered: a hidden one gets its size with the next show. It asks for at least one cell each way.
    func testResizeGoesOnlyToTheSessionOnScreen() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: false)
        let size = HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 30, rows: 10)
        await connection.resize(size)
        try await Task.sleep(for: .milliseconds(30))
        let writtenWhileHidden = await transport.writtenCount
        XCTAssertEqual(writtenWhileHidden, 1)

        connection.outbox.setSurfaceActive(true)
        await connection.resize(size)
        let resizeWhileShown = try await transport.written(1)
        XCTAssertEqual(resizeWhileShown, HerdrClientMessage.shellResize(size).frame)
        await connection.resize(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 0, rows: 0))
        let atLeastOneCell = try await transport.written(2)
        XCTAssertEqual(atLeastOneCell, HerdrClientMessage.shellResize(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 1, rows: 1)).frame)
    }

    /// A surface the decoder can't apply ends the connection as a wire failure, as in Herdr's client.
    func testASurfaceTheDecoderCannotApplyEndsTheConnection() async throws {
        let (_, transport, events) = try await openedSession(surfaceActive: true)
        let recorded = try Self.frames(Self.recording("herdr-04-patch-and-delta-A"))
        let delta = try XCTUnwrap(recorded.first { payload in
            guard case .control(let kind, _) = try? HerdrServerMessage.decode(payload) else { return false }
            return kind == HerdrControlKind.surfaceDelta
        })
        await transport.serve(HerdrWire.frame(delta))
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "ended(\(HerdrConnectionError.wire(.invalidSurfaceUpdate("surface delta without a baseline"))))"])
    }

    func testInputIsRefusedWhileHiddenOrOverHerdrsLimits() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: false)
        do {
            try await connection.send([.text("a")], toPane: "w1:p1")
            XCTFail("sent while hidden")
        } catch let error as HerdrInputError {
            XCTAssertEqual(error, .inactive)
        }
        let (active, activeTransport, _) = try await openedSession(surfaceActive: true)
        let keys = [HerdrInputEvent](repeating: .key(HerdrKeyEvent(code: .enter)), count: 4097)
        do {
            try await active.send(keys, toPane: "w1:p1")
            XCTFail("sent 4097 events")
        } catch let error as HerdrInputError {
            XCTAssertEqual(error, .tooManyEvents(4097))
        }
        do {
            try await active.send([.paste(String(repeating: "a", count: 1024 * 1024 + 1))], toPane: "w1:p1")
            XCTFail("sent over 1 MiB")
        } catch let error as HerdrInputError {
            XCTAssertEqual(error, .tooLarge(bytes: 1024 * 1024 + 1))
        }
        let wheel = HerdrMouseEvent(kind: .scrollDown, column: 0, row: 0, lines: 4096)
        XCTAssertThrowsError(try HerdrConnection.checkLimits([.mouse(wheel), .text("x")]))
        try await active.send([.text("hi")], toPane: "w1:p1")
        let sent = try await activeTransport.written(1)
        XCTAssertEqual(sent, HerdrClientMessage.paneInput(paneID: "w1:p1", events: [.text("hi")]).frame)
        _ = transport
    }

    // MARK: - Replies

    /// Every reply chunk reaches the screen as it comes, in wire order with the snapshots: the engine,
    /// which sent the requests, joins and judges them.
    func testRepliesReachTheScreenInWireOrder() async throws {
        let (_, transport, events) = try await openedSession(surfaceActive: true)
        let boot = "68169-1791562319387415000"
        await transport.serve(
            Self.chunk(id: "c1", data: Array(#"{"id":"c1","#.utf8), final: false)
                + HerdrServerScript.snapshot(revision: 100, boot: boot)
                + Self.chunk(id: "c1", data: Array(#""result":{}}"#.utf8), final: true)
        )
        await events.waitForCount(4)
        let kinds = await events.events.map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "response(c1)", "snapshot", "response(c1, final)"])
    }

    /// The connection's own messages and the requests the engine sends share one writer, which keeps the
    /// order they were sent in; once the connection ends nothing more goes out.
    func testEveryWriteGoesOutInTheOrderSent() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        let request = try HerdrClientMessage.endpointRequest(
            bootID: "boot",
            id: "c1",
            method: "worktree.list",
            params: [String: String]()
        )
        let size = HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 30, rows: 10)
        connection.outbox.send([request, .focus(true)])
        await connection.resize(size)
        let written = [try await transport.written(1), try await transport.written(2), try await transport.written(3)]
        XCTAssertEqual(written, [request.frame, HerdrClientMessage.focus(true).frame, HerdrClientMessage.shellResize(size).frame])

        await connection.close(.finished)
        connection.outbox.send([request])
        try await Task.sleep(for: .milliseconds(30))
        let count = await transport.writtenCount
        XCTAssertEqual(count, 4)
    }

    // MARK: - Health

    func testSilenceAfterAPingEndsTheConnection() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(pingAfterSilence: .milliseconds(50), unansweredPing: .milliseconds(100))
        )
        await connection.setAppActive(true)
        let ping = try await transport.written(1)
        XCTAssertEqual(try Self.control(ping).kind, HerdrControlKind.healthPing)
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds.last, "ended(unresponsive)")
        let closes = await transport.closes
        XCTAssertEqual(closes, [.unresponsive])
    }

    /// As Herdr's client, a connection whose session never arrives fails.
    func testNoSnapshotAfterConnectingEndsTheConnection() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame(try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))[0]))
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(
            transport: transport,
            hello: hello,
            appActive: true,
            timing: timing(firstSnapshot: .milliseconds(100)),
            onEvent: events.record
        )
        addTeardownBlock { await connection.close(.finished) }
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["ended(unresponsive)"])
    }

    /// Any bytes after a ping answer it, so a long message still arriving is not a dead connection.
    /// The proof: part of a message arrives, and a second ping goes out after the next silence, which
    /// happens only once the first has been answered; the message is delivered once it's complete.
    func testBytesAfterAPingAnswerIt() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(pingAfterSilence: .milliseconds(50))
        )
        await connection.setAppActive(true)
        let first = try Self.control(try await transport.written(1))
        let bell = HerdrWire.frame([9, 1])
        await transport.serve(Array(bell.prefix(3)))
        let second = try Self.control(try await transport.written(2))
        XCTAssertEqual(second.kind, HerdrControlKind.healthPing)
        XCTAssertNotEqual(second.data, first.data)
        let delivered = await events.events.count
        XCTAssertEqual(delivered, 1, "only the snapshot")
        await transport.serve(Array(bell.dropFirst(3)))
        await events.waitForCount(2)
        let ended = await events.hasEnded
        XCTAssertFalse(ended)
        await connection.setAppActive(false)
    }

    /// The health check wakes when a limit is due, not on a schedule: with the re-check while the screen
    /// takes messages at a minute, the ping goes out after the silence and the connection fails at the
    /// reply limit.
    func testHealthLimitsAreKeptWithoutAPeriodicCheck() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(pingAfterSilence: .milliseconds(50), unansweredPing: .milliseconds(100), deliveryRecheck: .seconds(60))
        )
        let reads = await transport.waitForReads(2)
        XCTAssertEqual(reads, 2, "the reader is waiting again, so the snapshot has been taken")
        await connection.setAppActive(true)
        let ping = try Self.control(try await transport.written(1))
        XCTAssertEqual(ping.kind, HerdrControlKind.healthPing)
        let deadline = ContinuousClock.now + .seconds(2)
        while await events.hasEnded == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let kinds = await events.events.map(\.kind)
        XCTAssertEqual(kinds.last, "ended(unresponsive)")
    }

    /// Bytes that answer a ping restart the silence, so the next ping goes out a silence after them,
    /// long before the reply limit the check was also waiting for.
    func testTheNextPingFollowsTheBytesThatAnsweredThePreviousOne() async throws {
        let (connection, transport, _) = try await openedSession(
            surfaceActive: true,
            timing: timing(pingAfterSilence: .milliseconds(100), deliveryRecheck: .seconds(60))
        )
        _ = await transport.waitForReads(2)
        await connection.setAppActive(true)
        let first = try Self.control(try await transport.written(1))
        // Part of a message: read, but nothing for the screen to take.
        await transport.serve(Array(HerdrWire.frame([9, 1]).prefix(3)))
        let second = try Self.control(try await transport.written(2))
        XCTAssertEqual(second.kind, HerdrControlKind.healthPing)
        XCTAssertNotEqual(second.data, first.data)
        await connection.setAppActive(false)
    }

    /// While the screen holds a message nothing is read, so no answer can arrive: that pause isn't
    /// server silence. Once the screen takes the message, the health check carries on.
    func testAScreenHoldingAMessageIsNotServerSilence() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(pingAfterSilence: .milliseconds(50), unansweredPing: .milliseconds(100))
        )
        await events.hold()
        await transport.serve(HerdrWire.frame([9, 1]))
        await events.waitForCount(2)
        await connection.setAppActive(true)
        try await Task.sleep(for: .milliseconds(500))
        let endedWhileHeld = await events.hasEnded
        XCTAssertFalse(endedWhileHeld)
        let written = await transport.writtenCount
        XCTAssertEqual(written, 1, "no ping while the screen holds a message")

        await events.release()
        let ping = try Self.control(try await transport.written(1))
        XCTAssertEqual(ping.kind, HerdrControlKind.healthPing)
        await transport.serve(Self.pong(ping.data))
        await connection.setAppActive(false)
        let ended = await events.hasEnded
        XCTAssertFalse(ended)
    }

    /// Herdr's client: a ping after 5 s of silence, its reply within 10 s, and 60 s for the first
    /// snapshot, as long as a remote server's setup.
    func testTheDefaultTimingIsHerdrsHealthRule() {
        let timing = HerdrConnection.Timing()
        XCTAssertEqual(timing.pingAfterSilence, .seconds(5))
        XCTAssertEqual(timing.unansweredPing, .seconds(10))
        XCTAssertEqual(timing.firstSnapshot, .seconds(60))
    }

    /// Herdr's server answers pings only once it has registered the client, which a busy server can put
    /// off after the welcome. So an unanswered ping fails the connection only after the server has sent
    /// something; before that only the first-snapshot limit applies.
    func testAPingCountsAsUnansweredOnlyOnceTheServerHasSentSomething() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame(try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))[0]))
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(
            transport: transport,
            hello: hello,
            appActive: true,
            timing: timing(pingAfterSilence: .milliseconds(50), unansweredPing: .milliseconds(100)),
            onEvent: events.record
        )
        addTeardownBlock { await connection.close(.finished) }
        let ping = try Self.control(try await transport.written(1))
        XCTAssertEqual(ping.kind, HerdrControlKind.healthPing)
        try await Task.sleep(for: .milliseconds(500))
        let endedBeforeAnything = await events.hasEnded
        XCTAssertFalse(endedBeforeAnything)

        await transport.serve(HerdrWire.frame([9, 1]))
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["bell", "ended(unresponsive)"])
    }

    /// An alive check follows the same rule: before anything has come since the welcome it keeps
    /// waiting, and once the server has sent something an unanswered check ends the connection.
    func testConfirmAliveWaitsUntilTheServerHasSentSomething() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame(try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))[0]))
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(
            transport: transport,
            hello: hello,
            appActive: true,
            timing: timing(unansweredPing: .milliseconds(100)),
            onEvent: events.record
        )
        addTeardownBlock { await connection.close(.finished) }
        let answer = AnswerBox()
        let check = Task { await answer.set(await connection.confirmAlive()) }
        _ = try await transport.written(1)
        try await Task.sleep(for: .milliseconds(500))
        let earlyAnswer = await answer.value
        XCTAssertNil(earlyAnswer)

        await transport.serve(HerdrWire.frame([9, 1]))
        await check.value
        let finalAnswer = await answer.value
        XCTAssertEqual(finalAnswer, false)
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["bell", "ended(unresponsive)"])
    }

    /// Messages without a snapshot don't extend the first-snapshot limit for an alive check either.
    func testConfirmAliveGivesUpWhenNoSnapshotCameInTime() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame(try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))[0]))
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(
            transport: transport,
            hello: hello,
            appActive: true,
            timing: timing(unansweredPing: .milliseconds(300), firstSnapshot: .milliseconds(400)),
            onEvent: events.record
        )
        addTeardownBlock { await connection.close(.finished) }
        let bells = Task {
            while !Task.isCancelled {
                await transport.serve(HerdrWire.frame([9, 1]))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { bells.cancel() }
        let answer = AnswerBox()
        let check = Task { await answer.set(await connection.confirmAlive()) }
        defer { check.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while await answer.value == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let answered = await answer.value
        XCTAssertEqual(answered, false, "the check must give up at the first-snapshot limit")
        let last = await events.waitForEnd().last?.kind
        XCTAssertEqual(last, "ended(unresponsive)")
    }

    func testConfirmAliveIsAnsweredByItsOwnPong() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        async let alive = connection.confirmAlive()
        let ping = try Self.control(try await transport.written(1))
        await transport.serve(Self.pong(ping.data))
        let answered = await alive
        XCTAssertTrue(answered)
    }

    /// The reply to a ping the connection didn't send, the marker the engine puts after a wheel batch, goes to the
    /// screen in wire order with what Herdr sent around it; the connection's own ping is still its own.
    func testAPongTheConnectionDidNotSendGoesToTheScreenInWireOrder() async throws {
        let (connection, transport, events) = try await openedSession(surfaceActive: true)
        let before = await events.events.count
        async let alive = connection.confirmAlive()
        let ping = try Self.control(try await transport.written(1))
        await transport.serve(
            HerdrWire.frame([9, 1]) + Self.pong("remux-wheel-1-7") + HerdrWire.frame([9, 1]) + Self.pong(ping.data)
        )
        let answered = await alive
        XCTAssertTrue(answered)
        await events.waitForCount(before + 3)
        let kinds = await events.events.dropFirst(before).map(\.kind)
        XCTAssertEqual(kinds, ["bell", "pong(remux-wheel-1-7)", "bell"])
    }

    /// Another ping's reply doesn't answer the check, so it stays unanswered and ends the connection.
    func testAnotherPongDoesNotConfirmAlive() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(unansweredPing: .milliseconds(200))
        )
        await connection.setAppActive(true)
        async let alive = connection.confirmAlive()
        _ = try await transport.written(2)
        await transport.serve(Self.pong("not-this-one"))
        let answered = await alive
        XCTAssertFalse(answered)
        let last = await events.waitForEnd().last?.kind
        XCTAssertEqual(last, "ended(unresponsive)")
    }

    /// Back from the background, as Herdr's client after a resume, a ping goes out at once instead of
    /// after the next silence.
    func testComingBackPingsAtOnce() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        await connection.setAppActive(true)
        _ = try await transport.written(1)
        await connection.setAppActive(false)
        await connection.setAppActive(true)
        let ping = try Self.control(try await transport.written(2))
        XCTAssertEqual(ping.kind, HerdrControlKind.healthPing)
        await connection.setAppActive(false)
    }

    /// In the background an alive check doesn't run out: a suspended phone reads nothing, so a reply may
    /// be waiting unread. Back in the foreground its limit starts over, and its reply answers it.
    func testAnAliveCheckWaitsOutTheBackground() async throws {
        let (connection, transport, events) = try await openedSession(
            surfaceActive: true,
            timing: timing(unansweredPing: .milliseconds(100))
        )
        await transport.serve(HerdrWire.frame([9, 1]))
        await events.waitForCount(2)
        let answer = AnswerBox()
        let check = Task { await answer.set(await connection.confirmAlive()) }
        let ping = try Self.control(try await transport.written(1))
        try await Task.sleep(for: .milliseconds(400))
        let ended = await events.hasEnded
        XCTAssertFalse(ended, "the check ran out in the background")

        await connection.setAppActive(true)
        _ = try await transport.written(2)
        await transport.serve(Self.pong(ping.data))
        await check.value
        let answered = await answer.value
        XCTAssertEqual(answered, true)
        await connection.setAppActive(false)
    }

    // MARK: - Closing

    /// Closing takes over before anything can wait: a write stuck in the transport, a request queued
    /// behind it and the stream ending meanwhile bring no `ended` event, and nothing more is written.
    func testCloseDoesNotWaitOnTheTransportOrReportAnEnd() async throws {
        let (connection, transport, events) = try await openedSession(surfaceActive: true)
        await transport.stallWrites()
        try await connection.send([.text("a")], toPane: "w1:p1")
        await transport.waitForStalledWrites(1)
        connection.outbox.send([try HerdrClientMessage.endpointRequest(
            bootID: "boot",
            id: "c1",
            method: HerdrScreenModel.paneFocusMethod,
            params: ["pane_id": "w1:p1"]
        )])

        await connection.close(.finished)
        let closes = await transport.closes
        XCTAssertEqual(closes, [.finished])
        let written = await transport.writtenCount
        XCTAssertEqual(written, 1, "only the hello")
        try await Task.sleep(for: .milliseconds(30))
        let ended = await events.hasEnded
        XCTAssertFalse(ended)
    }

    /// A close also covers an end found earlier (here a failed write) that the screen hasn't been told
    /// about yet because it still holds a message: no `ended` event follows.
    func testCloseAfterAnEndTheScreenHasNotSeenReportsNothing() async throws {
        let (connection, transport, events) = try await openedSession(surfaceActive: true)
        await events.hold()
        await transport.serve(HerdrWire.frame([9, 1]))
        await events.waitForCount(2)
        await transport.failWrites(with: NotInstalled())
        try await connection.send([.text("a")], toPane: "w1:p1")
        var waited = 0
        while !(await transport.isClosed), waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let closedByTheFailure = await transport.isClosed
        XCTAssertTrue(closedByTheFailure)

        await connection.close(.finished)
        await events.release()
        try await Task.sleep(for: .milliseconds(50))
        let ended = await events.hasEnded
        XCTAssertFalse(ended)
    }

    // MARK: - Reading

    /// The next read waits until the screen has taken every message of the previous one.
    func testReadsWaitForTheScreen() async throws {
        let (_, transport, events) = try await openedSession(surfaceActive: true)
        try await Task.sleep(for: .milliseconds(30))
        await events.hold()
        // The reader is parked in a read that the next chunk completes.
        let readsBefore = await transport.reads
        await transport.serve(HerdrWire.frame([9, 1]) + HerdrWire.frame([9, 2]))
        // The snapshot, then the first bell, whose delivery the screen holds.
        await events.waitForCount(2)
        try await Task.sleep(for: .milliseconds(30))
        let readsWhileHeld = await transport.reads
        XCTAssertEqual(readsWhileHeld, readsBefore)
        await events.release()
        await events.waitForCount(3)
        let readsAfter = await transport.waitForReads(readsBefore + 1)
        XCTAssertEqual(readsAfter, readsBefore + 1)
    }

    /// As Herdr's client: a binary snapshot ends the connection; a type for other kinds of client is
    /// skipped.
    func testABinarySnapshotEndsTheConnectionAndOtherClientsTypesAreSkipped() async throws {
        let (_, transport, events) = try await openedSession(surfaceActive: true)
        await transport.serve(HerdrWire.frame([1, 0xAA]) + HerdrWire.frame([9, 1]) + HerdrWire.frame([12]))
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "bell", "ended(\(HerdrConnectionError.wire(.unnegotiatedSnapshot)))"])
    }

    /// While hidden, bells, clipboard writes and input refusals are dropped, as in Herdr's client;
    /// snapshots still arrive.
    func testAHiddenSessionDropsBellsAndClipboardWrites() async throws {
        let (_, transport, events) = try await openedSession(surfaceActive: false)
        var clipboard = HerdrWireWriter()
        clipboard.variant(5)
        clipboard.string("aGk")
        var refused = HerdrWireWriter()
        refused.variant(15)
        refused.string("too large")
        let snapshot = try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))[2]
        await transport.serve(
            HerdrWire.frame([9, 1]) + HerdrWire.frame(clipboard.bytes) + HerdrWire.frame(refused.bytes)
                + HerdrWire.frame(snapshot)
        )
        await events.waitForCount(2)
        let kinds = await events.events.map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "snapshot"])
    }

    /// A snapshot carries the agent completions Herdr sent just before it, as the recorded server sends
    /// them, for its own boot and revision: a snapshot sent without them carries none, they never carry
    /// over to a later snapshot, and an older revision arriving late doesn't replace newer ones.
    func testASnapshotCarriesTheAgentCompletionsSentForIt() async throws {
        let recorded = try Self.frames(Self.recording("herdr-12-notification-A"))
        guard case .control(let kind, let data) = try HerdrServerMessage.decode(recorded[2]),
              case .snapshot(let first) = try HerdrEndpointControl.parse(kind: kind, data: data)
        else { return XCTFail("the recording's third message isn't its snapshot") }
        let boot = first.bootID
        let transport = FakeBridgeTransport()
        await transport.serve(recorded[0..<3].flatMap(HerdrWire.frame))
        let events = EventRecorder()
        let connection = try await HerdrConnection.open(
            transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: events.record
        )
        addTeardownBlock {
            await events.release()
            await connection.close(.finished)
        }

        await transport.serve(
            HerdrServerScript.agentCompletions(revision: 2, boot: boot, ["w1:p1": 5])
                + HerdrServerScript.snapshot(revision: 2, boot: boot)
                + HerdrServerScript.snapshot(revision: 3, boot: boot)
                + HerdrServerScript.agentCompletions(revision: 5, boot: boot, ["w1:p1": 7])
                + HerdrServerScript.snapshot(revision: 4, boot: boot)
                + HerdrServerScript.snapshot(revision: 5, boot: boot)
                + HerdrServerScript.agentCompletions(revision: 6, boot: "another", ["w1:p1": 8])
                + HerdrServerScript.snapshot(revision: 6, boot: boot)
                + HerdrServerScript.agentCompletions(revision: 8, boot: boot, ["w1:p1": 9])
                + HerdrServerScript.agentCompletions(revision: 7, boot: boot, ["w1:p1": 1])
                + HerdrServerScript.snapshot(revision: 8, boot: boot)
        )
        await events.waitForCount(7)
        let completions = await events.events.compactMap { event -> [String: UInt64]?? in
            guard case .snapshot(_, let completions) = event else { return nil }
            return completions
        }
        XCTAssertEqual(completions, [[:], ["w1:p1": 5], nil, nil, nil, nil, ["w1:p1": 9]])
    }

    /// An end found by another part of the connection (here a failed write) is reported only after the
    /// screen has taken the message it holds.
    func testTheEndIsReportedAfterTheScreenTakesWhatItHolds() async throws {
        let (connection, transport, events) = try await openedSession(surfaceActive: true)
        await events.hold()
        await transport.serve(HerdrWire.frame([9, 1]))
        await events.waitForCount(2)
        await transport.failWrites(with: NotInstalled())
        try await connection.send([.text("a")], toPane: "w1:p1")
        try await Task.sleep(for: .milliseconds(50))
        let endedWhileHeld = await events.hasEnded
        XCTAssertFalse(endedWhileHeld)
        await events.release()
        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "bell", "ended(\(HerdrConnectionError.transport(NotInstalled.text)))"])
    }

    // MARK: - Helpers

    /// A connection after the recorded welcome and snapshot of the all-capabilities session.
    private func openedSession(
        surfaceActive: Bool,
        timing: HerdrConnection.Timing? = nil
    ) async throws -> (HerdrConnection, FakeBridgeTransport, EventRecorder) {
        let frames = try Self.frames(Self.recording("herdr-01-handshake-all-caps-A"))
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame(frames[0]) + HerdrWire.frame(frames[2]))
        let events = EventRecorder()
        let hello = HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 40, rows: 12, surfaceActive: surfaceActive)
        let connection = try await HerdrConnection.open(
            transport: transport,
            hello: hello,
            appActive: false,
            timing: timing ?? relaxed,
            onEvent: events.record
        )
        addTeardownBlock {
            await events.release()
            await connection.close(.finished)
        }
        await events.waitForCount(1)
        return (connection, transport, events)
    }

    static func recording(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: HerdrConnectionTests.self).url(forResource: name, withExtension: "s2c.bin"))
        return Array(try Data(contentsOf: url))
    }

    static func frames(_ stream: [UInt8]) throws -> [[UInt8]] {
        var splitter = HerdrFrameSplitter()
        splitter.append(stream)
        var payloads = [[UInt8]]()
        while let payload = try splitter.nextPayload() {
            payloads.append(payload)
        }
        return payloads
    }

    static func chunk(id: String, data: [UInt8], final: Bool) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(18)
        writer.string("68169-1791562319387415000")
        writer.string(id)
        writer.bool(final)
        writer.byteArray(data)
        return HerdrWire.frame(writer.bytes)
    }

    static func reply(id: String, json result: String) -> [UInt8] {
        chunk(id: id, data: Array(#"{"id":"\#(id)","result":\#(result)}"#.utf8), final: true)
    }

    static func reply(id: String, error: (code: String, message: String)) -> [UInt8] {
        chunk(id: id, data: Array(#"{"id":"\#(id)","error":{"code":"\#(error.code)","message":"\#(error.message)"}}"#.utf8), final: true)
    }

    /// The recorded welcome without one capability.
    static func welcome(removing capability: String) throws -> [UInt8] {
        var reader = HerdrWireReader(try frames(recording("herdr-01-handshake-all-caps-A"))[0])
        _ = try reader.variant()
        _ = try reader.string()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try reader.string().utf8)) as? [String: Any])
        var edited = json
        edited["capabilities"] = (json["capabilities"] as? [String] ?? []).filter { $0 != capability }
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(HerdrControlKind.welcome)
        writer.string(String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self))
        return HerdrWire.frame(writer.bytes)
    }

    struct NotInstalled: LocalizedError {
        static let text = "Herdr isn't installed on this server."
        var errorDescription: String? { Self.text }
    }

    static func pong(_ data: String) -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(HerdrControlKind.healthPong)
        writer.string(data)
        return HerdrWire.frame(writer.bytes)
    }

    struct Request: Decodable {
        let id: String
        let method: String
        let params: [String: Bool]?

        private enum CodingKeys: String, CodingKey {
            case id, method, params
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            method = try container.decode(String.self, forKey: .method)
            params = try? container.decode([String: Bool].self, forKey: .params)
        }
    }

    static func request(_ frame: [UInt8]) throws -> Request {
        var reader = HerdrWireReader(Array(frame.dropFirst(4)))
        XCTAssertEqual(try reader.variant(), 15)
        _ = try reader.string()
        return try JSONDecoder().decode(Request.self, from: Data(try reader.string().utf8))
    }

    static func control(_ frame: [UInt8]) throws -> (kind: String, data: String) {
        var reader = HerdrWireReader(Array(frame.dropFirst(4)))
        XCTAssertEqual(try reader.variant(), 20)
        return (try reader.string(), try reader.string())
    }
}

/// A bridge whose reads wait until the test serves bytes.
actor FakeBridgeTransport: HerdrBridgeTransport {
    private var chunks: [[UInt8]] = []
    private var readers: [CheckedContinuation<[UInt8]?, Error>] = []
    private var writes: [[UInt8]] = []
    private var writeWaiters: [(Int, CheckedContinuation<[UInt8], Error>)] = []
    private var ended = false
    private var failure: Error?
    private var writeFailure: Error?
    private var stallsWrites = false
    private var stalledWrites: [CheckedContinuation<Void, Error>] = []
    private var closeWaiters: [(UInt64, CheckedContinuation<Bool, Never>)] = []
    private var nextCloseWaiter: UInt64 = 0
    private(set) var reads = 0
    private(set) var isClosed = false
    /// Every close's cause, in order.
    private(set) var closes: [HerdrBridgeCloseCause] = []

    var writtenCount: Int { writes.count }

    func serve(_ bytes: [UInt8]) {
        if readers.isEmpty {
            chunks.append(bytes)
        } else {
            readers.removeFirst().resume(returning: bytes)
        }
    }

    func serve(_ bytes: [UInt8], inChunksOf size: Int) {
        stride(from: 0, to: bytes.count, by: size).forEach { serve(Array(bytes[$0..<min($0 + size, bytes.count)])) }
    }

    /// Ends the stream, cleanly or with `error`, after the chunks already served.
    func finishServing(throwing error: Error? = nil) {
        ended = true
        failure = error
        for reader in readers {
            if let error {
                reader.resume(throwing: error)
            } else {
                reader.resume(returning: nil)
            }
        }
        readers.removeAll()
    }

    func failWrites(with error: Error) {
        writeFailure = error
    }

    /// The write at `index`, waiting up to two seconds for it.
    func written(_ index: Int) async throws -> [UInt8] {
        if index < writes.count { return writes[index] }
        return try await withCheckedThrowingContinuation { continuation in
            writeWaiters.append((index, continuation))
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.expireWaiter(index)
            }
        }
    }

    private func expireWaiter(_ index: Int) {
        guard let position = writeWaiters.firstIndex(where: { $0.0 == index }) else { return }
        writeWaiters.remove(at: position).1.resume(throwing: CancellationError())
    }

    /// The read count once it reaches `count`, or after two seconds.
    func waitForReads(_ count: Int) async -> Int {
        for _ in 0..<200 where reads < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reads
    }

    /// Writes from now on wait until the transport closes and then fail, as on a stalled network.
    func stallWrites() {
        stallsWrites = true
    }

    /// Returns once `count` writes are stalled, or after two seconds.
    func waitForStalledWrites(_ count: Int) async {
        for _ in 0..<200 where stalledWrites.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func read() async throws -> [UInt8]? {
        reads += 1
        if !chunks.isEmpty { return chunks.removeFirst() }
        if ended {
            if let failure { throw failure }
            return nil
        }
        return try await withCheckedThrowingContinuation { readers.append($0) }
    }

    func write(_ bytes: [UInt8]) async throws {
        if let writeFailure { throw writeFailure }
        if stallsWrites {
            guard !isClosed else { throw CancellationError() }
            try await withCheckedThrowingContinuation { stalledWrites.append($0) }
        }
        writes.append(bytes)
        let ready = writeWaiters.filter { $0.0 < writes.count }
        writeWaiters.removeAll { $0.0 < writes.count }
        ready.forEach { $0.1.resume(returning: writes[$0.0]) }
    }

    func close(_ cause: HerdrBridgeCloseCause) async {
        closes.append(cause)
        isClosed = true
        stalledWrites.forEach { $0.resume(throwing: CancellationError()) }
        stalledWrites.removeAll()
        closeWaiters.forEach { $0.1.resume(returning: true) }
        closeWaiters.removeAll()
        finishServing()
    }

    /// Whether the transport closed, waiting up to two seconds for its first close.
    func closed() async -> Bool {
        guard closes.isEmpty else { return true }
        nextCloseWaiter += 1
        let id = nextCloseWaiter
        return await withCheckedContinuation { continuation in
            closeWaiters.append((id, continuation))
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.expireCloseWaiter(id)
            }
        }
    }

    private func expireCloseWaiter(_ id: UInt64) {
        guard let position = closeWaiters.firstIndex(where: { $0.0 == id }) else { return }
        closeWaiters.remove(at: position).1.resume(returning: false)
    }
}

extension HerdrConnection {
    /// A connection over `transport`, once it has opened.
    static func open(
        transport: any HerdrBridgeTransport,
        hello: HerdrHello,
        appActive: Bool,
        timing: Timing = Timing(),
        onEvent: @escaping @Sendable (HerdrConnectionEvent) async -> Void
    ) async throws -> HerdrConnection {
        let connection = HerdrConnection(transport: transport, timing: timing, onEvent: onEvent)
        try await connection.open(hello: hello, appActive: appActive)
        return connection
    }
}

/// An answer that arrives later, or nil while it hasn't.
actor AnswerBox {
    private(set) var value: Bool?

    func set(_ answer: Bool) {
        value = answer
    }
}

/// Records connection events; `hold()` makes delivery wait, as a busy screen would.
actor EventRecorder {
    private(set) var events: [HerdrConnectionEvent] = []
    private var held = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var hasEnded: Bool {
        events.contains { if case .ended = $0 { return true } else { return false } }
    }

    nonisolated func record(_ event: HerdrConnectionEvent) async {
        await append(event)
    }

    private func append(_ event: HerdrConnectionEvent) async {
        events.append(event)
        let ready = countWaiters.filter { $0.0 <= events.count }
        countWaiters.removeAll { $0.0 <= events.count }
        ready.forEach { $0.1.resume() }
        if held {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func hold() { held = true }

    func release() {
        held = false
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func waitForCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func waitForEnd() async -> [HerdrConnectionEvent] {
        while !hasEnded {
            await waitForCount(events.count + 1)
        }
        return events
    }
}

extension HerdrConnectionEvent {
    var kind: String {
        switch self {
        case .snapshot: return "snapshot"
        case .surface(.surface): return "surface.full"
        case .surface(.patch): return "surface.patch"
        case .bell: return "bell"
        case .notification: return "notification"
        case .clipboard: return "clipboard"
        case .inputRefused: return "inputRefused"
        case .keyboardReportAll(let enabled): return "keyboardReportAll(\(enabled))"
        case .response(let chunk): return "response(\(chunk.requestID)\(chunk.isFinal ? ", final" : ""))"
        case .pong(let data): return "pong(\(data))"
        case .ended(let error):
            switch error {
            case .serverShutdown: return "ended(serverShutdown)"
            case .unresponsive: return "ended(unresponsive)"
            default: return "ended(\(error))"
            }
        }
    }
}
