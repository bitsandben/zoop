import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// The daily scheduled debug auto-export: at the user's chosen time of day, writes the durable
/// strap-log tail (plus the raw 5/MG capture when one exists) to the app's Documents directory under
/// a `yyMMdd-HHmm` filename, once per day, with no UI. Opt-in, default OFF; nothing leaves the device.
///
/// - macOS: a foreground `DispatchSourceTimer` fires at the chosen minute; `catchUpIfDue()` covers a
///   time that passed while the app was closed.
/// - iOS: a `BGAppRefreshTaskRequest` for *no earlier than* the chosen time; iOS decides when it
///   runs, so no exact background drop is promised. If the handler isn't registered/permitted,
///   `submit` fails gracefully and "Run now" still works.
///
/// Retention (#650): every write is pruned to `keepCount` generations (default 14), oldest first,
/// and Test Centre offers a manual "Clear scheduled exports"; the files sit in Files-visible
/// Documents with no UI reminding anyone they exist.
@MainActor
enum ScheduledDebugExport {

    // MARK: - Persisted settings

    private enum K {
        static let enabled = "debugExport.enabled"          // master enable; default OFF
        static let time = "debugExport.timeMinutes"         // minutes since local midnight; default 07:00
        static let lastRun = "debugExport.lastRunDayKey"    // yyyy-MM-dd of the last completed drop (catch-up dedup)
        static let keepCount = "debugExport.keepCount"      // retention: generations to keep (#650)
    }

    /// 07:00.
    static let defaultTimeMinutes = 7 * 60
    private static let minutesPerDay = 24 * 60

    // MARK: - Retention

    /// Keep-count choices; longer than `FolderBackup.keepOptions` since an export is a small text/JSON pair.
    static let keepOptions = [3, 7, 14, 30, 60]

    private static let defaultKeepCount = 14

    /// Scheduled-export generations to keep (a day's log + raw-capture pair counts once); 0 means unset,
    /// clamped to 1...100.
    static var keepCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.keepCount)   // 0 when never set
            return v == 0 ? defaultKeepCount : min(max(v, 1), 100)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: K.keepCount) }
    }

    /// Filename prefixes of the two scheduled-export file kinds (log `.txt`, raw-capture `.json`).
    /// Nothing else in Documents matches, so retention and clear only touch scheduled drops.
    private static let logPrefix = "noop-strap-log-"
    private static let rawPrefix = "noop-raw-capture-"

    /// The `yyMMdd-HHmm` stamp in a scheduled-export filename, or nil if `name` isn't one of ours. Pure.
    static func exportStamp(fromFilename name: String) -> String? {
        if name.hasPrefix(logPrefix), name.hasSuffix(".txt") {
            return String(name.dropFirst(logPrefix.count).dropLast(4))
        }
        if name.hasPrefix(rawPrefix), name.hasSuffix(".json") {
            return String(name.dropFirst(rawPrefix.count).dropLast(5))
        }
        return nil
    }

    /// Stamps to prune so only the `keep` newest generations remain (a log+raw pair shares a stamp).
    /// The fixed-width stamp sorts correctly as a plain string. Empty when within budget.
    static func exportStampsToPrune(_ names: [String], keep: Int) -> Set<String> {
        let stamps = Array(Set(names.compactMap { exportStamp(fromFilename: $0) })).sorted(by: >)
        guard stamps.count > keep else { return [] }
        return Set(stamps.dropFirst(keep))
    }

    /// Best-effort retention after every write: deletes files beyond `keep` generations, oldest first;
    /// failures never fail the export.
    private static func pruneScheduledExports(in docs: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return }
        let toPrune = exportStampsToPrune(names, keep: keep)
        guard !toPrune.isEmpty else { return }
        for name in names {
            guard let stamp = exportStamp(fromFilename: name), toPrune.contains(stamp) else { continue }
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
    }

    /// Manual "Clear scheduled exports": deletes every scheduled-export file under Documents regardless
    /// of retention, touching nothing else. Returns the number removed.
    @discardableResult
    static func clearScheduledExports() -> Int {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return 0 }
        var removed = 0
        for name in names where exportStamp(fromFilename: name) != nil {
            if (try? fm.removeItem(at: docs.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// iOS BGTask identifier, derived from the bundle id so it matches `BGTaskSchedulerPermittedIdentifiers`.
    /// Must be registered at launch for `submit` to succeed.
    static let bgTaskIdentifier = (Bundle.main.bundleIdentifier ?? "com.zoopapp.zoop") + ".debugexport"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// A delivered BGAppRefresh request is single-shot and schedules its successor only while exports
    /// stay enabled; outside the iOS-only `register` block so the race is testable everywhere.
    static func backgroundTaskShouldResubmit(enabled: Bool) -> Bool { enabled }

    /// Time of day to export, minutes since local midnight, clamped to a valid minute.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(v, 0), minutesPerDay - 1)
    }

    // MARK: - Public API

    /// Enables/disables and (re)schedules; disabling cancels the schedule.
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.enabled)
        if on {
            scheduleNext()
            catchUpIfDue()
        } else {
            cancel()
        }
    }

    /// Updates the time of day and reschedules.
    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), minutesPerDay - 1), forKey: K.time)
        if isEnabled { scheduleNext() }
    }

    /// Call on app start and when Settings appears: re-arms the schedule and writes a drop missed while
    /// the app wasn't running. No-op when off.
    static func activateIfEnabled() {
        guard isEnabled else { return }
        scheduleNext()
        catchUpIfDue()
    }

    /// The "Run now" button: always writes, ignoring the daily dedup. The caller may pass the current raw
    /// 5/MG capture URL (`live.puffinCaptureURL`) to include the matched pair. Returns the log URL, or nil.
    @discardableResult
    static func runNow(captureURL: URL? = nil) -> URL? {
        performExport(markDay: false, captureURL: captureURL)
    }

    // MARK: - Scheduling

    private static var macTimer: DispatchSourceTimer?

    /// (Re)arms the next occurrence: a foreground timer on macOS, a background-refresh request on iOS.
    private static func scheduleNext() {
        #if os(macOS)
        macTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = secondsToNextOccurrence(timeMinutes)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            guard isEnabled else { return }
            _ = performExport(markDay: true)
            // Re-arm for the following day (one-shot, so a clock change can't drift it).
            scheduleNext()
        }
        timer.resume()
        macTimer = timer
        #elseif os(iOS)
        submitBackgroundRequest()
        #endif
    }

    /// Cancels any armed schedule.
    private static func cancel() {
        #if os(macOS)
        macTimer?.cancel()
        macTimer = nil
        #elseif os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        #endif
    }

    /// If today's drop is due (at/after the chosen time, not yet written today), writes it once.
    /// Returns `true` when nothing was attempted or the write succeeded, `false` only when an attempted
    /// export failed, so the BGTask handler reports the real outcome.
    @discardableResult
    private static func catchUpIfDue() -> Bool {
        guard isEnabled else { return true }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= timeMinutes else { return true }      // not yet time today
        guard UserDefaults.standard.string(forKey: K.lastRun) != dayKey(now) else { return true } // already ran today
        return performExport(markDay: true) != nil
    }

    /// Seconds until the next wall-clock occurrence of `minuteOfDay` (today if ahead, else tomorrow).
    private static func secondsToNextOccurrence(_ minuteOfDay: Int, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        comps.second = 0
        var target = cal.date(from: comps) ?? now
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return max(1, target.timeIntervalSince(now))
    }

    // MARK: - The export itself

    /// Writes the durable strap-log tail to `Documents/noop-strap-log-<yyMMdd-HHmm>.txt` and, if supplied,
    /// copies the raw 5/MG capture beside it. `markDay` records today for the daily dedup; "Run now"
    /// passes false.
    @discardableResult
    private static func performExport(markDay: Bool, captureURL: URL? = nil) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = FileExport.timestamp()
        let logURL = docs.appendingPathComponent("noop-strap-log-\(stamp).txt")
        do {
            try LiveState.scheduledExportText(extraHeaderLines: DebugDataDiagnostics.strapStateLines())
                .write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        // Best-effort copy of the raw capture; the background timer path has no live session and passes nil.
        if let capture = captureURL, FileManager.default.fileExists(atPath: capture.path) {
            let dest = docs.appendingPathComponent("noop-raw-capture-\(stamp).json")
            try? FileManager.default.copyItem(at: capture, to: dest)
        }
        if markDay {
            UserDefaults.standard.set(dayKey(Date()), forKey: K.lastRun)
        }
        // Retention (#650): prune after every write, scheduled or manual.
        pruneScheduledExports(in: docs, keep: keepCount)
        return logURL
    }

    /// yyyy-MM-dd local-day key for the once-per-day dedup (POSIX locale for stability).
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// Registers the BGTask handler. Must be called before launch finishes (`StrandiOSApp.init()`), with
    /// the identifier in `BGTaskSchedulerPermittedIdentifiers`. Safe to leave uncalled.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            // If the background budget runs out, report failure so the run is retried.
            task.expirationHandler = { completion.finish(success: false) }
            // BGAppRefresh is single-shot and `cancel` loses the race with an in-flight delivery, so gate the
            // successor on a fresh enabled read.
            guard backgroundTaskShouldResubmit(enabled: isEnabled) else {
                completion.finish(success: true)
                return
            }
            // Write the drop, then request the next one (`catchUpIfDue()` no-ops when nothing is due).
            let succeeded = catchUpIfDue()
            submitBackgroundRequest()
            completion.finish(success: succeeded)
        }
    }

    /// Guards `BGTask.setTaskCompleted` against a double call (normal path plus expirationHandler). Plain
    /// lock: the system may invoke the expiration handler on another queue.
    private final class TaskCompletionGuard {
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
            // Break the retain cycle task -> expirationHandler -> self -> task.
            task.expirationHandler = nil
        }
    }

    /// Submits a background-refresh request for no earlier than the next chosen time (best-effort);
    /// `try?` swallows "identifier not permitted/registered".
    private static func submitBackgroundRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: secondsToNextOccurrence(timeMinutes))
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
