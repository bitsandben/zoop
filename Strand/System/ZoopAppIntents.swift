import AppIntents

/// Inbound automation: exposes strap actions as Shortcuts / Spotlight actions (the outbound
/// counterpart, strap double-tap to a macOS Shortcut, is in MacActions.swift).
///
/// Intents reach the live, bonded `AppModel` via `AppModel.shared`; a fresh `AppModel()` would start
/// a second BLEManager and analysis loop and could never buzz. The `weak` accessor lets an intent
/// fired while Zoop is closed fail with a clear "open Zoop" message.

@available(macOS 13.0, *)
enum NOOPIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:   return "Open Zoop first so it can reach your strap."
        case .notConnected: return "Connect your WHOOP strap in Zoop, then try again."
        }
    }
}

@available(macOS 13.0, *)
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Vibrate your connected WHOOP strap.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        guard model.live.bonded else { throw NOOPIntentError.notConnected }
        // A bare RUN_HAPTICS_PATTERN write could be silently ignored by a WHOOP 4.0; the one-shot routine sends the acked confirmed sequence.
        model.buzzStrapOnce()
        return .result()
    }
}

@available(macOS 13.0, *)
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment (and buzz the strap if it's connected).")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // markMoment() records regardless of bond (the confirming buzz no-ops when unbonded).
        guard let model = AppModel.shared else { throw NOOPIntentError.notRunning }
        model.markMoment()
        return .result()
    }
}

/// Surfaces the actions in Shortcuts.app with suggested phrases.
@available(macOS 13.0, *)
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my strap with \(.applicationName)", "Buzz \(.applicationName)"],
                    shortTitle: "Buzz Strap", systemImageName: "waveform")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment with \(.applicationName)", "Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment", systemImageName: "mappin.and.ellipse")
    }
}
