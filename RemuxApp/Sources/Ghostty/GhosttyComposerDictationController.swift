@preconcurrency import AVFoundation
import Accelerate
import Combine
@preconcurrency import Speech

enum GhosttyComposerDictationPhase: Equatable {
    case idle
    case preparing
    case starting
    case recording
    case transcribing

    var isActive: Bool {
        self != .idle
    }
}

enum GhosttyComposerDictationDraft {
    static func merging(snapshot: String, hypothesis: String) -> String {
        guard !hypothesis.isEmpty else { return snapshot }
        guard !snapshot.isEmpty else { return hypothesis }
        guard snapshot.last?.isWhitespace != true else {
            return snapshot + hypothesis
        }
        return snapshot + " " + hypothesis
    }
}

@MainActor
final class GhosttyComposerAudioLevelModel: ObservableObject {
    nonisolated static let historyCapacity = GhosttyComposerDictationMeterSizing.maximumBarCount

    @Published private(set) var levels: [CGFloat]

    init() {
        levels = Self.emptyLevels
    }

    func append(_ level: CGFloat) {
        var updatedLevels = levels
        updatedLevels.removeFirst()
        updatedLevels.append(level)
        levels = updatedLevels
    }

    func reset() {
        levels = Self.emptyLevels
    }

    func replace(with levels: [CGFloat]) {
        precondition(levels.count == Self.historyCapacity)
        self.levels = levels
    }

    private static var emptyLevels: [CGFloat] {
        Array(
            repeating: 0.08,
            count: Self.historyCapacity
        )
    }
}

enum GhosttyComposerDictationBackendEvent: Sendable {
    case preparing
    case starting
    case started
    case audioLevel(CGFloat)
    case hypothesis(String)
    case completed
    case recognitionFailed
    case failed(String)
}

protocol GhosttyComposerDictationBackendProtocol: Sendable {
    var requiresSpeechRecognitionAuthorization: Bool { get }
    func prepare(locale: Locale)
    func start(
        id: UInt64,
        locale: Locale,
        requestedAt: UInt64,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    )
    func finish(id: UInt64)
    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void)
    func cancelAll(completion: @escaping @Sendable () -> Void)
}

enum GhosttyComposerDictationBackendFactory {
    static func makeDefault() -> any GhosttyComposerDictationBackendProtocol {
        if #available(iOS 26.0, *) {
            return GhosttySpeechAnalyzerComposerDictationBackend()
        }
        return GhosttyLegacyComposerDictationBackend()
    }
}

struct GhosttyComposerDictationAuthorizationClient: Sendable {
    enum Result: Sendable {
        case authorized
        case speechRecognitionDenied
        case microphoneDenied
        case cancelled
    }

    let knownResult: @Sendable (_ requiresSpeechRecognition: Bool) -> Result?
    let requestSpeechAuthorization: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus
    let requestMicrophoneAuthorization: @Sendable () async -> Bool

    func resolve(requiresSpeechRecognition: Bool) async -> Result {
        if requiresSpeechRecognition {
            let speechAuthorization = await requestSpeechAuthorization()
            guard !Task.isCancelled else { return .cancelled }
            guard speechAuthorization == .authorized else {
                return .speechRecognitionDenied
            }
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard !Task.isCancelled else { return .cancelled }
        return microphoneAuthorized ? .authorized : .microphoneDenied
    }

    static let live = Self(
        knownResult: { requiresSpeechRecognition in
            if requiresSpeechRecognition {
                let speechAuthorization = SFSpeechRecognizer.authorizationStatus()
                switch speechAuthorization {
                case .denied, .restricted:
                    return .speechRecognitionDenied
                case .notDetermined:
                    return nil
                case .authorized:
                    break
                @unknown default:
                    return .speechRecognitionDenied
                }
            }

            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .authorized
            case .denied:
                return .microphoneDenied
            case .undetermined:
                return nil
            @unknown default:
                return .microphoneDenied
            }
        },
        requestSpeechAuthorization: {
            let current = SFSpeechRecognizer.authorizationStatus()
            guard current == .notDetermined else { return current }

            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        },
        requestMicrophoneAuthorization: {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        }
    )
}

private extension GhosttyComposerDictationAuthorizationClient.Result {
    var traceLabel: String {
        switch self {
        case .authorized:
            "authorized"
        case .speechRecognitionDenied:
            "speech_denied"
        case .microphoneDenied:
            "microphone_denied"
        case .cancelled:
            "cancelled"
        }
    }
}

/// Owns Speech and AVAudioEngine on one serial queue. The UI controller never
/// waits for teardown and never touches audio objects directly.
final class GhosttyLegacyComposerDictationBackend: GhosttyComposerDictationBackendProtocol,
    @unchecked Sendable
{
    let requiresSpeechRecognitionAuthorization = true

    typealias EventHandler = @Sendable (GhosttyComposerDictationBackendEvent) -> Void

    private enum RunPhase {
        case starting
        case recording
        case finishing
    }

    private final class Run {
        let id: UInt64
        let requestedAt: UInt64
        let handler: EventHandler
        var phase = RunPhase.starting
        var recognizer: SFSpeechRecognizer?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var captureSession: GhosttyComposerAudioCaptureSession?
        var hasReportedFirstHypothesis = false

        init(id: UInt64, requestedAt: UInt64, handler: @escaping EventHandler) {
            self.id = id
            self.requestedAt = requestedAt
            self.handler = handler
        }
    }

    private let queue = DispatchQueue(
        label: "dev.remux.composer-dictation",
        qos: .userInitiated
    )
    private let desiredRunLock = NSLock()
    private var desiredRunID: UInt64?
    private var activeRun: Run?
    private var preparedLocaleIdentifier: String?
    private var preparedRecognizer: SFSpeechRecognizer?

    func prepare(locale: Locale) {
        queue.async { [self] in
            guard activeRun == nil else { return }
            let startedAt = GhosttyRuntimeTrace.nowNanos()
            do {
                _ = try recognizer(for: locale)
                GhosttyRuntimeTrace.perf(
                    "composer.dictation.prepare result=ready locale=\(locale.identifier) "
                        + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
                )
            } catch {
                GhosttyRuntimeTrace.perf(
                    "composer.dictation.prepare result=unavailable locale=\(locale.identifier) "
                        + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt)) "
                        + "error=\(String(describing: error))"
                )
            }
        }
    }

    func start(
        id: UInt64,
        locale: Locale,
        requestedAt: UInt64,
        handler: @escaping EventHandler
    ) {
        setDesiredRunID(id)
        queue.async { [self] in
            traceStartup("backend.queueEntered", id: id, requestedAt: requestedAt)
            cancelActiveRun()
            guard isDesiredRun(id) else { return }
            traceStartup("backend.previousRunCleanupCompleted", id: id, requestedAt: requestedAt)

            let run = Run(id: id, requestedAt: requestedAt, handler: handler)
            activeRun = run
            start(run, locale: locale)
        }
    }

    func finish(id: UInt64) {
        queue.async { [self] in
            guard let run = activeRun,
                  run.id == id,
                  run.phase == .recording else {
                return
            }

            run.phase = .finishing
            run.captureSession?.finish { [weak self] inputFinished in
                self?.queue.async { [weak self] in
                    self?.captureFinished(
                        runID: id,
                        inputFinished: inputFinished
                    )
                }
            }
        }
    }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        clearDesiredRunID(ifMatching: id)
        queue.async { [self] in
            if activeRun?.id == id {
                cancelActiveRun()
            }
            completion()
        }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        setDesiredRunID(nil)
        queue.async { [self] in
            cancelActiveRun()
            completion()
        }
    }

    private func start(_ run: Run, locale: Locale) {
        run.handler(.starting)
        do {
            traceStartup("backend.recognizerResolve.begin", run: run)
            let recognizer = try recognizer(for: locale)
            traceStartup("backend.recognizerResolve.end", run: run)

            traceStartup("backend.recognitionTaskCreation.begin", run: run)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            request.taskHint = .dictation

            run.recognizer = recognizer
            run.request = request
            let runID = run.id
            run.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let hypothesis = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let errorDescription = error.map { String(describing: $0) }
                self?.queue.async { [weak self] in
                    self?.handleRecognitionUpdate(
                        runID: runID,
                        hypothesis: hypothesis,
                        isFinal: isFinal,
                        errorDescription: errorDescription
                    )
                }
            }
            traceStartup("backend.recognitionTaskCreation.end", run: run)

            let captureSession = GhosttyComposerAudioCaptureSession()
            run.captureSession = captureSession
            traceStartup("backend.captureStart.begin", run: run)
            let audioLevelHandler: @Sendable (CGFloat) -> Void = { [weak self] level in
                self?.publishAudioLevel(level, runID: runID)
            }
            try captureSession.start(
                makeConsumer: { _ in
                    GhosttyComposerAudioTapProcessor(
                        request: request,
                        onLevel: audioLevelHandler
                    )
                },
                onStarted: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.captureStarted(runID: runID)
                    }
                },
                onFailure: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.captureFailed(runID: runID)
                    }
                }
            )
            guard isActive(run), isDesiredRun(run.id) else {
                cancelActiveRun()
                return
            }
            traceStartup("backend.captureStart.end", run: run)
        } catch {
            let message = userMessage(for: error)
            GhosttyRuntimeTrace.perf(
                "composer.dictation.backend.startFailed id=\(run.id) "
                    + "error=\(String(describing: error))"
            )
            clearDesiredRunID(ifMatching: run.id)
            cancelActiveRun()
            run.handler(.failed(message))
        }
    }

    private func captureStarted(runID: UInt64) {
        guard let run = activeRun,
              run.id == runID,
              run.phase == .starting,
              isDesiredRun(runID) else {
            return
        }
        run.phase = .recording
        traceStartup("backend.firstForwardedAudioBuffer", run: run)
        run.handler(.started)
    }

    private func captureFinished(runID: UInt64, inputFinished: Bool) {
        guard let run = activeRun,
              run.id == runID,
              run.phase == .finishing else {
            return
        }
        guard inputFinished else {
            run.handler(.recognitionFailed)
            clearDesiredRunID(ifMatching: run.id)
            cancelActiveRun()
            return
        }

        run.recognitionTask?.finish()
    }

    private func captureFailed(runID: UInt64) {
        guard let run = activeRun,
              run.id == runID,
              run.phase == .starting || run.phase == .recording else {
            return
        }
        run.handler(.recognitionFailed)
        clearDesiredRunID(ifMatching: run.id)
        cancelActiveRun()
    }

    private func handleRecognitionUpdate(
        runID: UInt64,
        hypothesis: String?,
        isFinal: Bool,
        errorDescription: String?
    ) {
        guard let run = activeRun, run.id == runID else { return }

        if let hypothesis, !hypothesis.isEmpty {
            if !run.hasReportedFirstHypothesis {
                run.hasReportedFirstHypothesis = true
                traceStartup("backend.firstHypothesis", run: run)
            }
            run.handler(.hypothesis(hypothesis))
        }

        if isFinal {
            run.handler(.completed)
            clearDesiredRunID(ifMatching: run.id)
            releaseCompletedRun(run)
            return
        }

        guard let errorDescription else { return }
        GhosttyRuntimeTrace.perf(
            "composer.dictation.backend.recognitionFailed id=\(run.id) "
                + "error=\(errorDescription)"
        )
        clearDesiredRunID(ifMatching: run.id)
        run.handler(.recognitionFailed)
        cancelActiveRun()
    }

    private func publishAudioLevel(_ level: CGFloat, runID: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  let run = activeRun,
                  run.id == runID,
                  run.phase == .recording else {
                return
            }
            run.handler(.audioLevel(level))
        }
    }

    private func releaseCompletedRun(_ run: Run) {
        guard activeRun === run else { return }
        run.captureSession?.cancel()
        activeRun = nil
    }

    private func cancelActiveRun() {
        guard let run = activeRun else { return }
        activeRun = nil
        run.recognitionTask?.cancel()
        run.captureSession?.cancel()
        run.recognitionTask = nil
        run.request = nil
        run.recognizer = nil
        run.captureSession = nil
    }

    private func recognizer(for locale: Locale) throws -> SFSpeechRecognizer {
        let localeIdentifier = locale.identifier
        let recognizer: SFSpeechRecognizer
        if preparedLocaleIdentifier == localeIdentifier,
           let preparedRecognizer {
            recognizer = preparedRecognizer
        } else {
            guard let createdRecognizer = SFSpeechRecognizer(locale: locale) else {
                throw GhosttyComposerDictationError.unsupportedLocale
            }
            preparedLocaleIdentifier = localeIdentifier
            preparedRecognizer = createdRecognizer
            recognizer = createdRecognizer
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw GhosttyComposerDictationError.unsupportedOnDeviceLocale
        }
        guard recognizer.isAvailable else {
            throw GhosttyComposerDictationError.recognizerUnavailable
        }
        return recognizer
    }

    private func traceStartup(
        _ event: String,
        run: Run,
        at timestamp: UInt64? = nil
    ) {
        traceStartup(event, id: run.id, requestedAt: run.requestedAt, at: timestamp)
    }

    private func traceStartup(
        _ event: String,
        id: UInt64,
        requestedAt: UInt64,
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.perfEnabled else { return }
        let resolvedTimestamp = timestamp ?? GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.perf(
            "composer.dictation.startup event=\(event) id=\(id) "
                + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: requestedAt, to: resolvedTimestamp))"
        )
    }

    private func isActive(_ run: Run) -> Bool {
        activeRun === run
    }

    private func setDesiredRunID(_ id: UInt64?) {
        desiredRunLock.lock()
        desiredRunID = id
        desiredRunLock.unlock()
    }

    private func clearDesiredRunID(ifMatching id: UInt64) {
        desiredRunLock.lock()
        if desiredRunID == id {
            desiredRunID = nil
        }
        desiredRunLock.unlock()
    }

    private func isDesiredRun(_ id: UInt64) -> Bool {
        desiredRunLock.lock()
        defer { desiredRunLock.unlock() }
        return desiredRunID == id
    }

    private func userMessage(for error: Error) -> String {
        switch error {
        case GhosttyComposerDictationError.unsupportedLocale:
            "Dictation isn’t available for this language."
        case GhosttyComposerDictationError.unsupportedOnDeviceLocale:
            "On-device dictation isn’t available for this language."
        case GhosttyComposerDictationError.recognizerUnavailable:
            "Dictation isn’t available right now."
        default:
            "Couldn’t start dictation. Try again."
        }
    }
}

private final class GhosttyComposerAudioTapProcessor:
    GhosttyComposerAudioCaptureConsumer,
    @unchecked Sendable
{
    private static let levelPublishInterval = 0.075

    private let request: SFSpeechAudioBufferRecognitionRequest
    private let onLevel: @Sendable (CGFloat) -> Void
    private let lock = NSLock()
    private var lastLevelPublishTime: CFTimeInterval = 0
    private var isFinished = false

    init(
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (CGFloat) -> Void
    ) {
        self.request = request
        self.onLevel = onLevel
    }

    func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        request.append(buffer)

        let now = CACurrentMediaTime()
        if now - lastLevelPublishTime >= Self.levelPublishInterval {
            lastLevelPublishTime = now
            onLevel(GhosttyComposerAudioLevelMeter.normalizedPeak(for: buffer))
        }
        return true
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return true }
        isFinished = true
        request.endAudio()
        return true
    }

    func cancel() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }
}

@MainActor
final class GhosttyComposerDictationController: ObservableObject {
    @Published private(set) var phase = GhosttyComposerDictationPhase.idle
    let audioLevelModel: GhosttyComposerAudioLevelModel

    private let backend: any GhosttyComposerDictationBackendProtocol
    private let authorizationClient: GhosttyComposerDictationAuthorizationClient
    private let startDeadline: Duration
    private var authorizationTask: Task<Void, Never>?
    private var startDeadlineTask: Task<Void, Never>?
    private var sessionID: UInt64 = 0
    private var backendRunRequested = false
    private var startRequestedAt: UInt64?
    private var draftSnapshot = ""
    private var latestHypothesis = ""
    private var onTranscript: ((String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var afterTranscription: (() -> Void)?

    static func makeDefault() -> GhosttyComposerDictationController {
#if DEBUG
        if let configuration = GhosttyDebugComposerDictationConfiguration.current() {
            return GhosttyComposerDictationController(
                backend: GhosttyDebugComposerDictationBackend(configuration: configuration),
                authorizationClient: .debugAuthorized
            )
        }
#endif
        return GhosttyComposerDictationController()
    }

    init(
        backend: any GhosttyComposerDictationBackendProtocol = GhosttyComposerDictationBackendFactory.makeDefault(),
        authorizationClient: GhosttyComposerDictationAuthorizationClient = .live,
        startDeadline: Duration = .seconds(8)
    ) {
        self.backend = backend
        self.authorizationClient = authorizationClient
        self.startDeadline = startDeadline
        audioLevelModel = GhosttyComposerAudioLevelModel()
    }

    deinit {
        backend.cancelAll {}
    }

    func prepare() {
        backend.prepare(locale: .current)
    }

    func start(
        draft: String,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard phase == .idle else { return }

        sessionID &+= 1
        let requestedSessionID = sessionID
        draftSnapshot = draft
        latestHypothesis = ""
        audioLevelModel.reset()
        self.onTranscript = onTranscript
        self.onFailure = onFailure
        phase = .starting
        let requestedAt = GhosttyRuntimeTrace.nowNanos()
        startRequestedAt = requestedAt
        GhosttyRuntimeTrace.perf(
            "composer.dictation.startup event=ui.tap id=\(requestedSessionID) elapsed_ms=0.000"
        )

        if let knownAuthorizationResult = authorizationClient.knownResult(
            backend.requiresSpeechRecognitionAuthorization
        ) {
            handleAuthorizationResult(
                knownAuthorizationResult,
                sessionID: requestedSessionID,
                requestedAt: requestedAt
            )
            return
        }

        let authorizationClient = authorizationClient
        let requiresSpeechRecognition = backend.requiresSpeechRecognitionAuthorization
        authorizationTask = Task { [weak self, authorizationClient] in
            let result = await authorizationClient.resolve(
                requiresSpeechRecognition: requiresSpeechRecognition
            )
            guard let self else { return }
            handleAuthorizationResult(
                result,
                sessionID: requestedSessionID,
                requestedAt: requestedAt
            )
        }
    }

    func finish(afterTranscription: (() -> Void)? = nil) {
        guard phase == .recording else { return }

        self.afterTranscription = afterTranscription
        phase = .transcribing
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        GhosttyRuntimeTrace.perf("composer.dictation.finishRequested id=\(sessionID)")

        backend.finish(id: sessionID)
    }

    func cancel() {
        guard phase.isActive else { return }
        let snapshot = draftSnapshot
        let transcript = onTranscript
        invalidateSession()
        transcript?(snapshot)
    }

    func stopImmediately() {
        guard phase.isActive else { return }
        invalidateSession()
    }

    private func handleAuthorizationResult(
        _ result: GhosttyComposerDictationAuthorizationClient.Result,
        sessionID requestedSessionID: UInt64,
        requestedAt: UInt64
    ) {
        guard isCurrentStartingSession(requestedSessionID) else { return }
        authorizationTask = nil
        GhosttyRuntimeTrace.perf(
            "composer.dictation.startup event=authorization.resolved "
                + "id=\(requestedSessionID) result=\(result.traceLabel) "
                + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: requestedAt))"
        )

        switch result {
        case .authorized:
            beginBackend(sessionID: requestedSessionID, requestedAt: requestedAt)

        case .speechRecognitionDenied:
            fail(
                sessionID: requestedSessionID,
                message: "Allow speech recognition in Settings to use dictation."
            )

        case .microphoneDenied:
            fail(
                sessionID: requestedSessionID,
                message: "Allow microphone access in Settings to use dictation."
            )

        case .cancelled:
            invalidateSession()
        }
    }

    private func beginBackend(sessionID requestedSessionID: UInt64, requestedAt: UInt64) {
        backendRunRequested = true
        backend.start(
            id: requestedSessionID,
            locale: .current,
            requestedAt: requestedAt,
            handler: { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    self?.handleBackendEvent(event, sessionID: requestedSessionID)
                }
            }
        )
    }

    private func traceStartupFromUI(_ event: String, id: UInt64) {
        guard GhosttyRuntimeTrace.perfEnabled,
              let startRequestedAt else {
            return
        }
        GhosttyRuntimeTrace.perf(
            "composer.dictation.startup event=\(event) id=\(id) "
                + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startRequestedAt))"
        )
    }

    private func handleBackendEvent(
        _ event: GhosttyComposerDictationBackendEvent,
        sessionID requestedSessionID: UInt64
    ) {
        guard requestedSessionID == sessionID, phase.isActive else { return }

        switch event {
        case .preparing:
            guard phase == .starting || phase == .preparing else { return }
            startDeadlineTask?.cancel()
            startDeadlineTask = nil
            phase = .preparing

        case .starting:
            guard phase == .starting || phase == .preparing else { return }
            phase = .starting
            scheduleStartDeadline(sessionID: requestedSessionID)

        case .started:
            guard phase == .starting else { return }
            startDeadlineTask?.cancel()
            startDeadlineTask = nil
            phase = .recording
            traceStartupFromUI("ui.recording", id: requestedSessionID)

        case .audioLevel(let level):
            guard phase == .recording else { return }
            audioLevelModel.append(level)

        case .hypothesis(let hypothesis):
            if latestHypothesis.isEmpty, !hypothesis.isEmpty {
                traceStartupFromUI("ui.firstHypothesis", id: requestedSessionID)
            }
            latestHypothesis = hypothesis
            onTranscript?(
                GhosttyComposerDictationDraft.merging(
                    snapshot: draftSnapshot,
                    hypothesis: hypothesis
                )
            )

        case .completed:
            if latestHypothesis.isEmpty {
                fail(
                    sessionID: requestedSessionID,
                    message: "No speech detected. Try again."
                )
            } else {
                complete(sessionID: requestedSessionID)
            }

        case .recognitionFailed:
            fail(
                sessionID: requestedSessionID,
                message: "Dictation stopped unexpectedly. Try again."
            )

        case .failed(let message):
            fail(sessionID: requestedSessionID, message: message)
        }
    }

    private func scheduleStartDeadline(sessionID requestedSessionID: UInt64) {
        startDeadlineTask?.cancel()
        let startDeadline = startDeadline
        startDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: startDeadline)
            } catch {
                return
            }
            guard let self,
                  requestedSessionID == sessionID,
                  phase == .starting else {
                return
            }

            GhosttyRuntimeTrace.perf(
                "composer.dictation.startTimedOut id=\(requestedSessionID)"
            )
            fail(
                sessionID: requestedSessionID,
                message: "Couldn’t start dictation. Try again."
            )
        }
    }

    private func complete(sessionID requestedSessionID: UInt64) {
        guard requestedSessionID == sessionID else { return }
        let completion = afterTranscription
        invalidateSession()
        completion?()
    }

    private func fail(sessionID requestedSessionID: UInt64, message: String) {
        guard requestedSessionID == sessionID else { return }
        let failure = onFailure
        invalidateSession()
        failure?(message)
    }

    private func invalidateSession() {
        let invalidatedSessionID = sessionID
        let shouldCancelBackend = backendRunRequested
        sessionID &+= 1
        backendRunRequested = false
        startRequestedAt = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        startDeadlineTask?.cancel()
        startDeadlineTask = nil
        phase = .idle
        audioLevelModel.reset()
        onTranscript = nil
        onFailure = nil
        afterTranscription = nil
        guard shouldCancelBackend else { return }
        backend.cancel(id: invalidatedSessionID) {}
    }

    private func isCurrentStartingSession(_ requestedSessionID: UInt64) -> Bool {
        requestedSessionID == sessionID
            && phase == .starting
    }

}

enum GhosttyComposerAudioLevelMeter {
    static func normalizedPeak(for buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0 else {
            return 0.08
        }

        var peak: Float = 0
        vDSP_maxmgv(
            samples,
            1,
            &peak,
            vDSP_Length(buffer.frameLength)
        )
        let decibels = 20 * log10(max(peak, 0.000_001))
        return CGFloat(min(max((decibels + 50) / 50, 0.08), 1))
    }
}

enum GhosttyComposerDictationError: Error {
    case unavailableAudioInput
    case unsupportedLocale
    case unsupportedOnDeviceLocale
    case recognizerUnavailable
}
