import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Runs a backgrounded re-score somewhere it can finish, and records honestly when one did not. See
/// `RescoreBackgroundPolicy` for the problem (#1538) and the decision rules; this is the plumbing:
/// the durable "re-score owed" mark, the measured duration, the iOS execution assertion and the
/// `BGProcessingTask` work is escalated to.
///
/// `BGProcessingTask` rather than `BGAppRefreshTask` (metered for short work). iOS picks when it runs
/// (favouring idle and charging), so this guarantees "eventually", not a score moments after a sync.
///
/// - macOS: no suspension deadline; every entry point is a no-op reporting `.run`.
/// - iOS: needs the `processing` background mode, the identifier in `BGTaskSchedulerPermittedIdentifiers`
///   and `register()` before launch finishes; otherwise `submit` fails gracefully and the foreground
///   path still scores.
@MainActor
enum RescoreBackgroundScheduler {

    /// A re-score is OWED: a pass started and never finished (killed), or a trigger deferred one to a
    /// background task. Persisted, since the kill is the event the process can't record.
    static let owedKey = "zoop.rescoreOwed"
    /// Seconds the last COMPLETED pass took.
    static let lastPassSecondsKey = "zoop.rescoreLastPassSeconds"

    /// Identifies the most recent debt so a pass can tell its own from a newer one (#1681). A token, not a
    /// counter: concurrent marks each write a distinct token (last wins), where a counter's
    /// read-modify-write could lose an increment.
    static let owedTokenKey = "zoop.rescoreOwedToken"

    /// Whether the outstanding debt was left by a pass that COMPLETED but couldn't settle (out-voted by a
    /// newer token) rather than one killed partway. A killed pass never advanced `analyzeWatermarkKey`, so
    /// its resume must force; a completed one did, so its resume can consult the fingerprint and stand
    /// down. Forcing both made a 5-minute Oura drain re-score 21 nights back to back (#2238).
    static let owedAfterCompletedPassKey = "zoop.rescoreOwedAfterCompletedPass"

    static var isRescoreOwed: Bool { UserDefaults.standard.bool(forKey: owedKey) }

    /// True only while the debt came from a completed-but-unsettled pass; cleared by the next `markRescoreOwed()`.
    static var isOwedAfterCompletedPass: Bool {
        UserDefaults.standard.bool(forKey: owedAfterCompletedPassKey)
    }

    static var currentOwedToken: String? { UserDefaults.standard.string(forKey: owedTokenKey) }

    static var lastCompletedPassSeconds: Double? {
        guard UserDefaults.standard.object(forKey: lastPassSecondsKey) != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: lastPassSecondsKey)
        return value.isFinite && value > 0 ? value : nil
    }

    /// When the last pass started (unix seconds); written only by a pass about to work, never by deferral.
    static let lastAttemptStartedAtKey = "zoop.rescoreLastAttemptStartedAt"

    /// Seconds since the last pass started, nil if none recorded.
    static var secondsSinceLastAttempt: Double? {
        let started = UserDefaults.standard.double(forKey: lastAttemptStartedAtKey)
        return started > 0 ? Date().timeIntervalSince1970 - started : nil
    }

    /// Marks a re-score as owed, from `IntelligenceEngine` once a pass is about to work, and from the
    /// deferral path. Returns the token stamped on this debt; a pass hands it back at completion.
    /// - Parameter passStarting: the caller is a pass about to work, so the attempt time is recorded for
    ///   `RescoreBackgroundPolicy.interruptedRetryCooldownSeconds`.
    @discardableResult
    static func markRescoreOwed(passStarting: Bool = false) -> String {
        let token = UUID().uuidString
        if passStarting {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAttemptStartedAtKey)
        }
        UserDefaults.standard.set(true, forKey: owedKey)
        UserDefaults.standard.set(token, forKey: owedTokenKey)
        // A fresh debt is unproven until its pass finishes; cleared here so the flag describes the current debt (#2238).
        UserDefaults.standard.set(false, forKey: owedAfterCompletedPassKey)
        return token
    }

    /// May a pass holding `capturedToken` settle the debt? Only if nothing newer was recorded while it
    /// ran (#1681: completion used to clear one global flag, erasing a debt recorded for data that
    /// arrived after the pass read its inputs). A pass with no token never settles: an extra pass costs
    /// battery, the other direction costs a night's scores. Pure.
    static func maySettleDebt(capturedToken: String?, currentToken: String?) -> Bool {
        guard let capturedToken, !capturedToken.isEmpty else { return false }
        return capturedToken == currentToken
    }

    /// Settles the debt at the end of a completed pass, beside the watermark advance; a killed pass never
    /// reaches this. Settles only if `owedToken` is still current (`maySettleDebt`); the duration is
    /// recorded either way. Returns whether it settled, so the caller can log when it did not.
    @discardableResult
    static func markRescoreCompleted(seconds: Double, owedToken: String?) -> Bool {
        let settled = maySettleDebt(capturedToken: owedToken, currentToken: currentOwedToken)
        if settled {
            UserDefaults.standard.set(false, forKey: owedKey)
        } else {
            // This pass finished and advanced the watermark; only a newer token outvoted it. Record that so the resume can gate on the fingerprint (#2238).
            UserDefaults.standard.set(true, forKey: owedAfterCompletedPassKey)
        }
        if seconds.isFinite, seconds > 0 {
            UserDefaults.standard.set(seconds, forKey: lastPassSecondsKey)
        }
        return settled
    }

    /// Whether the app is somewhere a long pass might not survive; always false on macOS. Anything not
    /// `.active` counts, `.inactive` included: it is the state on the way to suspension, and mistaking it
    /// for foreground loses work while the reverse costs a deferral the next `.active` drains.
    static var isBackgrounded: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    /// Decides, then runs `work` under an execution assertion or leaves it for `BGProcessingTask`. `log`
    /// always receives the decision and its reason (#1538). `isBackground` is a parameter only so a test
    /// can reach the deferral branch.
    /// - Parameter owesOnDefer: whether a deferral records a debt. True for a real update path (a
    ///   completed offload must eventually be scored); false for the steady-state backstop tick, which
    ///   would otherwise conjure a forced full pass when likely nothing changed (#1146).
    /// - Parameter passInProgress: a pass is already running; see `RescoreBackgroundPolicy.decide`.
    static func run(isBackground: Bool? = nil,
                    owesOnDefer: Bool = true,
                    passInProgress: Bool = false,
                    log: @escaping (String) -> Void,
                    work: () async -> Void) async {
        let decision = RescoreBackgroundPolicy.decide(
            isBackground: isBackground ?? isBackgrounded,
            isRealUpdate: owesOnDefer,
            rescoreAlreadyOwed: isRescoreOwed,
            passInProgress: passInProgress,
            secondsSinceLastAttempt: secondsSinceLastAttempt)

        switch decision {
        case .deferToBackgroundTask(let reason):
            guard owesOnDefer else {
                // Nothing is queued or owed; say so rather than log "deferred", which promises a task that isn't coming.
                log("re-score: backstop tick skipped while backgrounded — \(reason)")
                return
            }
            // Record the debt BEFORE scheduling, or the background task finds nothing owed and the work is dropped.
            markRescoreOwed()
            log("re-score: deferred to a background task — \(reason)")
            schedule()
        case .run:
            await withAssertion(log: log, work: work)
        }
    }

    /// Times the re-score execution assertion has expired in this process; read at pass start and end for the cost line.
    private(set) static var assertionExpiries = 0

    /// CPU seconds used by this process (user + system, all threads, so including BLE and UI work); nil if the read fails.
    nonisolated static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// What a completed pass cost and whether it outlived its background grant. Uptime keeps running
    /// while suspended, so CPU time beside it separates a mostly-suspended pass from one that ran past an
    /// expired assertion.
    nonisolated static func passCostLogLine(cpuSeconds: Double?, elapsedSeconds: Double,
                                            assertionExpiries: Int, backgroundedAtEnd: Bool) -> String {
        let cpu = cpuSeconds.map { String(format: "%.1fs", max(0, $0)) } ?? "n/a"
        let share = cpuSeconds.flatMap { elapsedSeconds > 0 ? Int((max(0, $0) / elapsedSeconds * 100).rounded()) : nil }
        return "re-score: cost cpu=\(cpu) elapsed=\(String(format: "%.1f", elapsedSeconds))s"
            + " cpuShare=\(share.map { "\($0)%" } ?? "n/a") assertionExpired=\(assertionExpiries)"
            + " backgrounded=\(backgroundedAtEnd)"
    }

    /// Rests between units of re-score work when backgrounded, to stay under iOS's background CPU limit
    /// (`RescoreBackgroundPolicy.backgroundRestPerWorkSecond`). `mark` is the uptime (ns) the work since
    /// the last rest started; it is left alone until a quantum of work builds up and reset after a rest
    /// or in the foreground.
    nonisolated static func paceIfBackgrounded(since mark: inout UInt64) async {
        let workSeconds = Double(DispatchTime.now().uptimeNanoseconds &- mark) / 1_000_000_000
        let background = await MainActor.run { isBackgrounded }
        let rest = RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: workSeconds, isBackground: background)
        if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
        if rest > 0 || !background { mark = DispatchTime.now().uptimeNanoseconds }
    }

    /// Holds an execution assertion for the duration of `work` so a short pass isn't suspended halfway;
    /// a long one still outlives the grant, and the expiry handler logs and escalates it.
    private static func withAssertion(log: @escaping (String) -> Void, work: () async -> Void) async {
        #if os(iOS)
        let assertion = BackgroundAssertion()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "zoop.rescore") {
            // iOS calls this on the main thread when reclaiming the assertion. The pass can't be cancelled
            // from here (its loop runs in a detached task), so record and escalate; the owed mark is still set.
            MainActor.assumeIsolated {
                assertionExpiries += 1
                log("re-score: background time expired mid-pass — it resumes on the next wake (#1538)")
                schedule()
                assertion.end()
            }
        }
        assertion.store(taskID)
        await work()
        // Idempotent under the box's lock, so expiry and this path can't double-end the task.
        assertion.end()
        #else
        await work()
        #endif
    }

    // MARK: - iOS background-processing plumbing

    #if os(iOS)
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.zoopapp.zoop") + ".rescore"

    /// Registers the handler. Must be called from `StrandiOSApp.init()` before launch finishes, with the
    /// identifier in `BGTaskSchedulerPermittedIdentifiers`, or iOS never delivers the task. `onExpire`
    /// reports iOS reclaiming the processing time before the pass finished.
    static func register(perform operation: @escaping @MainActor () async -> Void,
                         onExpire: @escaping @MainActor () -> Void = {}) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                await operation()
                guard !Task.isCancelled else { return }
                // Re-arm only while work remains; a processing task is single-shot.
                if isRescoreOwed { schedule() }
                completion.finish(success: !isRescoreOwed)
            }
            task.expirationHandler = {
                worker.cancel()
                Task { @MainActor in onExpire() }
                // Out of budget: ask for another rather than drop the work, and report failure honestly.
                schedule()
                completion.finish(success: false)
            }
        }
    }

    /// Keeps exactly one pending request, so repeated calls are idempotent and repair a discarded request.
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        // Neither is required: the app is offline, and demanding power would strand non-overnight chargers.
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Holds the background-task identifier so the normal path and the expiry handler end it exactly once
    /// (UIKit treats a double or missing `endBackgroundTask` as an error). Plain lock, like `TaskCompletionGuard`.
    private final class BackgroundAssertion: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UIBackgroundTaskIdentifier = .invalid

        func store(_ newID: UIBackgroundTaskIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            id = newID
        }

        @MainActor func end() {
            lock.lock()
            let current = id
            id = .invalid
            lock.unlock()
            guard current != .invalid else { return }
            UIApplication.shared.endBackgroundTask(current)
        }
    }

    /// Guards `setTaskCompleted` against a double call (normal path plus expiration handler). Plain lock:
    /// iOS may invoke the expiration handler on another queue.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
    #else
    /// macOS has no background-task scheduler or suspension deadline.
    static func schedule() {}
    #endif
}
