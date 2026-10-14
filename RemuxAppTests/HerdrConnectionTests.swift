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
        healthTick: .milliseconds(10),
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
        command: Duration = .seconds(10),
        activation: Duration = .seconds(10)
    ) -> HerdrConnection.Timing {
        HerdrConnection.Timing(
            welcome: welcome,
            pingAfterSilence: pingAfterSilence,
            unansweredPing: unansweredPing,
            firstSnapshot: firstSnapshot,
            healthTick: .milliseconds(10),
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

        XCTAssertEqual(connection.negotiated.methods.count, 40)
        XCTAssertEqual(connection.negotiated.serverVersion, "0.9.3")
        XCTAssertTrue(connection.negotiated.delta)
        XCTAssertTrue(connection.negotiated.scroll)
        let first = try await transport.written(0)
        XCTAssertEqual(first, HerdrClientMessage.hello(hello).frame)

        let kinds = await events.waitForEnd().map(\.kind)
        XCTAssertEqual(kinds, ["snapshot", "surface.full", "ended(serverShutdown)"])
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
        // No answer means the path may be dead: the SSH connection isn't reused.
        let reusable = await transport.closedReusable
        XCTAssertEqual(reusable, false)
    }

    /// An old server answers the hello with the binary welcome; Herdr's client asks for an update.
    func testAnOldServerIsAskedToUpdate() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(HerdrWire.frame([0, 1, 2]))
        do {
            _ = try await HerdrConnection.open(transport: transport, hello: hello, appActive: false, timing: relaxed, onEvent: { _ in })
            XCTFail("opened")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .incompatible("its Herdr needs an update"))
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
            XCTAssertEqual(error, .incompatible("its Herdr 0.9.3 needs an update"))
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

    /// A read doesn't end when its task is cancelled, so cancelling the open closes the transport.
    func testCancellingTheOpenClosesTheTransportAndOpensNothing() async throws {
        let transport = FakeBridgeTransport()
        let (sentHello, slowTiming) = (hello, relaxed)
        let opening = Task {
            try await HerdrConnection.open(transport: transport, hello: sentHello, appActive: false, timing: slowTiming, onEvent: { _ in })
        }
        _ = try await transport.written(0)
        opening.cancel()
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
        let closed = await transport.isClosed
        XCTAssertTrue(closed)
    }

    // MARK: - Showing, hiding and input

    /// Show sends resize, `surface.set(true)` and focus in Herdr's client order; hide sends focus first.
    func testShowAndHideFollowHerdrsOrder() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: false)
        let geometry = HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 40, rows: 12)

        async let floor = connection.show(geometry)
        let resize = try await transport.written(1)
        let set = try await transport.written(2)
        let focus = try await transport.written(3)
        XCTAssertEqual(resize, HerdrClientMessage.shellResize(geometry).frame)
        let request = try Self.request(set)
        XCTAssertEqual(request.method, "client_shell.surface.set")
        XCTAssertEqual(request.params, ["active": true])
        XCTAssertEqual(focus, HerdrClientMessage.focus(true).frame)
        await transport.serve(Self.reply(id: request.id, json: #"{"type":"client_shell_surface_set","active":true,"projection_revision":4}"#))
        let revision = try await floor
        XCTAssertEqual(revision, 4)

        async let hidden: Void = connection.hide()
        let unfocus = try await transport.written(4)
        let unset = try Self.request(try await transport.written(5))
        XCTAssertEqual(unfocus, HerdrClientMessage.focus(false).frame)
        XCTAssertEqual(unset.params, ["active": false])
        await transport.serve(Self.reply(id: unset.id, json: #"{"type":"client_shell_surface_set","active":false,"projection_revision":4}"#))
        try await hidden
    }

    /// As Herdr's client, a show asks for at least one cell each way.
    func testShowAsksForAtLeastOneCell() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: false)
        async let floor = connection.show(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 0, rows: 0))
        let resize = try await transport.written(1)
        XCTAssertEqual(resize, HerdrClientMessage.shellResize(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 1, rows: 1)).frame)
        let set = try Self.request(try await transport.written(2))
        await transport.serve(Self.reply(id: set.id, json: #"{"type":"client_shell_surface_set","active":true,"projection_revision":2}"#))
        _ = try await floor
    }

    /// A show Herdr doesn't acknowledge in time, or acknowledges as inactive, is rolled back as
    /// Herdr's client rolls it back: focus off, then the surface off; input is refused again.
    func testAnUnacknowledgedShowIsRolledBack() async throws {
        for answer in [nil, #"{"type":"client_shell_surface_set","active":false,"projection_revision":2}"#] {
            let (connection, transport, _) = try await openedSession(surfaceActive: false, timing: timing(activation: .milliseconds(100)))
            async let floor = connection.show(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 40, rows: 12))
            let set = try Self.request(try await transport.written(2))
            if let answer {
                await transport.serve(Self.reply(id: set.id, json: answer))
            }
            do {
                _ = try await floor
                XCTFail("shown")
            } catch let error as HerdrCommandError {
                XCTAssertEqual(error, answer == nil ? .timedOut(method: "client_shell.surface.set") : .notAcknowledged)
            }
            let unfocus = try await transport.written(4)
            XCTAssertEqual(unfocus, HerdrClientMessage.focus(false).frame)
            let release = try Self.request(try await transport.written(5))
            XCTAssertEqual(release.params, ["active": false])
            do {
                try await connection.send([.text("a")], toPane: "w1:p1")
                XCTFail("sent")
            } catch let error as HerdrInputError {
                XCTAssertEqual(error, .inactive)
            }
        }
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

    // MARK: - Commands

    /// One command at a time; the second goes out only once the first's final chunk arrives.
    func testCommandsRunOneAtATimeAndJoinChunks() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        async let first = connection.command("pane.focus", params: ["pane_id": "w1:p1"])
        let firstRequest = try Self.request(try await transport.written(1))
        async let second = connection.command("tab.focus", params: ["tab_id": "w1:t1"])
        try await Task.sleep(for: .milliseconds(30))
        let count = await transport.writtenCount
        XCTAssertEqual(count, 2)

        let body = Array(#"{"id":"\#(firstRequest.id)","result":{"type":"ok"}}"#.utf8)
        await transport.serve(Self.chunk(id: firstRequest.id, data: Array(body.prefix(10)), final: false))
        await transport.serve(Self.chunk(id: firstRequest.id, data: Array(body.dropFirst(10)), final: true))
        let firstReply = try await first
        XCTAssertEqual(firstReply, Data(body))

        let secondRequest = try Self.request(try await transport.written(2))
        XCTAssertEqual(secondRequest.method, "tab.focus")
        await transport.serve(Self.reply(id: secondRequest.id, error: ("not_found", "no tab")))
        do {
            _ = try await second
            XCTFail("succeeded")
        } catch let error as HerdrCommandError {
            XCTAssertEqual(error, .failed(code: "not_found", message: "no tab"))
        }
    }

    /// As Herdr's client, a timed-out command frees the lane for the next one, and its late reply is
    /// dropped instead of answering anything else.
    func testATimedOutCommandFreesTheLaneAndItsLateReplyIsDropped() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true, timing: timing(command: .milliseconds(100)))
        do {
            _ = try await connection.command("worktree.list", params: [String: String]())
            XCTFail("answered")
        } catch let error as HerdrCommandError {
            XCTAssertEqual(error, .timedOut(method: "worktree.list"))
        }
        let slow = try Self.request(try await transport.written(1))
        async let next = connection.command("pane.focus", params: ["pane_id": "w1:p1"])
        let nextRequest = try Self.request(try await transport.written(2))
        XCTAssertEqual(nextRequest.method, "pane.focus")
        await transport.serve(Self.reply(id: slow.id, json: #"{"type":"late"}"#))
        await transport.serve(Self.reply(id: nextRequest.id, json: #"{"type":"ok"}"#))
        let answer = try await next
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), #"{"id":"\#(nextRequest.id)","result":{"type":"ok"}}"#)
    }

    /// A command cancelled while it waits for the lane is never sent.
    func testACommandCancelledInLineIsNeverSent() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        async let first = connection.command("worktree.list", params: [String: String]())
        let firstRequest = try Self.request(try await transport.written(1))
        let queued = Task { try await connection.command("tab.focus", params: ["tab_id": "w1:t1"]) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("answered")
        } catch is CancellationError {}

        await transport.serve(Self.reply(id: firstRequest.id, json: #"{"type":"ok"}"#))
        _ = try await first
        async let next = connection.command("pane.focus", params: ["pane_id": "w1:p1"])
        let nextRequest = try Self.request(try await transport.written(2))
        XCTAssertEqual(nextRequest.method, "pane.focus")
        await transport.serve(Self.reply(id: nextRequest.id, json: #"{"type":"ok"}"#))
        _ = try await next
    }

    /// A command cancelled after it was sent returns at once; its late reply still frees the lane.
    func testACancelledSentCommandReturnsAtOnceAndItsReplyFreesTheLane() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        let slow = Task { try await connection.command("worktree.list", params: [String: String]()) }
        let slowRequest = try Self.request(try await transport.written(1))
        slow.cancel()
        do {
            _ = try await slow.value
            XCTFail("answered")
        } catch is CancellationError {}

        async let next = connection.command("pane.focus", params: ["pane_id": "w1:p1"])
        try await Task.sleep(for: .milliseconds(30))
        let count = await transport.writtenCount
        XCTAssertEqual(count, 2)
        await transport.serve(Self.reply(id: slowRequest.id, json: #"{"type":"ok"}"#))
        let nextRequest = try Self.request(try await transport.written(2))
        XCTAssertEqual(nextRequest.method, "pane.focus")
        await transport.serve(Self.reply(id: nextRequest.id, json: #"{"type":"ok"}"#))
        _ = try await next
    }

    func testAMethodTheServerDoesNotAdvertiseFailsAlone() async throws {
        let (connection, _, events) = try await openedSession(surfaceActive: true)
        do {
            _ = try await connection.command("pane.read", params: [String: String]())
            XCTFail("sent")
        } catch let error as HerdrCommandError {
            XCTAssertEqual(error, .unsupported(method: "pane.read"))
        }
        let ended = await events.hasEnded
        XCTAssertFalse(ended)
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
        let reusable = await transport.closedReusable
        XCTAssertEqual(reusable, false)
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
        addTeardownBlock { await connection.close() }
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

    func testConfirmAliveIsAnsweredByItsOwnPong() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true)
        async let alive = connection.confirmAlive()
        let ping = try Self.control(try await transport.written(1))
        await transport.serve(Self.pong(ping.data))
        let answered = await alive
        XCTAssertTrue(answered)
    }

    func testAnotherPongDoesNotConfirmAlive() async throws {
        let (connection, transport, _) = try await openedSession(surfaceActive: true, timing: timing(unansweredPing: .milliseconds(200)))
        async let alive = connection.confirmAlive()
        _ = try await transport.written(1)
        await transport.serve(Self.pong("not-this-one"))
        let answered = await alive
        XCTAssertFalse(answered)
    }

    // MARK: - Closing

    /// Closing takes over before anything can wait: a write stuck in the transport, a command waiting
    /// for its reply and the stream ending meanwhile bring no `ended` event, and nothing more is written.
    func testCloseDoesNotWaitOnTheTransportOrReportAnEnd() async throws {
        let (connection, transport, events) = try await openedSession(surfaceActive: true)
        await transport.stallWrites()
        try await connection.send([.text("a")], toPane: "w1:p1")
        await transport.waitForStalledWrites(1)
        let command = Task { try await connection.command("pane.focus", params: ["pane_id": "w1:p1"]) }

        await connection.close()
        do {
            _ = try await command.value
            XCTFail("answered")
        } catch let error as HerdrCommandError {
            XCTAssertEqual(error, .connectionEnded)
        }
        let reusable = await transport.closedReusable
        XCTAssertEqual(reusable, true)
        let written = await transport.writtenCount
        XCTAssertEqual(written, 1, "only the hello")
        try await Task.sleep(for: .milliseconds(30))
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
            await connection.close()
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
    private(set) var reads = 0
    private(set) var isClosed = false
    /// What the first close said about reusing the connection underneath.
    private(set) var closedReusable: Bool?

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

    func close(reusable: Bool) async {
        if !isClosed { closedReusable = reusable }
        isClosed = true
        stalledWrites.forEach { $0.resume(throwing: CancellationError()) }
        stalledWrites.removeAll()
        finishServing()
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
        case .surface(.full): return "surface.full"
        case .surface(.patch): return "surface.patch"
        case .surface(.reuse): return "surface.reuse"
        case .surface(.delta): return "surface.delta"
        case .surface(.scroll): return "surface.scroll"
        case .bell: return "bell"
        case .notification: return "notification"
        case .clipboard: return "clipboard"
        case .inputRefused: return "inputRefused"
        case .ended(let error):
            switch error {
            case .serverShutdown: return "ended(serverShutdown)"
            case .unresponsive: return "ended(unresponsive)"
            default: return "ended(\(error))"
            }
        }
    }
}
