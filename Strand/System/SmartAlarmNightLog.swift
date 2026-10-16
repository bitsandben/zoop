import Foundation
import Combine
import StrandAnalytics

/// The goal-based smart alarm's settings, read by the planner UI and the night checks from one place.
enum GoalWakeSettings {
    static let modeKey = "zoop.smartWake.mode"
    static let thresholdKey = "zoop.smartWake.recoveryThreshold"
    static let preferLightKey = "zoop.smartWake.preferLight"
    /// Window used by the goal modes while the stored window is 0 (a plain alarm has no window).
    static let defaultGoalWindowMinutes = 30
    static let thresholdChoices = [50, 60, 67, 75, 80, 90]

    static var mode: GoalWake.Mode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(GoalWake.Mode.init(rawValue:)) ?? .fixedTime
    }

    static var recoveryThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: thresholdKey)
        return (1...100).contains(v) ? v : GoalWake.defaultRecoveryThreshold
    }

    static var preferLightSleep: Bool {
        UserDefaults.standard.object(forKey: preferLightKey) as? Bool ?? true
    }

    static var settings: GoalWake.Settings {
        GoalWake.Settings(mode: mode, recoveryThreshold: Double(recoveryThreshold), preferLightSleep: preferLightSleep)
    }

    /// The window length in effect: the gentle-wake window for a fixed time (0 = plain alarm), never 0 for a goal.
    static var windowMinutes: Int {
        let stored = SmartWakeWindow.windowMinutes
        return mode == .fixedTime ? stored : (stored > 0 ? stored : defaultGoalWindowMinutes)
    }
}

/// Local, on-device log of the last 30 smart-alarm nights (JSON in Application Support), for the Test Centre's
/// "Smart alarm nights" page and the planner's morning line. Only what the app itself observed is written.
@MainActor
final class SmartAlarmNightLog: ObservableObject {
    static let shared = SmartAlarmNightLog()
    static let keepNights = 30
    /// Events are filed under a night from this long before its window until shortly after its deadline.
    static let eventLeadS = 10 * 3600
    static let eventTailS = 30 * 60

    @Published private(set) var nights: [SmartAlarmNight] = []

    private let url: URL?

    init(url: URL? = SmartAlarmNightLog.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([SmartAlarmNight].self, from: data) {
            nights = SmartAlarmNight.pruned(saved, keep: Self.keepNights)
        }
    }

    nonisolated static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("SmartAlarm", isDirectory: true).appendingPathComponent("nights.json")
    }

    func night(deadline: Int) -> SmartAlarmNight? { nights.first { $0.deadline == deadline } }

    /// The night an event at `now` belongs to.
    func current(now: Int) -> SmartAlarmNight? {
        nights.first { now >= $0.windowStart - Self.eventLeadS && now <= $0.deadline + Self.eventTailS }
    }

    /// The newest night whose wake has happened (early wake armed and due, or the deadline passed).
    func lastFinished(now: Int) -> SmartAlarmNight? {
        nights.first { n in n.deadline <= now || (n.earlyWake.map { $0.wakeAt <= now } ?? false) }
    }

    /// Creates or refreshes the night ending at `deadline`. Settings and the plan are fixed once the window opens.
    func begin(deadline: Int, window: GoalWake.Window, settings: GoalWake.Settings, needMin: Double?,
               plannedChecks: [Int], now: Int) {
        if var n = night(deadline: deadline) {
            if now < n.windowStart {
                n.windowStart = window.start
                n.settings = settings
                n.plannedChecks = plannedChecks
                if needMin != nil { n.needMin = needMin }
            }
            replace(n)
        } else {
            replace(SmartAlarmNight(deadline: deadline, windowStart: window.start, settings: settings,
                                    needMin: needMin, plannedChecks: plannedChecks))
        }
    }

    func update(deadline: Int, _ change: (inout SmartAlarmNight) -> Void) {
        guard var n = night(deadline: deadline) else { return }
        change(&n)
        replace(n)
    }

    func recordArm(deadline: Int, target: Int, connected: Bool, now: Int) {
        update(deadline: deadline) { night in
            // Re-arms of the same time on every foreground are not news; a change of time or of delivery is.
            if let last = night.arms.last, last.target == target, last.connected == connected { return }
            night.arms.append(.init(at: now, target: target, connected: connected))
        }
    }

    func recordEvent(_ kind: SmartAlarmNight.EventKind, now: Int = Int(Date().timeIntervalSince1970)) {
        guard let n = current(now: now) else { return }
        update(deadline: n.deadline) { night in
            // One line per kind per minute: a foreground/background flap is not news.
            if let last = night.events.last, last.kind == kind, now - last.at < 60 { return }
            night.events.append(.init(at: now, kind: kind))
            if kind == .strapAlarmFired, now >= night.windowStart - 60, now <= night.deadline + 120 {
                night.strapFiredAt = now
            }
        }
    }

    /// Files a written morning brief under this morning's night: the one whose event span holds `at`, else
    /// the latest night with its deadline earlier the same local day (a brief often lands after the tail).
    func recordBrief(_ brief: SmartAlarmNight.Brief) {
        let cal = Calendar.current
        let day = Date(timeIntervalSince1970: TimeInterval(brief.at))
        let night = current(now: brief.at) ?? nights
            .filter { $0.deadline <= brief.at && cal.isDate(Date(timeIntervalSince1970: TimeInterval($0.deadline)),
                                                             inSameDayAs: day) }
            .max { $0.deadline < $1.deadline }
        guard let night else { return }
        update(deadline: night.deadline) { $0.briefs = ($0.briefs ?? []) + [brief] }
    }

    /// Fills the arm-readback verdict from the alarm path's own stored halves, only when they are attributable.
    func recordReadback(now: Int) {
        guard let n = current(now: now) ?? nights.first, let lastArm = n.arms.last else { return }
        let d = UserDefaults.standard
        guard let sent = d.object(forKey: "alarm.lastArmSentEpoch") as? Int, sent == lastArm.target,
              let reported = d.object(forKey: "alarm.lastReportedEpoch") as? Int else { return }
        let verdict = AlarmReadback.verdict(sentEpoch: sent, reportedEpoch: reported,
                                            sentDeviceId: d.string(forKey: "alarm.lastArmDeviceId"),
                                            reportedDeviceId: d.string(forKey: "alarm.lastReportedDeviceId"),
                                            sentAt: d.object(forKey: "alarm.lastArmAt") as? Double,
                                            reportedAt: d.object(forKey: "alarm.lastReportedAt") as? Double)
        update(deadline: n.deadline) { $0.readback = "\(verdict)" }
    }

    func clear() {
        nights = []
        save()
    }

    private func replace(_ night: SmartAlarmNight) {
        nights = SmartAlarmNight.pruned(nights.filter { $0.deadline != night.deadline } + [night], keep: Self.keepNights)
        save()
    }

    private func save() {
        guard let url else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(nights) else { return }
        // Readable while the phone is locked at night, like the store (`StorePaths`).
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
