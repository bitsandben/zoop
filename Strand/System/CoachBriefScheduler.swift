import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
import WidgetKit
#endif

/// A user-scheduled local notification delivering a one-line morning coaching brief, generated
/// on-device through the user's configured Coach provider. Tap opens Coach with the full brief.
/// Default OFF; no push server.
///
/// - macOS: a foreground `DispatchSourceTimer` fires at the chosen minute; `catchUpIfDue` covers a
///   time that passed while the app was closed.
/// - iOS: a `BGAppRefreshTaskRequest` for *no earlier than* the chosen time (best-effort); a missed
///   slot is caught up by the next `activateIfEnabled`.
///
/// Network call is gated on `enabled`, a saved Coach key and `dataConsent`. A failed generation never
/// marks the day done, so it retries on the next wake.
@MainActor
enum CoachBriefScheduler {

    // MARK: - Persisted settings

    private enum K {
        static let enabled = "coachBrief.enabled"          // master enable; default OFF
        static let time = "coachBrief.timeMinutes"         // minutes since local midnight; default 07:00
        static let lastRun = "coachBrief.lastRunDayKey"    // yyyy-MM-dd of the last GENERATED brief (dedup)
        static let storedBrief = "coachBrief.storedText"   // the full brief, for the notification tap-through
        static let hasUnconsumed = "coachBrief.hasUnconsumedBrief"
        // Brief text mirrored into the App Group; the widget process can't see `UserDefaults.standard`.
        static let widgetBriefKey = "coachBrief.widgetText"
        static let widgetBriefDateKey = "coachBrief.widgetDate"
    }

    /// 07:00.
    static let defaultTimeMinutes = 7 * 60
    private static let minutesPerDay = 24 * 60

    /// Category id on the posted notification so `NotificationPresenter` routes a brief tap to Coach.
    static let notificationCategoryId = "coach-brief"
    private static let requestIdPrefix = "coach-brief-"

    /// The Coach master switch (`zoop.coachEnabled`).
    ///
    /// Uses `object(forKey:)` because the pref defaults to TRUE and `bool(forKey:)` answers FALSE for an
    /// unwritten key.
    static var coachMasterEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "zoop.coachEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "zoop.coachEnabled")
    }

    /// Tears down the brief's leftovers when the Coach master switch goes off: cancels the schedule,
    /// clears the widget and removes delivered/pending brief notifications.
    ///
    /// One-directional: re-arming happens in `activateIfEnabled` when `CoachView` appears.
    static func applyMasterSwitch(_ on: Bool) {
        guard !on else { return }
        cancel()
        // Delivered briefs would otherwise stay tappable in Notification Centre after the AI is off.
        let centre = UNUserNotificationCenter.current()
        centre.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(requestIdPrefix) }
            guard !ids.isEmpty else { return }
            centre.removeDeliveredNotifications(withIdentifiers: ids)
        }
        centre.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(requestIdPrefix) }
            guard !ids.isEmpty else { return }
            centre.removePendingNotificationRequests(withIdentifiers: ids)
        }
        #if os(iOS)
        publishToWidget(nil)
        #endif
    }

    /// Whether the daily brief should run: its own flag AND the Coach master switch.
    static var isEnabled: Bool { coachMasterEnabled && UserDefaults.standard.bool(forKey: K.enabled) }

    /// Time of day to generate, minutes since local midnight, clamped to a valid minute.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(v, 0), minutesPerDay - 1)
    }

    /// The latest generated brief (for the notification tap-through), or nil before the first one.
    static var storedBrief: String? { UserDefaults.standard.string(forKey: K.storedBrief) }

    /// True when a generated brief hasn't yet been surfaced in the Coach transcript.
    static var hasUnconsumedBrief: Bool { UserDefaults.standard.bool(forKey: K.hasUnconsumed) }

    /// Coach calls this once on appear to surface the stored brief; returns nil when nothing is unconsumed.
    static func consumeStoredBrief() -> String? {
        guard hasUnconsumedBrief, let text = storedBrief else { return nil }
        UserDefaults.standard.set(false, forKey: K.hasUnconsumed)
        return text
    }

    // MARK: - Widget-facing API (App Group, iOS only)

    #if os(iOS)
    /// Publishes (or clears, with nil) the brief into the App Group for the widget extension.
    static func publishToWidget(_ text: String?) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return }
        if let text {
            defaults.set(text, forKey: K.widgetBriefKey)
            defaults.set(Date(), forKey: K.widgetBriefDateKey)
        } else {
            defaults.removeObject(forKey: K.widgetBriefKey)
            defaults.removeObject(forKey: K.widgetBriefDateKey)
        }
        // Reload the widget timeline; `kind` must match `CoachBriefWidget`.
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
    #endif

    /// WidgetKit kind for the coach-brief widget; must match `CoachBriefWidget` in `StrandiOSWidgets/`.
    static let widgetKind = "CoachBriefWidget"

    // MARK: - Enable / configure (Settings calls these)

    /// Outcome of enabling the schedule, so the UI can revert the toggle and point at Settings on denial.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enables/disables and (re)schedules. Enabling first checks notification authorization (asking once
    /// if undetermined) and reports `.denied` rather than scheduling something the OS won't deliver.
    /// `completion` runs on the main actor.
    static func setEnabled(_ on: Bool,
                            generateBrief: @escaping () async -> String?,
                            completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            cancel()
            #if os(iOS)
            publishToWidget(nil)  // K10: clear the widget when the feature is turned off
            #endif
            completion?(.off)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    scheduleNext(generateBrief: generateBrief)
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: K.enabled)
                                scheduleNext(generateBrief: generateBrief)
                                completion?(.scheduled)
                            } else {
                                UserDefaults.standard.set(false, forKey: K.enabled)
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Updates the time of day and reschedules.
    static func setTimeMinutes(_ minutes: Int, generateBrief: @escaping () async -> String?) {
        UserDefaults.standard.set(min(max(minutes, 0), minutesPerDay - 1), forKey: K.time)
        if isEnabled { scheduleNext(generateBrief: generateBrief) }
    }

    /// Call when Coach appears: re-arms the schedule and generates once if a slot was missed. No-op when off.
    static func activateIfEnabled(generateBrief: @escaping () async -> String?) {
        guard isEnabled else { return }
        scheduleNext(generateBrief: generateBrief)
        Task { await catchUpIfDue(generateBrief: generateBrief) }
    }

    /// The "Generate now" button: always generates and stores, ignoring the once-per-day dedup. Posts no
    /// notification and leaves `lastRun` alone. Returns nil on failure.
    @discardableResult
    static func generateNow(generateBrief: () async -> String?) async -> String? {
        await generateBrief()
    }

    // MARK: - Due check + generation

    /// Whether a generation attempt is in flight.
    ///
    /// `lastRun` is written only after success, so the day guard stays open across the `await`; without
    /// this claim a cold launch onto Coach could run two generations (two provider calls, two
    /// notifications). MainActor-isolated because callers arrive on different executors.
    @MainActor private static var generationInFlight = false

    /// Takes the single generation slot, or reports that another attempt holds it.
    @MainActor private static func claimGeneration() -> Bool {
        guard !generationInFlight else { return false }
        generationInFlight = true
        return true
    }

    /// Releases the generation slot; called right after the attempt on both outcomes.
    @MainActor private static func releaseGeneration() { generationInFlight = false }

    /// If today's brief is due, generates it once: stores the text, marks today done, posts the notification.
    ///
    /// Returns `true` when there was nothing to do or generation succeeded; `false` only when generation
    /// failed, so the BGTask handler can report the real outcome.
    @discardableResult
    static func catchUpIfDue(generateBrief: () async -> String?) async -> Bool {
        guard isEnabled else { return true }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= timeMinutes else { return true }                                  // not yet time today
        guard UserDefaults.standard.string(forKey: K.lastRun) != dayKey(now) else { return true } // already ran today

        // One attempt at a time; see `generationInFlight`.
        guard await claimGeneration() else { return true }
        let generated = await generateBrief()
        await releaseGeneration()

        guard let text = generated else {
            // Never mark the day done on failure; post a low-key retry notification.
            postNotification(title: String(localized: "Coach brief unavailable"),
                              body: String(localized: "Couldn't generate today's brief. Tap to try again in Coach."),
                              isRetry: true)
            return false
        }

        UserDefaults.standard.set(dayKey(now), forKey: K.lastRun)
        UserDefaults.standard.set(text, forKey: K.storedBrief)
        UserDefaults.standard.set(true, forKey: K.hasUnconsumed)
        #if os(iOS)
        publishToWidget(text)  // K10: mirror into the App Group for the widget
        #endif
        // The proactive morning brief may already have announced today; one coach push per morning.
        if claimMorningPush(day: dayKey(now)) {
            postNotification(title: String(localized: "Today's coaching brief"),
                              body: oneLineSummary(from: text))
        }
        return true
    }

    /// The local day a coach push (this scheduled brief or the proactive morning brief) last went out.
    private static let morningPushDayKey = "zoop.coach.morningPushDay"

    /// Claims today's single coach push. False when one already went out for `day`.
    static func claimMorningPush(day: String) -> Bool {
        guard UserDefaults.standard.string(forKey: morningPushDayKey) != day else { return false }
        UserDefaults.standard.set(day, forKey: morningPushDayKey)
        return true
    }

    /// Pure: the brief's first non-empty line, trimmed and length-capped for a notification banner.
    static func oneLineSummary(from brief: String, maxLength: Int = 120) -> String {
        let firstLine = brief
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? brief
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return trimmed[..<cut].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func postNotification(title: String, body: String, isRetry: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = notificationCategoryId
        // Immediate delivery; one id per day so a retry replaces the earlier notification.
        let request = UNNotificationRequest(identifier: requestIdPrefix + dayKey(Date()),
                                            content: content, trigger: nil)
        NotificationWork.run { $0.add(request) }
    }

    /// yyyy-MM-dd local-day key for the once-per-day dedup (POSIX locale for stability).
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
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

    // MARK: - Scheduling

    private static var macTimer: DispatchSourceTimer?

    /// (Re)arms the next occurrence: a foreground timer on macOS, a background-refresh request on iOS.
    private static func scheduleNext(generateBrief: @escaping () async -> String?) {
        #if os(macOS)
        macTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = secondsToNextOccurrence(timeMinutes)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            Task { @MainActor in
                guard isEnabled else { return }
                _ = await catchUpIfDue(generateBrief: generateBrief)
                scheduleNext(generateBrief: generateBrief)
            }
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

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// BGTask identifier, derived from the bundle id; must match `BGTaskSchedulerPermittedIdentifiers`.
    static let bgTaskIdentifier = (Bundle.main.bundleIdentifier ?? "com.zoopapp.zoop") + ".coachbrief"
    private static var logBackgroundFailure: ((String) -> Void)?

    /// Registers the BGTask handler. Must be called before app launch finishes (`StrandiOSApp.init()`).
    static func register(generateBrief: @escaping () async -> String?, log: @escaping (String) -> Void) {
        logBackgroundFailure = log
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                task.expirationHandler = { completion.finish(success: false) }
                guard isEnabled else {
                    completion.finish(success: true)
                    return
                }
                let succeeded = await catchUpIfDue(generateBrief: generateBrief)
                // Single-shot: always request the next occurrence so a failure retries at the next wake.
                submitBackgroundRequest()
                completion.finish(success: succeeded)
            }
            task.expirationHandler = { worker.cancel(); completion.finish(success: false) }
        }
    }

    /// `BGTask` completion is single-shot even when the normal path races expiration.
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
            task.expirationHandler = nil
        }
    }

    /// Submits a background-refresh request for no earlier than the next chosen time (best-effort).
    private static func submitBackgroundRequest() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: secondsToNextOccurrence(timeMinutes))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logBackgroundFailure?("coach brief: background request refused (\(error.localizedDescription))")
        }
    }
    #endif
}
