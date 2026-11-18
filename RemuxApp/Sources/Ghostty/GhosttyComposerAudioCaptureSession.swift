@preconcurrency import AVFoundation
import Darwin

protocol GhosttyComposerAudioCaptureConsumer: AnyObject, Sendable {
    /// Returns only after this buffer has been forwarded to the recognizer.
    func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> Bool
    /// Closes the recognizer input after every accepted buffer.
    func finish() -> Bool
    /// Prevents any later tap callback from forwarding more audio.
    func cancel()
}

/// The timestamp-only portion of capture draining. Keeping this independent of
/// AVAudioEngine makes the boundary contract deterministic and testable.
struct GhosttyComposerAudioCaptureBoundary {
    enum ForwardResult: Equatable {
        case recording(firstBuffer: Bool)
        case draining
        case covered
    }

    private(set) var stopHostTime: UInt64?
    private(set) var latestCoveredHostTime: UInt64?
    private(set) var hasForwardedBuffer = false
    private(set) var hasReliableTimeline = false
    private(set) var maximumDeliveryInterval: TimeInterval?
    private(set) var droppedSampleFrames: AVAudioFramePosition = 0

    private var anchor: AVAudioTime?
    private var previousDeliveryHostTime: UInt64?
    private var previousSampleEnd: AVAudioFramePosition?
    private var previousSampleRate: Double?

    mutating func requestStop(at hostTime: UInt64) -> Bool {
        guard stopHostTime == nil else { return false }
        stopHostTime = hostTime
        return true
    }

    mutating func didForward(
        _ buffer: AVAudioPCMBuffer,
        at time: AVAudioTime,
        deliveredAt deliveryHostTime: UInt64
    ) -> ForwardResult {
        let isFirstBuffer = !hasForwardedBuffer
        hasForwardedBuffer = true
        recordDeliveryInterval(at: deliveryHostTime)
        recordSampleContinuity(for: buffer, at: time)

        if time.isHostTimeValid, time.isSampleTimeValid {
            anchor = time
        }

        if let endHostTime = endHostTime(for: buffer, at: time) {
            hasReliableTimeline = true
            latestCoveredHostTime = endHostTime
        }

        guard let stopHostTime else {
            return .recording(firstBuffer: isFirstBuffer)
        }
        guard let latestCoveredHostTime else { return .draining }
        return latestCoveredHostTime >= stopHostTime ? .covered : .draining
    }

    /// This bounds only the wait for capture hardware to deliver another
    /// buffer. Recognition finalization itself is never timed out.
    var drainWatchdogDuration: TimeInterval {
        let measuredInterval = maximumDeliveryInterval ?? 0.4
        return min(max(measuredInterval * 5, 0.5), 2.0)
    }

    private mutating func endHostTime(
        for buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) -> UInt64? {
        let resolvedTime: AVAudioTime
        if time.isHostTimeValid {
            resolvedTime = time
        } else if time.isSampleTimeValid,
                  let anchor,
                  let extrapolated = time.extrapolateTime(fromAnchor: anchor),
                  extrapolated.isHostTimeValid {
            resolvedTime = extrapolated
        } else {
            return nil
        }

        guard buffer.format.sampleRate > 0 else { return nil }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let durationHostTime = AVAudioTime.hostTime(forSeconds: duration)
        let (endHostTime, overflow) = resolvedTime.hostTime.addingReportingOverflow(
            durationHostTime
        )
        return overflow ? UInt64.max : endHostTime
    }

    private mutating func recordDeliveryInterval(at hostTime: UInt64) {
        defer { previousDeliveryHostTime = hostTime }
        guard let previousDeliveryHostTime,
              hostTime >= previousDeliveryHostTime else {
            return
        }
        let interval = AVAudioTime.seconds(
            forHostTime: hostTime - previousDeliveryHostTime
        )
        maximumDeliveryInterval = max(maximumDeliveryInterval ?? 0, interval)
    }

    private mutating func recordSampleContinuity(
        for buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        guard time.isSampleTimeValid else {
            previousSampleEnd = nil
            previousSampleRate = nil
            return
        }

        if previousSampleRate == time.sampleRate,
           let previousSampleEnd,
           time.sampleTime > previousSampleEnd {
            droppedSampleFrames += time.sampleTime - previousSampleEnd
        }
        previousSampleEnd = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
        previousSampleRate = time.sampleRate
    }
}

/// Owns the process-wide audio session, one fresh AVAudioEngine, its input tap,
/// and the recording-to-draining transition. Recognition backends only consume
/// buffers and finalize their own framework after this owner reports drained.
final class GhosttyComposerAudioCaptureSession: @unchecked Sendable {
    typealias VoidHandler = @Sendable () -> Void

    /// How much sound each buffer from the microphone holds.
    static let bufferDuration: TimeInterval = 0.1

    private enum State {
        case idle
        case capturing
        case draining
        case stopped
    }

    private let queue = DispatchQueue(
        label: "dev.remux.composer-audio-capture",
        qos: .userInitiated
    )
    private let lock = NSLock()

    private var state = State.idle
    private var boundary = GhosttyComposerAudioCaptureBoundary()
    private var consumer: (any GhosttyComposerAudioCaptureConsumer)?
    private var engine: AVAudioEngine?
    private var notificationTokens: [NSObjectProtocol] = []
    private var onStarted: VoidHandler?
    private var onFailure: VoidHandler?
    private var drainCompletion: (@Sendable (Bool) -> Void)?
    private var drainGeneration: UInt64 = 0
    private var isAudioSessionActive = false

    @discardableResult
    func start<Consumer: GhosttyComposerAudioCaptureConsumer>(
        makeConsumer: @escaping @Sendable (AVAudioFormat) throws -> Consumer,
        onStarted: @escaping VoidHandler,
        onFailure: @escaping VoidHandler
    ) throws -> Consumer {
        try queue.sync {
            lock.lock()
            precondition(state == .idle)
            self.onStarted = onStarted
            self.onFailure = onFailure
            lock.unlock()

            do {
                try configureAudioSession()
                try AVAudioSession.sharedInstance().setActive(true)
                isAudioSessionActive = true

                let engine = AVAudioEngine()
                let inputNode = engine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw GhosttyComposerDictationError.unavailableAudioInput
                }
                let consumer = try makeConsumer(format)
                lock.lock()
                self.consumer = consumer
                state = .capturing
                lock.unlock()

                self.engine = engine
                installNotifications(for: engine)
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: AVAudioFrameCount(format.sampleRate * Self.bufferDuration),
                    format: format
                ) { [weak self] buffer, time in
                    self?.accept(buffer, at: time)
                }
                engine.prepare()
                try engine.start()
                return consumer
            } catch {
                cancelOnQueue()
                throw error
            }
        }
    }

    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        let stopHostTime = mach_absolute_time()
        var watchdogDuration: TimeInterval?

        lock.lock()
        if state == .capturing, boundary.requestStop(at: stopHostTime) {
            state = .draining
            drainCompletion = completion
            drainGeneration &+= 1
            watchdogDuration = boundary.drainWatchdogDuration
        }
        let generation = drainGeneration
        lock.unlock()

        guard let watchdogDuration else {
            queue.async {
                completion(false)
            }
            return
        }
        GhosttyRuntimeTrace.perf(
            "composer.dictation.capture drain=started stop_host=\(stopHostTime)"
        )
        queue.asyncAfter(deadline: .now() + watchdogDuration) { [weak self] in
            self?.completeDrainIfNeeded(
                generation: generation,
                reason: "watchdog"
            )
        }
    }

    func cancel() {
        queue.sync {
            cancelOnQueue()
        }
    }

    private func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        guard state == .capturing || state == .draining,
              let consumer else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard consumer.accept(buffer, at: time) else {
            failCapture()
            return
        }

        let deliveredAt = mach_absolute_time()
        var shouldReportStarted = false
        var shouldCompleteDrain = false
        var generation: UInt64 = 0

        lock.lock()
        guard state == .capturing || state == .draining else {
            lock.unlock()
            return
        }
        let result = boundary.didForward(
            buffer,
            at: time,
            deliveredAt: deliveredAt
        )
        if case .recording(let firstBuffer) = result {
            shouldReportStarted = firstBuffer
        }
        if result == .covered, state == .draining {
            shouldCompleteDrain = true
            generation = drainGeneration
        }
        lock.unlock()
        let completionGeneration = generation

        if shouldReportStarted {
            let deliveryLagMilliseconds: Double?
            if time.isHostTimeValid, deliveredAt >= time.hostTime {
                deliveryLagMilliseconds = AVAudioTime.seconds(
                    forHostTime: deliveredAt - time.hostTime
                ) * 1_000
            } else {
                deliveryLagMilliseconds = nil
            }
            let deliveryLagLabel = deliveryLagMilliseconds.map {
                String(format: "%.3f", $0)
            } ?? "unavailable"
            GhosttyRuntimeTrace.perf(
                "composer.dictation.capture first_forwarded_buffer "
                    + "frames=\(buffer.frameLength) "
                    + "sample_rate=\(buffer.format.sampleRate) "
                    + "delivery_lag_ms=\(deliveryLagLabel)"
            )
            queue.async { [weak self] in
                self?.reportStartedIfNeeded()
            }
        }
        if shouldCompleteDrain {
            queue.async { [weak self] in
                self?.completeDrainIfNeeded(
                    generation: completionGeneration,
                    reason: "timestamp_coverage"
                )
            }
        }
    }

    private func reportStartedIfNeeded() {
        lock.lock()
        let handler = state == .capturing ? onStarted : nil
        lock.unlock()
        handler?()
    }

    private func failCapture() {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            guard state == .capturing else {
                lock.unlock()
                return
            }
            state = .stopped
            let handler = onFailure
            let consumer = consumer
            lock.unlock()

            consumer?.cancel()
            teardownOnQueue()
            handler?()
        }
    }

    private func completeDrainIfNeeded(generation: UInt64, reason: String) {
        lock.lock()
        guard state == .draining, generation == drainGeneration else {
            lock.unlock()
            return
        }
        state = .stopped
        let completion = drainCompletion
        drainCompletion = nil
        let hadReliableTimeline = boundary.hasReliableTimeline
        let latestCoveredHostTime = boundary.latestCoveredHostTime
        let stopHostTime = boundary.stopHostTime
        let droppedSampleFrames = boundary.droppedSampleFrames
        let consumer = consumer
        lock.unlock()

        let inputFinished = consumer?.finish() ?? false
        teardownOnQueue()
        let coveredHostLabel = latestCoveredHostTime.map(String.init) ?? "none"
        let drainWaitMilliseconds = stopHostTime.map {
            AVAudioTime.seconds(forHostTime: mach_absolute_time() - $0) * 1_000
        }
        let tailCapturedMilliseconds: Double? = if let stopHostTime,
                                                   let latestCoveredHostTime,
                                                   latestCoveredHostTime >= stopHostTime {
            AVAudioTime.seconds(forHostTime: latestCoveredHostTime - stopHostTime) * 1_000
        } else {
            nil
        }
        GhosttyRuntimeTrace.perf(
            "composer.dictation.capture drain=completed reason=\(reason) "
                + "reliable_timeline=\(hadReliableTimeline) "
                + "covered_host=\(coveredHostLabel) "
                + "drain_wait_ms=\(metricLabel(drainWaitMilliseconds)) "
                + "tail_captured_ms=\(metricLabel(tailCapturedMilliseconds)) "
                + "dropped_sample_frames=\(droppedSampleFrames)"
        )
        completion?(inputFinished)
    }

    private func handleCaptureLoss(reason: String) {
        lock.lock()
        let currentState = state
        let generation = drainGeneration
        lock.unlock()

        switch currentState {
        case .capturing:
            GhosttyRuntimeTrace.perf(
                "composer.dictation.capture failure=\(reason)"
            )
            failCapture()
        case .draining:
            completeDrainIfNeeded(generation: generation, reason: reason)
        case .idle, .stopped:
            break
        }
    }

    private func installNotifications(for engine: AVAudioEngine) {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began else {
                    return
                }
                self?.enqueueCaptureLoss(reason: "interruption")
            },
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.enqueueCaptureLoss(reason: "engine_configuration_change")
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                        as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason)
                        == .oldDeviceUnavailable else {
                    return
                }
                self?.enqueueCaptureLoss(reason: "input_route_unavailable")
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                self?.enqueueCaptureLoss(reason: "media_services_reset")
            },
        ]
    }

    private func enqueueCaptureLoss(reason: String) {
        queue.async { [weak self] in
            self?.handleCaptureLoss(reason: reason)
        }
    }

    private func cancelOnQueue() {
        lock.lock()
        guard state != .idle, state != .stopped else {
            let consumer = consumer
            lock.unlock()
            consumer?.cancel()
            teardownOnQueue()
            return
        }
        state = .stopped
        drainGeneration &+= 1
        let cancelledDrainCompletion = drainCompletion
        drainCompletion = nil
        let consumer = consumer
        lock.unlock()

        consumer?.cancel()
        teardownOnQueue()
        cancelledDrainCompletion?(false)
    }

    private func teardownOnQueue() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            self.engine = nil
        }

        if isAudioSessionActive {
            isAudioSessionActive = false
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            } catch {
                GhosttyRuntimeTrace.perf(
                    "composer.dictation.capture audio_session_deactivate_failed "
                        + "error=\(String(describing: error))"
                )
            }
        }

        lock.lock()
        consumer = nil
        onStarted = nil
        onFailure = nil
        lock.unlock()
    }

    private func configureAudioSession() throws {
        try AVAudioSession.sharedInstance().setCategory(
            .record,
            mode: .measurement,
            options: [.allowBluetoothHFP]
        )
    }

    private func metricLabel(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "unavailable"
    }
}
