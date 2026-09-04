import AudioToolbox
import UIKit

@MainActor
enum Haptic {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    // MARK: - Chrome press feedback (long-lived prepared generators)

    private static var keyboardImpact: UIImpactFeedbackGenerator?
    private static var chromeSelection: UISelectionFeedbackGenerator?

    /// Warm both keyboard-chrome generators so the first key/dock press has no
    /// cold-start latency. Idempotent.
    static func prewarmChromeFeedback() {
        if keyboardImpact == nil {
            keyboardImpact = UIImpactFeedbackGenerator(style: .light)
        }
        if chromeSelection == nil {
            chromeSelection = UISelectionFeedbackGenerator()
        }
        keyboardImpact?.prepare()
        chromeSelection?.prepare()
    }

    /// Touch-down feedback for an accessory key (ctrl / shift / esc / tab).
    /// Audio defaults to OFF: a normal-app view cannot honor iOS Settings >
    /// Keyboard Feedback > Sound, so we ship visual + haptic only and leave
    /// the audio click as an explicit caller opt-in.
    static func keyboardPress(playsAudio: Bool = false) {
        if keyboardImpact == nil {
            keyboardImpact = UIImpactFeedbackGenerator(style: .light)
        }
        keyboardImpact?.impactOccurred()
        keyboardImpact?.prepare()

        if playsAudio {
            // Public-API approximation of the iOS keyboard click; not exact
            // parity. Plays via the ringer/silent path.
            AudioServicesPlaySystemSound(1104)
        }
    }

    /// Touch-down feedback for chrome navigation/toggle controls (home,
    /// windows, panes, keyboard toggle). Selection tic - canonical for
    /// nav/toggle controls and materially quieter than the key impact.
    static func chromeControlPress() {
        if chromeSelection == nil {
            chromeSelection = UISelectionFeedbackGenerator()
        }
        chromeSelection?.selectionChanged()
        chromeSelection?.prepare()
    }
}
