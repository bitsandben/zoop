import Foundation
import Combine
import StrandAnalytics
#if os(iOS)
import UIKit
#endif

/// Experimental smart alarm with a wake window: a fixed time that may wake earlier in light sleep, or a goal
/// (sleep need reached, recovery estimate reached). The strap alarm is armed at the window END all night, the
/// hard deadline, so if the app is suspended or nothing is met it rings as a plain alarm. Inside the window the
/// app checks every few minutes (sync, then `GoalWake.decide`); on a wake it re-arms the same strap alarm to
/// 30 s from now, only earlier and once per night. Every check and what the app could see is written to
/// `SmartAlarmNightLog`. No new strap command: only `armStrapAlarm(at:)`, the existing sync request, and the Live
/// screen's realtime-HR stream held around the window (`SmartWakeLiveStream`), whose samples also drive checks.
@MainActor
final class SmartWakeWindow {
    nonisolated static let windowKey = "zoop.smartWake.windowMinutes"
    nonisolated static let choices = [0, 15, 20, 30, 45, 60]

    /// Stored window length in minutes; 0 = off for a fixed time (`GoalWakeSettings.windowMinutes` is the one in effect).
    nonisolated static var windowMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: windowKey)
        return choices.contains(v) ? v : 0
    }

    /// Check interval, and the longest a check waits for its sync before reading.
    nonisolated static let checkInterval = 3 * 60
    static let syncSettle: TimeInterval = 75
    /// After an early wake, re-arm the deadline this long past it unless the strap reported firing.
    static let deadlineGuardS = 90

    private weak var model: AppModel?
    private let log: SmartAlarmNightLog
    private var timer: Timer?
    private var guardTimer: Timer?
    private var deadline: Int?
    private var running = false
    private var lastRunAt = 0
    /// The last full check's reading, reused by the live evaluations between checks.
    private var lastReading: (deadline: Int, at: Int, reading: SmartWakeProbe.Reading)?
    private var cancellables = Set<AnyCancellable>()
    let liveStream: SmartWakeLiveStream

    init(model: AppModel, log: SmartAlarmNightLog = .shared) {
        self.model = model
        self.log = log
        liveStream = SmartWakeLiveStream(model: model, log: log)
        liveStream.activeNight = { [weak self] in self?.activeNight }
        liveStream.onEvaluate = { [weak self] in self?.streamTick() }
        model.live.$lastSyncedAt.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                self?.log.recordEvent(.syncCompleted)
                self?.scheduleNextCheck()
            }
        }.store(in: &cancellables)
    }

    // MARK: Arming

    /// What to arm for the plain next alarm `planned`: the early wake when one is chosen and still due, the
    /// following alarm once the strap reported this morning's alarm fired, else `planned` itself.
    /// `nextAfter` resolves the alarm after a given date (the same pure resolver the app arms from).
    func resolve(planned: Date, now: Date = Date(), nextAfter: (Date) -> Date?) -> (arm: Date, deadline: Date)? {
        let key = Int(planned.timeIntervalSince1970)
        guard let night = log.night(deadline: key) else { return (planned, planned) }
        if night.strapFiredAt != nil {
            guard let next = nextAfter(planned.addingTimeInterval(60)) else { return nil }
            return (next, next)
        }
        if let e = night.earlyWake, TimeInterval(e.wakeAt) > now.timeIntervalSince1970 - 60 {
            return (Date(timeIntervalSince1970: TimeInterval(e.wakeAt)), planned)
        }
        return (planned, planned)
    }

    /// Called by `applySmartAlarm` after each arm: logs it and follows the deadline (nil = no alarm).
    func didArm(_ arm: Date?, deadline next: Date?) {
        guard let next else {
            deadline = nil
            timer?.invalidate(); timer = nil
            liveStream.reconcile()
            return
        }
        let dl = Int(next.timeIntervalSince1970)
        let now = Int(Date().timeIntervalSince1970)
        deadline = dl
        // One record per night, set up from the evening on (an alarm days away has no night yet).
        guard dl - now < 24 * 3600, let model else { return }
        let window = GoalWake.Window(deadline: dl, minutes: GoalWakeSettings.windowMinutes)
        let days = SmartWakeProbe.days(model.repo.days, beforeWake: dl)
        log.begin(deadline: dl, window: window, settings: GoalWakeSettings.settings,
                  needMin: days.isEmpty ? nil : SmartWakeProbe.sleepTargetMin(days: days),
                  plannedChecks: GoalWake.plannedChecks(window: window, intervalS: Self.checkInterval), now: now)
        if let arm {
            let target = Int(arm.timeIntervalSince1970)
            log.recordArm(deadline: dl, target: target, connected: Self.armWentOut(target), now: now)
        }
        log.recordReadback(now: now)
        scheduleNextCheck()
    }

    /// True only when the alarm path recorded THIS arm as sent over a ready channel (a 5/MG without its
    /// experimental switch, or a dropped strap, leaves the record of an older arm or a queued one).
    static func armWentOut(_ target: Int) -> Bool {
        let d = UserDefaults.standard
        return (d.object(forKey: "alarm.lastArmSentEpoch") as? Int) == target && d.bool(forKey: "alarm.lastArmConnected")
    }

    // MARK: Checks

    private var activeNight: SmartAlarmNight? { deadline.flatMap { log.night(deadline: $0) } }

    /// Schedules the next check: the next planned slot, or now when the app wakes inside the window and no
    /// check ran for a full interval (a late wake still gets to decide).
    func scheduleNextCheck() {
        liveStream.reconcile()
        timer?.invalidate(); timer = nil
        guard !running, let night = activeNight, night.earlyWake == nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        let window = GoalWake.Window(start: night.windowStart, end: night.deadline)
        guard !night.plannedChecks.isEmpty, GoalWake.wakeTime(now: max(now, window.start), window: window) != nil
        else { return }
        let fireAt: Int
        let trigger: SmartAlarmNight.Trigger
        if now >= window.start, now - lastRunAt >= Self.checkInterval {
            fireAt = now + 1
            trigger = .appWake
        } else if now >= window.start {
            fireAt = night.plannedChecks.first { $0 > now } ?? lastRunAt + Self.checkInterval
            trigger = .timer
        } else {
            fireAt = window.start
            trigger = .timer
        }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, fireAt - now)), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.runCheck(trigger: trigger) }
        }
    }

    /// A live sample arrived inside the window (at most once a minute): the samples are what iOS woke the app
    /// for, so they drive the checks while timers cannot fire. A full check when one is due, else a quick
    /// evaluation of the live read against the last check's synced data.
    private func streamTick() {
        guard !running, let night = activeNight, night.earlyWake == nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        let window = GoalWake.Window(start: night.windowStart, end: night.deadline)
        guard now >= window.start, GoalWake.wakeTime(now: now, window: window) != nil else { return }
        guard now - lastRunAt < Self.checkInterval, let last = lastReading, last.deadline == night.deadline else {
            timer?.invalidate(); timer = nil
            Task { await runCheck(trigger: .stream) }
            return
        }
        liveEvaluate(night: night, window: window, last: last, now: now)
    }

    private func liveEvaluate(night: SmartAlarmNight, window: GoalWake.Window,
                              last: (deadline: Int, at: Int, reading: SmartWakeProbe.Reading), now: Int) {
        guard let model else { return }
        let r = last.reading
        let liveRead = liveStream.read(now: now, sleepingBpm: r.sleepingBpm, moving: r.signal == .moving)
        var inputs = r.inputs
        inputs.now = now
        inputs.live = liveRead.state
        let decision = GoalWake.decide(window: window, settings: night.settings, inputs: inputs)
        liveStream.didEvaluate(at: now)
        let hrAge = liveStream.newestSampleAt.map { now - $0 }
        log.update(deadline: night.deadline) {
            $0.checks.append(.init(ranAt: now, evaluatedAt: now, connected: model.live.connected, sync: .notRequested,
                                   hrAgeS: hrAge,
                                   gravityAgeS: r.gravityAgeS.map { $0 + now - last.at },
                                   asleepMin: inputs.asleepMin, needMin: inputs.needMin,
                                   recoveryEstimate: r.estimate?.score, lightSleep: r.signal?.rawValue,
                                   decision: Self.label(decision), trigger: .stream,
                                   liveState: liveRead.state?.rawValue))
        }
        if case .wake(let at, let reason) = decision {
            let task = BackgroundTime.begin()
            wake(at: at, reason: reason, night: night, decidedAt: now)
            task.end()
        }
    }

    static func label(_ d: GoalWake.Decision) -> String {
        switch d {
        case .hold(let h): return h.rawValue
        case .wake: return "wake"
        }
    }

    private func runCheck(trigger: SmartAlarmNight.Trigger) async {
        guard !running, let model, let night = activeNight, night.earlyWake == nil else { return }
        let ranAt = Int(Date().timeIntervalSince1970)
        let window = GoalWake.Window(start: night.windowStart, end: night.deadline)
        guard ranAt >= window.start - 60, GoalWake.wakeTime(now: max(ranAt, window.start), window: window) != nil
        else { return }
        running = true
        lastRunAt = ranAt
        log.recordReadback(now: ranAt)
        let task = BackgroundTime.begin()
        defer { task.end(); running = false }

        let connected = model.live.connected
        let sync = await SmartWakeProbe.sync(model: model, settle: Self.syncSettle)
        let reading = await SmartWakeProbe.read(model: model, now: Int(Date().timeIntervalSince1970),
                                                deadline: night.deadline, needMin: night.needMin)
        var inputs = reading.inputs
        inputs.now = Int(Date().timeIntervalSince1970)
        let liveRead = liveStream.read(now: inputs.now, sleepingBpm: reading.sleepingBpm,
                                       moving: reading.signal == .moving)
        inputs.live = liveRead.state
        lastReading = (night.deadline, inputs.now, reading)
        liveStream.didEvaluate(at: inputs.now)
        let decision = GoalWake.decide(window: window, settings: night.settings, inputs: inputs)
        let label = Self.label(decision)
        log.update(deadline: night.deadline) {
            $0.checks.append(.init(ranAt: ranAt, evaluatedAt: inputs.now, connected: connected, sync: sync,
                                   hrAgeS: reading.hrAgeS, gravityAgeS: reading.gravityAgeS,
                                   asleepMin: inputs.asleepMin, needMin: inputs.needMin,
                                   recoveryEstimate: reading.estimate?.score,
                                   lightSleep: reading.signal?.rawValue, decision: label,
                                   trigger: trigger, liveState: liveRead.state?.rawValue))
        }
        model.live.append(log: AppModel.stamped("Smart alarm check: \(label), sync \(sync.rawValue)"))
        if case .wake(let at, let reason) = decision {
            wake(at: at, reason: reason, night: night, decidedAt: inputs.now)
        } else {
            running = false
            scheduleNextCheck()
        }
    }

    private func wake(at: Int, reason: GoalWake.Reason, night: SmartAlarmNight, decidedAt: Int) {
        guard let model else { return }
        log.update(deadline: night.deadline) { $0.earlyWake = .init(decidedAt: decidedAt, wakeAt: at, reason: reason) }
        model.live.append(log: AppModel.stamped("Smart alarm: \(reason.rawValue), strap alarm moved to now"))
        model.ble.armStrapAlarm(at: Date(timeIntervalSince1970: TimeInterval(at)))
        log.recordArm(deadline: night.deadline, target: at, connected: Self.armWentOut(at), now: decidedAt)
        // The strap holds one alarm instant, so the early wake replaced the deadline. Unless the strap reports
        // firing, put the deadline back once the early wake is past.
        guardTimer?.invalidate()
        let delay = TimeInterval(at + Self.deadlineGuardS) - Date().timeIntervalSince1970
        guardTimer = Timer.scheduledTimer(withTimeInterval: max(1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restoreDeadlineIfUnconfirmed(night.deadline) }
        }
        liveStream.reconcile()
    }

    private func restoreDeadlineIfUnconfirmed(_ deadline: Int) {
        guard let night = log.night(deadline: deadline), night.strapFiredAt == nil,
              TimeInterval(deadline) > Date().timeIntervalSince1970 else { return }
        log.recordEvent(.deadlineRearmed)
        model?.applySmartAlarm()
    }
}

/// A short stretch of background execution for one check (iOS gives about 30 s); a no-op elsewhere.
@MainActor
final class BackgroundTime {
    #if os(iOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #endif

    static func begin() -> BackgroundTime {
        let t = BackgroundTime()
        #if os(iOS)
        t.id = UIApplication.shared.beginBackgroundTask(withName: "smart-alarm-check") { [weak t] in
            MainActor.assumeIsolated { t?.end() }   // the expiry handler runs on main and must end synchronously
        }
        #endif
        return t
    }

    func end() {
        #if os(iOS)
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        #endif
    }
}
