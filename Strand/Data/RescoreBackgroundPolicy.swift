import Foundation

/// Decides whether a re-score triggered while the app is backgrounded starts now or is handed to a
/// background-processing task.
///
/// `analyzeRecent` is all-or-nothing (the watermark advances only at the very end), so a pass that iOS
/// kills mid-run loses all its work and the next trigger starts the same doomed pass again (#1538).
/// A backgrounded pass therefore paces itself under the background CPU limit (see
/// `backgroundRestPerWorkSecond`); this type only decides whether one should start at all. It does not
/// make the pass itself cheaper: a cold process still re-scores every night in the window.
enum RescoreBackgroundPolicy {

    /// What a background-initiated re-score should do.
    enum Decision: Equatable {
        /// Start the pass now, under an execution assertion.
        case run
        /// Do not start it; leave the work marked pending for a background-processing task or the next
        /// foreground. The reason is logged verbatim to the strap log.
        case deferToBackgroundTask(reason: String)
    }

    /// How long a backgrounded pass rests per second of work it just did.
    ///
    /// iOS terminates a background process that holds more than 80% CPU over 60 s (`cpu_resource_fatal`);
    /// resting as long as it worked holds the pass near 50%. A suspension between rests is harmless: the
    /// pass resumes on the next wake.
    static let backgroundRestPerWorkSecond: Double = 1.0

    /// The longest single rest. Work timed on the uptime clock can include a suspension spent mid-unit;
    /// resting for all of it would stall an already idle pass.
    static let maxBackgroundRestSeconds: Double = 30

    /// How much work a backgrounded pass does between rests.
    ///
    /// Resting after every night made a pass advance about one night per wake, because a sleeping
    /// background process is what iOS suspends until the next Bluetooth wake. Ten seconds of work then ten
    /// of rest keeps the ~50% ceiling with one suspension opportunity per quantum.
    static let backgroundWorkQuantumSeconds: Double = 10

    /// Seconds to rest after `workSeconds` of re-score work since the last rest. Zero until a quantum has
    /// accumulated, always zero in the foreground, and zero for a non-finite measurement.
    static func restSeconds(afterWorkSeconds workSeconds: Double, isBackground: Bool) -> Double {
        guard isBackground, workSeconds.isFinite, workSeconds >= backgroundWorkQuantumSeconds else { return 0 }
        return min(workSeconds * backgroundRestPerWorkSecond, maxBackgroundRestSeconds)
    }

    /// - Parameters:
    ///   - isBackground: the app is backgrounded. A foregrounded app is never deferred.
    ///   - isRealUpdate: the trigger carries new data (an offload) rather than the steady-state backstop
    ///     tick. A backgrounded backstop never runs.
    ///   - rescoreAlreadyOwed: a re-score is outstanding, either a pass that marked itself started and never
    ///     finished (the mark survives process death) or an earlier deferral.
    ///   - passInProgress: a pass is running in THIS process. Its own started-mark reads as owed, so it is
    ///     not evidence of a killed pass; deferring here left a debt the running pass never settled (#1681).
    ///   - secondsSinceLastAttempt: seconds since the last pass STARTED, nil when unknown. Outstanding debt
    ///     defers only while that is within `interruptedRetryCooldownSeconds`; any offload defers while it
    ///     is under `backgroundSpacingSeconds`.
    static func decide(isBackground: Bool,
                       isRealUpdate: Bool = true,
                       rescoreAlreadyOwed: Bool,
                       passInProgress: Bool = false,
                       secondsSinceLastAttempt: Double? = nil) -> Decision {
        guard isBackground else { return .run }

        guard isRealUpdate else {
            return .deferToBackgroundTask(
                reason: "the backstop tick does not re-score while backgrounded; offloads run their own")
        }

        if rescoreAlreadyOwed, !passInProgress,
           let since = secondsSinceLastAttempt, since >= 0, since < interruptedRetryCooldownSeconds {
            return .deferToBackgroundTask(
                reason: "a re-score is already outstanding from an earlier trigger")
        }

        if !passInProgress, let since = secondsSinceLastAttempt, since >= 0, since < backgroundSpacingSeconds {
            return .deferToBackgroundTask(
                reason: "the last pass started \(Int(since / 60)) min ago; a backgrounded offload re-scores"
                    + " at most every \(Int(backgroundSpacingSeconds / 60)) min")
        }

        return .run
    }

    /// How long after an unfinished attempt a backgrounded offload waits before retrying.
    ///
    /// Deferring on any outstanding debt without an end stopped scoring outright (iOS also kills suspended
    /// apps for memory, and the processing task is rarely granted). Pacing already keeps attempts under
    /// the CPU limit, so this only prevents a retry on every offload.
    static let interruptedRetryCooldownSeconds: Double = 30 * 60

    /// The least time between the starts of two backgrounded offload re-scores.
    ///
    /// A strap offloads about every ten minutes and each offload re-scored the whole window, mostly a night
    /// still in progress. Spacing cuts that background CPU roughly 3x. The work is moved, not dropped: the
    /// deferral records the debt, settled by the first offload past the spacing, the processing task or
    /// the next foreground. A foregrounded pass is never spaced.
    static let backgroundSpacingSeconds: Double = 30 * 60
}
