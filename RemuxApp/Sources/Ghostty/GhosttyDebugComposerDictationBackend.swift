#if DEBUG
import Foundation

struct GhosttyDebugComposerDictationConfiguration: Sendable {
    let transcript: String?

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GhosttyDebugComposerDictationConfiguration? {
        if environment["REMUX_DEBUG_DICTATION_NO_SPEECH"] == "1" {
            return GhosttyDebugComposerDictationConfiguration(transcript: nil)
        }
        guard let transcript = environment["REMUX_DEBUG_DICTATION_TRANSCRIPT"],
              !transcript.isEmpty else {
            return nil
        }
        return GhosttyDebugComposerDictationConfiguration(transcript: transcript)
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
        var hypothesisWork: DispatchWorkItem?
        var completionWork: DispatchWorkItem?

        init(
            id: UInt64,
            handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
        ) {
            self.id = id
            self.handler = handler
        }

        func cancel() {
            startWork?.cancel()
            hypothesisWork?.cancel()
            completionWork?.cancel()
        }
    }

    private let configuration: GhosttyDebugComposerDictationConfiguration
    private let queue = DispatchQueue(label: "dev.remux.composer-dictation-debug")
    private var activeRun: Run?

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
                for index in 0..<GhosttyComposerAudioLevelModel.historyCapacity {
                    run.handler(.audioLevel(0.14 + (CGFloat(index % 7) * 0.1)))
                }

                guard let transcript = configuration.transcript else { return }
                let hypothesisWork = DispatchWorkItem { [weak self, weak run] in
                    guard let self,
                          let run,
                          activeRun === run else {
                        return
                    }
                    run.handler(.hypothesis(transcript))
                }
                run.hypothesisWork = hypothesisWork
                queue.asyncAfter(
                    deadline: .now() + .milliseconds(350),
                    execute: hypothesisWork
                )
            }
            run.startWork = startWork
            queue.asyncAfter(
                deadline: .now() + .milliseconds(180),
                execute: startWork
            )
        }
    }

    func finish(id: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  let run = activeRun,
                  run.id == id else {
                return
            }

            run.completionWork?.cancel()
            let completionWork = DispatchWorkItem { [weak self, weak run] in
                guard let self,
                      let run,
                      activeRun === run else {
                    return
                }
                run.handler(.completed)
            }
            run.completionWork = completionWork
            let delay: DispatchTimeInterval = configuration.transcript == nil
                ? .milliseconds(250)
                : .milliseconds(1_250)
            queue.asyncAfter(deadline: .now() + delay, execute: completionWork)
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
