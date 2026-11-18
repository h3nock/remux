#if DEBUG
import AVFoundation
import Foundation

struct GhosttyDebugComposerDictationConfiguration: Sendable {
    /// A recognizer result: the text the composer shows `at` seconds after dictation starts.
    struct Hypothesis: Sendable {
        let at: TimeInterval
        let text: String
    }

    let transcript: String?
    /// A recording that plays as the microphone: the meter follows its loudness.
    let audio: URL?
    /// The recognizer's results for `audio`, in order; the last is the final transcript.
    let hypotheses: [Hypothesis]

    init(transcript: String?, audio: URL? = nil, hypotheses: [Hypothesis] = []) {
        self.transcript = transcript
        self.audio = audio
        self.hypotheses = hypotheses
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GhosttyDebugComposerDictationConfiguration? {
        if environment["REMUX_DEBUG_DICTATION_NO_SPEECH"] == "1" {
            return GhosttyDebugComposerDictationConfiguration(transcript: nil)
        }
        // REMUX_DEBUG_DICTATION_AUDIO is a recording's path, and REMUX_DEBUG_DICTATION_TIMELINE a JSON file of
        // [[seconds, "text so far"], ...] for it, such as a recognizer gave while it listened.
        if let path = environment["REMUX_DEBUG_DICTATION_AUDIO"], !path.isEmpty {
            let hypotheses = environment["REMUX_DEBUG_DICTATION_TIMELINE"].map(hypotheses(inFile:)) ?? []
            return GhosttyDebugComposerDictationConfiguration(
                transcript: hypotheses.last?.text ?? environment["REMUX_DEBUG_DICTATION_TRANSCRIPT"],
                audio: URL(fileURLWithPath: path),
                hypotheses: hypotheses
            )
        }
        guard let transcript = environment["REMUX_DEBUG_DICTATION_TRANSCRIPT"],
              !transcript.isEmpty else {
            return nil
        }
        return GhosttyDebugComposerDictationConfiguration(transcript: transcript)
    }

    private static func hypotheses(inFile path: String) -> [Hypothesis] {
        guard let data = FileManager.default.contents(atPath: path),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard row.count >= 2, let at = (row[0] as? NSNumber)?.doubleValue, let text = row[1] as? String else {
                return nil
            }
            return Hypothesis(at: at, text: text)
        }
    }

    /// The meter's levels for `audio`, one per microphone buffer, as the live capture would publish them.
    func audioLevels() -> [CGFloat] {
        guard let audio,
              let file = try? AVAudioFile(forReading: audio),
              let samples = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: samples)) != nil,
              let source = samples.floatChannelData else {
            return []
        }
        let step = AVAudioFrameCount(file.processingFormat.sampleRate * GhosttyComposerAudioCaptureSession.bufferDuration)
        guard step > 0, let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: step),
              let target = piece.floatChannelData else {
            return []
        }
        var levels: [CGFloat] = []
        var offset: AVAudioFrameCount = 0
        while offset < samples.frameLength {
            let count = min(step, samples.frameLength - offset)
            for channel in 0..<Int(file.processingFormat.channelCount) {
                target[channel].update(from: source[channel] + Int(offset), count: Int(count))
            }
            piece.frameLength = count
            levels.append(GhosttyComposerAudioLevelMeter.normalizedPeak(for: piece))
            offset += count
        }
        return levels
    }
}

extension GhosttyComposerDictationAuthorizationClient {
    static let debugAuthorized = Self(
        knownResult: { _ in .authorized },
        requestSpeechAuthorization: { .authorized },
        requestMicrophoneAuthorization: { true }
    )
}

final class GhosttyDebugComposerDictationBackend:
    GhosttyComposerDictationBackendProtocol,
    @unchecked Sendable
{
    let requiresSpeechRecognitionAuthorization = false

    private final class Run {
        let id: UInt64
        let handler: @Sendable (GhosttyComposerDictationBackendEvent) -> Void
        var startWork: DispatchWorkItem?
        var hypothesisWork: [DispatchWorkItem] = []
        var levelTimer: DispatchSourceTimer?
        var levelsPlayed = 0
        var deliveredHypothesis = false

        init(
            id: UInt64,
            handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
        ) {
            self.id = id
            self.handler = handler
        }

        func cancel() {
            startWork?.cancel()
            hypothesisWork.forEach { $0.cancel() }
            levelTimer?.cancel()
        }
    }

    private let configuration: GhosttyDebugComposerDictationConfiguration
    private let queue = DispatchQueue(label: "dev.remux.composer-dictation-debug")
    private var activeRun: Run?
    private lazy var audioLevels = configuration.audioLevels()

    init(configuration: GhosttyDebugComposerDictationConfiguration) {
        self.configuration = configuration
    }

    func prepare(locale: Locale) {}

    func start(
        id: UInt64,
        locale: Locale,
        requestedAt: UInt64,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            activeRun?.cancel()

            let run = Run(id: id, handler: handler)
            activeRun = run
            let startWork = DispatchWorkItem { [weak self, weak run] in
                guard let self,
                      let run,
                      activeRun === run else {
                    return
                }

                run.handler(.started)
                if configuration.audio != nil {
                    play(into: run)
                    return
                }
                for index in 0..<GhosttyComposerAudioLevelModel.historyCapacity {
                    run.handler(.audioLevel(0.14 + (CGFloat(index % 7) * 0.1)))
                }

                guard let transcript = configuration.transcript else { return }
                schedule(GhosttyDebugComposerDictationConfiguration.Hypothesis(at: 0.35, text: transcript), last: true, for: run)
            }
            run.startWork = startWork
            queue.asyncAfter(
                deadline: .now() + .milliseconds(180),
                execute: startWork
            )
        }
    }

    /// The recording as the microphone: a level each buffer, the room's quiet after it ends, and each result at its time.
    private func play(into run: Run) {
        let levels = audioLevels
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self, weak run] in
            guard let self, let run, activeRun === run else { return }
            let index = run.levelsPlayed
            run.handler(.audioLevel(index < levels.count ? levels[index] : 0.08))
            run.levelsPlayed += 1
        }
        let interval = GhosttyComposerAudioCaptureSession.bufferDuration
        timer.schedule(deadline: .now() + interval, repeating: interval)
        run.levelTimer = timer
        timer.resume()
        for (position, hypothesis) in configuration.hypotheses.enumerated() {
            schedule(hypothesis, last: position == configuration.hypotheses.count - 1, for: run)
        }
    }

    private func schedule(
        _ hypothesis: GhosttyDebugComposerDictationConfiguration.Hypothesis,
        last: Bool,
        for run: Run
    ) {
        let work = DispatchWorkItem { [weak self, weak run] in
            guard let self, let run, activeRun === run else { return }
            if last { run.deliveredHypothesis = true }
            run.handler(.hypothesis(hypothesis.text))
        }
        run.hypothesisWork.append(work)
        queue.asyncAfter(deadline: .now() + hypothesis.at, execute: work)
    }

    func finish(id: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  let run = activeRun,
                  run.id == id else {
                return
            }

            // Like a recognizer's final result, a stop delivers the transcript
            // even if the recording hasn't reached it yet.
            run.cancel()
            if let transcript = configuration.transcript, !run.deliveredHypothesis {
                run.deliveredHypothesis = true
                run.handler(.hypothesis(transcript))
            }
            activeRun = nil
            run.handler(.completed)
        }
    }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            if activeRun?.id == id {
                activeRun?.cancel()
                activeRun = nil
            }
            completion()
        }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            self?.activeRun?.cancel()
            self?.activeRun = nil
            completion()
        }
    }
}
#endif
