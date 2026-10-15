import Foundation
import StrandAnalytics

/// The words for a smart-alarm night: the planner's morning line, the Test Centre list and timeline. Built
/// here, once, so the two screens cannot describe the same night differently. Each line says only what the
/// record shows: "woken" needs the strap's own fire report, otherwise it is "alarm moved to".
enum SmartAlarmNightText {

    static let checkInterval = SmartWakeWindow.checkInterval

    static func clock(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .omitted, time: .shortened)
    }

    static func day(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func minutes(_ m: Double) -> String {
        Duration.seconds(Int(m.rounded()) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded())) %" }

    static func mode(_ m: GoalWake.Mode) -> String {
        switch m {
        case .fixedTime: return String(localized: "At a fixed time")
        case .sleepNeed: return String(localized: "Sleep need reached")
        case .recovery: return String(localized: "Recovery reached")
        }
    }

    static func reason(_ r: GoalWake.Reason) -> String {
        switch r {
        case .sleepNeedReached: return String(localized: "sleep need reached")
        case .recoveryReached: return String(localized: "recovery reached")
        case .lightSleep: return String(localized: "light sleep")
        case .awake: return String(localized: "awake (live heart rate)")
        }
    }

    // MARK: Outcome

    /// "Woken at 06:41 – sleep need reached", or nil while the night is still running.
    static func outcome(_ n: SmartAlarmNight, now: Int) -> String? {
        switch n.outcome(now: now) {
        case .pending: return nil
        case .earlyWake(let at, let r):
            return n.strapFiredAt != nil
                ? String(localized: "Woken at \(clock(at)) – \(reason(r))")
                : String(localized: "Alarm moved to \(clock(at)) – \(reason(r))")
        case .deadlineGoalNotMet:
            return String(localized: "Window end \(clock(n.deadline)) – goal not reached")
        case .deadlineAppNotRunning:
            return String(localized: "Window end \(clock(n.deadline)) – the app wasn't running at night")
        case .deadlineFixed:
            return String(localized: "Fixed time \(clock(n.deadline))")
        }
    }

    /// The planner's line for this morning, when the last finished night woke today and had a window.
    static func morningLine(_ n: SmartAlarmNight?, now: Int) -> String? {
        guard let n, !n.plannedChecks.isEmpty,
              Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(n.deadline)),
                                      inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now))),
              let line = outcome(n, now: now) else { return nil }
        return String(localized: "Today: \(line)")
    }

    // MARK: Coverage

    enum Tone { case positive, warning, critical, neutral }

    static func coverage(_ c: SmartAlarmNight.Coverage) -> (icon: String, text: String, tone: Tone) {
        switch c {
        case .full: return ("checkmark.circle.fill", String(localized: "App was active and could decide"), .positive)
        case .partial: return ("exclamationmark.triangle.fill", String(localized: "App ran for part of the window"), .warning)
        case .none: return ("xmark.circle.fill", String(localized: "App didn't run in the window"), .critical)
        case .pending: return ("clock", String(localized: "Window not over yet"), .neutral)
        case .notApplicable: return ("alarm", String(localized: "Plain alarm, nothing to check"), .neutral)
        }
    }

    static func summary(_ nights: [SmartAlarmNight], now: Int) -> String? {
        let s = SmartAlarmNight.summary(nights, now: now, intervalS: checkInterval)
        guard s.total > 0 else { return nil }
        return String(localized: "In \(s.acted) of \(s.total) nights the app could act.")
    }

    // MARK: Timeline

    struct Entry: Identifiable {
        let id = UUID()
        let at: Int
        let title: String
        var detail: String? = nil
        var tone: Tone = .neutral
    }

    static func timeline(_ n: SmartAlarmNight, now: Int) -> [Entry] {
        var out: [Entry] = []
        for a in n.arms {
            out.append(Entry(at: a.at, title: String(localized: "Strap alarm armed for \(clock(a.target))"),
                             detail: a.connected ? nil : String(localized: "Not sent yet: no strap connection")))
        }
        if let r = n.readback {
            out.append(Entry(at: n.arms.last?.at ?? n.windowStart, title: readback(r)))
        }
        for e in n.events { out.append(Entry(at: e.at, title: event(e.kind))) }
        for slot in n.missedChecks(intervalS: checkInterval) where slot <= now {
            out.append(Entry(at: slot, title: String(localized: "Check missed – app not running"),
                             tone: .critical))
        }
        for c in n.checks { out.append(check(c)) }
        out += liveTimeline(n, now: now)
        if let e = n.earlyWake {
            out.append(Entry(at: e.decidedAt, title: String(localized: "Alarm moved to \(clock(e.wakeAt)) – \(reason(e.reason))"),
                             tone: .positive))
        }
        return out.sorted { $0.at < $1.at }
    }

    static func check(_ c: SmartAlarmNight.Check) -> Entry {
        var parts: [String] = [sync(c.sync)]
        parts.append(c.connected ? String(localized: "strap connected") : String(localized: "strap not connected"))
        if let age = c.hrAgeS { parts.append(String(localized: "newest heart rate \(minutes(Double(age) / 60)) old")) }
        else { parts.append(String(localized: "no heart rate tonight")) }
        if let a = c.asleepMin, let need = c.needMin {
            parts.append(String(localized: "asleep \(minutes(a)) of \(minutes(need))"))
        } else if let a = c.asleepMin {
            parts.append(String(localized: "asleep \(minutes(a))"))
        }
        if let r = c.recoveryEstimate { parts.append(String(localized: "recovery estimate \(percent(r))")) }
        parts.append(c.lightSleep != nil ? String(localized: "light sleep signal") : String(localized: "no light sleep signal"))
        if let s = c.liveState { parts.append(String(localized: "live heart rate: \(liveState(s))")) }
        let title = c.trigger == .stream
            ? String(localized: "Live check: \(decision(c.decision))")
            : String(localized: "Check: \(decision(c.decision))")
        return Entry(at: c.ranAt, title: title,
                     detail: parts.joined(separator: " · "),
                     tone: c.decision == "wake" ? .positive : .neutral)
    }

    static func decision(_ raw: String) -> String {
        if raw == "wake" { return String(localized: "wake now") }
        switch GoalWake.Hold(rawValue: raw) {
        case .beforeWindow: return String(localized: "window not open")
        case .deadlineClose: return String(localized: "deadline too close")
        case .conditionNotMet: return String(localized: "goal not reached")
        case .noData: return String(localized: "not enough data")
        case .waitingForLightSleep: return String(localized: "waiting for light sleep")
        case nil: return raw
        }
    }

    static func sync(_ s: SmartAlarmNight.SyncResult) -> String {
        switch s {
        case .completed: return String(localized: "sync finished")
        case .timedOut: return String(localized: "sync still running")
        case .failed: return String(localized: "sync ended without finishing")
        case .notStarted: return String(localized: "no sync started")
        case .noStrap: return String(localized: "no sync: strap not connected")
        case .notRequested: return String(localized: "no sync: live heart rate only")
        }
    }

    static func event(_ k: SmartAlarmNight.EventKind) -> String {
        switch k {
        case .foreground: return String(localized: "App opened")
        case .background: return String(localized: "App went to the background")
        case .backgroundLaunch: return String(localized: "iOS started the app in the background")
        case .bleRestore: return String(localized: "iOS woke the app for Bluetooth")
        case .syncCompleted: return String(localized: "Sync finished")
        case .strapAlarmFired: return String(localized: "Strap reported its alarm went off")
        case .deadlineRearmed: return String(localized: "No report from the strap: window end armed again")
        }
    }

    static func readback(_ raw: String) -> String {
        switch raw {
        case "matches": return String(localized: "Strap reports the same alarm time")
        case "mismatch": return String(localized: "Strap reports a different alarm time")
        default: return String(localized: "Strap's alarm time can't be compared")
        }
    }
}
