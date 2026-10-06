import Combine
import AVFoundation
import XCTest
@testable import Remux

@MainActor
final class GhosttyComposerDictationControllerTests: XCTestCase {
    func testCaptureBoundaryStartsOnlyAfterFirstForwardedBuffer() throws {
        var boundary = GhosttyComposerAudioCaptureBoundary()
        let buffer = try captureBuffer(frameLength: 4_800)
        let startHostTime = AVAudioTime.hostTime(forSeconds: 10)
        let time = AVAudioTime(
            hostTime: startHostTime,
            sampleTime: 0,
            atRate: 48_000
        )

        XCTAssertEqual(
            boundary.didForward(buffer, at: time, deliveredAt: startHostTime),
            .recording(firstBuffer: true)
        )
        XCTAssertEqual(
            boundary.didForward(
                buffer,
                at: AVAudioTime(
                    hostTime: startHostTime + AVAudioTime.hostTime(forSeconds: 0.1),
                    sampleTime: 4_800,
                    atRate: 48_000
                ),
                deliveredAt: startHostTime + AVAudioTime.hostTime(forSeconds: 0.1)
            ),
            .recording(firstBuffer: false)
        )
    }

    func testCaptureBoundaryWaitsUntilForwardedAudioCoversStopTime() throws {
        var boundary = GhosttyComposerAudioCaptureBoundary()
        let buffer = try captureBuffer(frameLength: 4_800)
        let startHostTime = AVAudioTime.hostTime(forSeconds: 10)
        let bufferDuration = AVAudioTime.hostTime(forSeconds: 0.1)
        let stopHostTime = startHostTime + AVAudioTime.hostTime(forSeconds: 0.15)

        XCTAssertTrue(boundary.requestStop(at: stopHostTime))
        XCTAssertEqual(
            boundary.didForward(
                buffer,
                at: AVAudioTime(
                    hostTime: startHostTime,
                    sampleTime: 0,
                    atRate: 48_000
                ),
                deliveredAt: startHostTime + bufferDuration
            ),
            .draining
        )
        XCTAssertEqual(
            boundary.didForward(
                buffer,
                at: AVAudioTime(
                    hostTime: startHostTime + bufferDuration,
                    sampleTime: 4_800,
                    atRate: 48_000
                ),
                deliveredAt: startHostTime + (bufferDuration * 2)
            ),
            .covered
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(boundary.latestCoveredHostTime),
            stopHostTime
        )
    }

    func testCaptureBoundaryExtrapolatesHostTimeFromCompleteAnchor() throws {
        var boundary = GhosttyComposerAudioCaptureBoundary()
        let buffer = try captureBuffer(frameLength: 4_800)
        let startHostTime = AVAudioTime.hostTime(forSeconds: 10)
        let bufferDuration = AVAudioTime.hostTime(forSeconds: 0.1)

        _ = boundary.didForward(
            buffer,
            at: AVAudioTime(
                hostTime: startHostTime,
                sampleTime: 0,
                atRate: 48_000
            ),
            deliveredAt: startHostTime + bufferDuration
        )
        XCTAssertTrue(
            boundary.requestStop(
                at: startHostTime + AVAudioTime.hostTime(forSeconds: 0.15)
            )
        )

        XCTAssertEqual(
            boundary.didForward(
                buffer,
                at: AVAudioTime(sampleTime: 4_800, atRate: 48_000),
                deliveredAt: startHostTime + (bufferDuration * 2)
            ),
            .covered
        )
        XCTAssertTrue(boundary.hasReliableTimeline)
    }

    func testCaptureBoundaryUsesMeasuredCadenceForHardwareWatchdog() throws {
        var boundary = GhosttyComposerAudioCaptureBoundary()
        let buffer = try captureBuffer(frameLength: 4_800)
        let startHostTime = AVAudioTime.hostTime(forSeconds: 10)
        let interval = AVAudioTime.hostTime(forSeconds: 0.12)

        _ = boundary.didForward(
            buffer,
            at: AVAudioTime(
                hostTime: startHostTime,
                sampleTime: 0,
                atRate: 48_000
            ),
            deliveredAt: startHostTime
        )
        _ = boundary.didForward(
            buffer,
            at: AVAudioTime(
                hostTime: startHostTime + interval,
                sampleTime: 5_760,
                atRate: 48_000
            ),
            deliveredAt: startHostTime + interval
        )

        XCTAssertEqual(boundary.drainWatchdogDuration, 0.6, accuracy: 0.001)
    }

    func testCaptureBoundaryCountsDroppedSampleFrames() throws {
        var boundary = GhosttyComposerAudioCaptureBoundary()
        let buffer = try captureBuffer(frameLength: 4_800)
        let startHostTime = AVAudioTime.hostTime(forSeconds: 10)

        _ = boundary.didForward(
            buffer,
            at: AVAudioTime(
                hostTime: startHostTime,
                sampleTime: 0,
                atRate: 48_000
            ),
            deliveredAt: startHostTime
        )
        _ = boundary.didForward(
            buffer,
            at: AVAudioTime(
                hostTime: startHostTime + AVAudioTime.hostTime(forSeconds: 0.125),
                sampleTime: 6_000,
                atRate: 48_000
            ),
            deliveredAt: startHostTime + AVAudioTime.hostTime(forSeconds: 0.125)
        )

        XCTAssertEqual(boundary.droppedSampleFrames, 1_200)
    }

    func testProgressiveTranscriptPreservesFinalizedPassages() {
        var transcript = GhosttyComposerProgressiveTranscript()

        transcript.apply(AttributedString("First draft"), isFinal: false)
        transcript.apply(AttributedString("First passage. "), isFinal: true)
        transcript.apply(AttributedString("Second dra"), isFinal: false)
        XCTAssertEqual(transcript.text, "First passage. Second dra")

        transcript.apply(AttributedString("Second passage."), isFinal: true)
        XCTAssertEqual(transcript.text, "First passage. Second passage.")
    }

    func testHypothesisBecomesDraftWhenSnapshotIsEmpty() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "",
                hypothesis: "Check the build"
            ),
            "Check the build"
        )
    }

    func testHypothesisIsSeparatedFromExistingDraft() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Open the project",
                hypothesis: "then run the tests"
            ),
            "Open the project then run the tests"
        )
    }

    func testExistingWhitespaceIsNotDuplicated() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Open the project\n",
                hypothesis: "Then run the tests"
            ),
            "Open the project\nThen run the tests"
        )
    }

    func testEmptyPartialPreservesSnapshot() {
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: "Keep this draft",
                hypothesis: ""
            ),
            "Keep this draft"
        )
    }

    func testNewPartialReplacesPreviousPartialInsteadOfAppending() {
        let snapshot = "Please"

        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: snapshot,
                hypothesis: "review"
            ),
            "Please review"
        )
        XCTAssertEqual(
            GhosttyComposerDictationDraft.merging(
                snapshot: snapshot,
                hypothesis: "review this change"
            ),
            "Please review this change"
        )
    }

    func testAuthorizationTimeDoesNotConsumeBackendStartDeadline() async {
        let backend = DictationBackendSpy(startEvent: .started)
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .delayedAuthorization(.milliseconds(80)),
            startDeadline: .milliseconds(20)
        )
        var failures: [String] = []

        controller.start(
            draft: "",
            onTranscript: { _ in },
            onFailure: { failures.append($0) }
        )

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(controller.phase, .starting)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(backend.actions.isEmpty)

        await waitUntil { controller.phase == .recording }
        XCTAssertTrue(failures.isEmpty)
        controller.stopImmediately()
    }

    func testModernBackendAuthorizationOnlyRequestsMicrophoneAccess() async {
        let client = GhosttyComposerDictationAuthorizationClient(
            knownResult: { _ in nil },
            requestSpeechAuthorization: {
                XCTFail("SpeechAnalyzer must not request SFSpeechRecognizer authorization")
                return .denied
            },
            requestMicrophoneAuthorization: { true }
        )

        let result = await client.resolve(requiresSpeechRecognition: false)

        guard case .authorized = result else {
            return XCTFail("Expected microphone-only authorization to succeed")
        }
    }

    func testKnownAuthorizationStartsBackendWithoutTaskHop() {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests
        )

        controller.start(draft: "", onTranscript: { _ in }, onFailure: { _ in })

        XCTAssertEqual(backend.actions, [.start(1)])
        controller.stopImmediately()
    }

#if DEBUG
    func testDebugBackendExercisesControllerLifecycle() async {
        let transcript = "Review the current changes"
        let controller = GhosttyComposerDictationController(
            backend: GhosttyDebugComposerDictationBackend(
                configuration: GhosttyDebugComposerDictationConfiguration(
                    transcript: transcript
                )
            ),
            authorizationClient: .debugAuthorized
        )
        var transcripts: [String] = []
        var completionCount = 0

        controller.start(
            draft: "Please",
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in XCTFail("Unexpected debug dictation failure") }
        )
        await waitUntil { controller.phase == .recording }
        await waitUntil { transcripts == ["Please \(transcript)"] }

        controller.finish { completionCount += 1 }
        await waitUntil(timeout: .seconds(5)) { controller.phase == .idle }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(transcripts, ["Please \(transcript)"])
    }

    func testDebugBackendNoSpeechUsesControllerFailurePath() async {
        let controller = GhosttyComposerDictationController(
            backend: GhosttyDebugComposerDictationBackend(
                configuration: GhosttyDebugComposerDictationConfiguration(
                    transcript: nil
                )
            ),
            authorizationClient: .debugAuthorized
        )
        var failures: [String] = []

        controller.start(
            draft: "Keep this",
            onTranscript: { _ in },
            onFailure: { failures.append($0) }
        )
        await waitUntil { controller.phase == .recording }
        controller.finish()
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(failures, ["No speech detected. Try again."])
    }

    func testDebugBackendCancelSuppressesDelayedTranscriptAndCanRestart() async {
        let controller = GhosttyComposerDictationController(
            backend: GhosttyDebugComposerDictationBackend(
                configuration: GhosttyDebugComposerDictationConfiguration(
                    transcript: "Delayed transcript"
                )
            ),
            authorizationClient: .debugAuthorized
        )
        var transcripts: [String] = []

        controller.start(
            draft: "Keep this",
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in XCTFail("Unexpected debug dictation failure") }
        )
        await waitUntil { controller.phase == .recording }
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transcripts, ["Keep this"])

        controller.start(
            draft: "",
            onTranscript: { _ in },
            onFailure: { _ in XCTFail("Debug dictation did not restart") }
        )
        await waitUntil { controller.phase == .recording }
        controller.stopImmediately()
    }

    func testDebugConfigurationPreservesNoSpeechPrecedence() {
        XCTAssertNil(
            GhosttyDebugComposerDictationConfiguration.current(environment: [:])
        )
        XCTAssertEqual(
            GhosttyDebugComposerDictationConfiguration.current(
                environment: ["REMUX_DEBUG_DICTATION_TRANSCRIPT": "Transcript"]
            )?.transcript,
            "Transcript"
        )
        let noSpeech = GhosttyDebugComposerDictationConfiguration.current(
            environment: [
                "REMUX_DEBUG_DICTATION_NO_SPEECH": "1",
                "REMUX_DEBUG_DICTATION_TRANSCRIPT": "Ignored",
            ]
        )
        XCTAssertNotNil(noSpeech)
        XCTAssertNil(noSpeech?.transcript)
    }
#endif

    func testBackendStartDeadlineCancelsRunAndReportsFailure() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests,
            startDeadline: .milliseconds(20)
        )
        var failures: [String] = []

        controller.start(
            draft: "",
            onTranscript: { _ in },
            onFailure: { failures.append($0) }
        )
        backend.emit(.starting, for: 1)

        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(failures, ["Couldn’t start dictation. Try again."])
        XCTAssertEqual(backend.actions, [.start(1), .cancel(1)])
    }

    func testBackendPreparationDoesNotConsumeAudioStartDeadline() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests,
            startDeadline: .milliseconds(20)
        )
        var failures: [String] = []

        controller.start(
            draft: "",
            onTranscript: { _ in },
            onFailure: { failures.append($0) }
        )
        backend.emit(.preparing, for: 1)

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertTrue(failures.isEmpty)

        backend.emit(.starting, for: 1)
        backend.emit(.started, for: 1)
        await waitUntil { controller.phase == .recording }
        XCTAssertTrue(failures.isEmpty)
        controller.stopImmediately()
    }

    func testCancelRestoresSnapshotAndIgnoresStaleBackendEvents() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests
        )
        var transcripts: [String] = []
        var failures: [String] = []

        controller.start(
            draft: "Keep this",
            onTranscript: { transcripts.append($0) },
            onFailure: { failures.append($0) }
        )
        await waitUntil { backend.actions.contains(.start(1)) }
        backend.emit(.started, for: 1)
        await waitUntil { controller.phase == .recording }

        controller.cancel()
        backend.emit(.hypothesis("stale text"), for: 1)
        backend.emit(.completed, for: 1)
        backend.emit(.failed("stale failure"), for: 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(transcripts, ["Keep this"])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(backend.actions, [.start(1), .cancel(1)])
    }

    func testFinishSubmitsOneFinalTranscriptAndCompletesOnce() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests
        )
        var transcripts: [String] = []
        var completionCount = 0

        controller.start(
            draft: "Please",
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in XCTFail("Unexpected dictation failure") }
        )
        await waitUntil { backend.actions.contains(.start(1)) }
        backend.emit(.started, for: 1)
        await waitUntil { controller.phase == .recording }

        controller.finish { completionCount += 1 }
        XCTAssertEqual(controller.phase, .transcribing)
        XCTAssertEqual(backend.actions, [.start(1), .finish(1)])

        backend.emit(.hypothesis("review this"), for: 1)
        backend.emit(.completed, for: 1)
        await waitUntil { controller.phase == .idle }
        backend.emit(.hypothesis("duplicate"), for: 1)
        backend.emit(.completed, for: 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(transcripts, ["Please review this"])
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(backend.actions, [.start(1), .finish(1), .cancel(1)])
    }

    func testFinalizationFailureDoesNotSubmitPartialTranscript() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests
        )
        var failures: [String] = []
        var completionCount = 0

        controller.start(
            draft: "Keep",
            onTranscript: { _ in },
            onFailure: { failures.append($0) }
        )
        backend.emit(.started, for: 1)
        await waitUntil { controller.phase == .recording }
        backend.emit(.hypothesis("this partial"), for: 1)

        controller.finish { completionCount += 1 }
        backend.emit(.recognitionFailed, for: 1)
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(failures, ["Dictation stopped unexpectedly. Try again."])
        XCTAssertEqual(backend.actions, [.start(1), .finish(1), .cancel(1)])
    }

    func testCancelDuringAuthorizationNeverStartsBackend() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .delayedAuthorization(.milliseconds(80))
        )

        controller.start(draft: "", onTranscript: { _ in }, onFailure: { _ in })
        controller.stopImmediately()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(backend.actions.isEmpty)
    }

    func testAudioLevelOnlyInvalidatesMeterModel() async {
        let backend = DictationBackendSpy()
        let controller = GhosttyComposerDictationController(
            backend: backend,
            authorizationClient: .authorizedForTests
        )

        controller.start(draft: "", onTranscript: { _ in }, onFailure: { _ in })
        await waitUntil { backend.actions.contains(.start(1)) }
        backend.emit(.started, for: 1)
        await waitUntil { controller.phase == .recording }

        var controllerUpdateCount = 0
        var meterUpdateCount = 0
        let controllerObservation = controller.objectWillChange.sink {
            controllerUpdateCount += 1
        }
        let meterObservation = controller.audioLevelModel.objectWillChange.sink {
            meterUpdateCount += 1
        }

        backend.emit(.audioLevel(0.75), for: 1)
        await waitUntil { controller.audioLevelModel.levels.last == 0.75 }

        XCTAssertEqual(controllerUpdateCount, 0)
        XCTAssertEqual(meterUpdateCount, 1)
        withExtendedLifetime((controllerObservation, meterObservation)) {}
        controller.stopImmediately()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for dictation state")
    }

    private func captureBuffer(frameLength: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        )
        buffer.frameLength = frameLength
        return buffer
    }
}

private final class DictationBackendSpy: GhosttyComposerDictationBackendProtocol,
    @unchecked Sendable
{
    let requiresSpeechRecognitionAuthorization = true

    enum Action: Equatable {
        case start(UInt64)
        case finish(UInt64)
        case cancel(UInt64)
        case cancelAll
    }

    private let lock = NSLock()
    private let startEvent: GhosttyComposerDictationBackendEvent?
    private let completesCancellationImmediately: Bool
    private var storedActions: [Action] = []
    private var handlers: [UInt64: @Sendable (GhosttyComposerDictationBackendEvent) -> Void] = [:]
    private var pendingCancellations: [@Sendable () -> Void] = []

    init(
        startEvent: GhosttyComposerDictationBackendEvent? = nil,
        completesCancellationImmediately: Bool = true
    ) {
        self.startEvent = startEvent
        self.completesCancellationImmediately = completesCancellationImmediately
    }

    var actions: [Action] {
        lock.lock()
        defer { lock.unlock() }
        return storedActions
    }

    func prepare(locale: Locale) {}

    func start(
        id: UInt64,
        locale: Locale,
        requestedAt: UInt64,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    ) {
        lock.lock()
        storedActions.append(.start(id))
        handlers[id] = handler
        lock.unlock()
        if let startEvent {
            handler(startEvent)
        }
    }

    func finish(id: UInt64) {
        append(.finish(id))
    }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        storedActions.append(.cancel(id))
        if completesCancellationImmediately {
            lock.unlock()
            completion()
        } else {
            pendingCancellations.append(completion)
            lock.unlock()
        }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        append(.cancelAll)
        completion()
    }

    func emit(_ event: GhosttyComposerDictationBackendEvent, for id: UInt64) {
        lock.lock()
        let handler = handlers[id]
        lock.unlock()
        handler?(event)
    }

    func completePendingCancellations() {
        lock.lock()
        let completions = pendingCancellations
        pendingCancellations.removeAll()
        lock.unlock()
        completions.forEach { $0() }
    }

    private func append(_ action: Action) {
        lock.lock()
        storedActions.append(action)
        lock.unlock()
    }
}

private extension GhosttyComposerDictationAuthorizationClient {
    static let authorizedForTests = Self(
        knownResult: { _ in .authorized },
        requestSpeechAuthorization: { .authorized },
        requestMicrophoneAuthorization: { true }
    )

    static func delayedAuthorization(_ delay: Duration) -> Self {
        Self(
            knownResult: { _ in nil },
            requestSpeechAuthorization: {
                try? await Task.sleep(for: delay)
                return .authorized
            },
            requestMicrophoneAuthorization: { true }
        )
    }
}
