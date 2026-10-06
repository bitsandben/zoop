import Foundation
import WhoopProtocol

// AlarmAnchoredWake.swift — experimental: end a night at the moment the user got up after the strap alarm.
//
// The strap logs when its alarm fired (STRAP_DRIVEN_ALARM_EXECUTED). It does not log when the alarm was
// dismissed, so the fire time alone says the user was woken, not that they got up. Getting up shows as a
// sustained heart-rate rise over the minutes just before the alarm. When both are present near the end of
// a detected night, the night ends at the start of that rise and everything from the alarm on is wake.
//
// Conservative by construction: without an alarm near the detected end, without enough heart rate before
// it, or without a sustained rise inside the search window, the session passes through unchanged. It only
// moves the END of a session; the start, resting HR and HRV are carried over. Default off
// (`PuffinExperiment.alarmAnchoredWakeEnabled`), unvalidated on hardware.

public enum AlarmAnchoredWake {

    /// The alarm must fire at least this long after the session started (not a nap or a mid-night test).
    static let minSleepBeforeAlarm = 3 * 3600
    /// How far before the detected end an alarm may fire and still anchor it (the detector can run long).
    static let alarmBeforeEnd = 90 * 60
    /// How far after the detected end an alarm may fire (the detector can end early on a quiet lie-in).
    static let alarmAfterEnd = 60 * 60
    /// Heart rate before the alarm that forms the sleeping baseline.
    static let baselineWindow = 15 * 60
    static let minBaselineSamples = 10
    /// How long after the alarm a rise is looked for.
    static let riseSearchWindow = 45 * 60
    /// The rise: per-minute mean at least this far over the baseline median…
    static let riseBpm = 10
    /// …for this many consecutive minutes.
    static let riseMinutes = 3

    /// The alarm that anchors `session`: the last fire inside the eligible window, or nil.
    static func anchoringAlarm(_ session: SleepSession, alarmFires: [Int]) -> Int? {
        alarmFires
            .filter { $0 >= session.start + minSleepBeforeAlarm
                && $0 >= session.end - alarmBeforeEnd
                && $0 <= session.end + alarmAfterEnd }
            .max()
    }

    /// Start of the first run of `riseMinutes` minutes, each with a mean `riseBpm` over the baseline,
    /// within `riseSearchWindow` after `alarm`. nil when the baseline is too thin or no rise holds.
    static func getUpTime(alarm: Int, hr: [HRSample]) -> Int? {
        let before = hr.filter { $0.ts >= alarm - baselineWindow && $0.ts < alarm }.map(\.bpm).sorted()
        guard before.count >= minBaselineSamples else { return nil }
        let baseline = before[before.count / 2]

        var sums: [Int: (Int, Int)] = [:]   // minute index after the alarm → (sum, count)
        for s in hr where s.ts >= alarm && s.ts < alarm + riseSearchWindow {
            let m = (s.ts - alarm) / 60
            let cur = sums[m] ?? (0, 0)
            sums[m] = (cur.0 + s.bpm, cur.1 + 1)
        }
        func raised(_ m: Int) -> Bool {
            guard let (sum, count) = sums[m], count > 0 else { return false }
            return sum >= (baseline + riseBpm) * count
        }
        let minutes = riseSearchWindow / 60
        var m = 0
        while m + riseMinutes <= minutes {
            if (m..<(m + riseMinutes)).allSatisfy(raised) { return alarm + m * 60 }
            m += 1
        }
        return nil
    }

    /// The session ended at the get-up time, with every stage from the alarm on marked wake.
    public static func refine(_ session: SleepSession, alarmFires: [Int], hr: [HRSample]) -> SleepSession {
        guard let alarm = anchoringAlarm(session, alarmFires: alarmFires),
              let getUp = getUpTime(alarm: alarm, hr: hr),
              getUp > session.start else { return session }
        let newEnd = getUp
        let cut = min(alarm, newEnd)
        var stages: [StageSegment] = session.stages.compactMap { seg in
            let end = min(seg.end, cut)
            return end > seg.start ? StageSegment(start: seg.start, end: end, stage: seg.stage) : nil
        }
        let tailStart = stages.last?.end ?? session.start
        if newEnd > tailStart {
            if let last = stages.last, last.stage == "wake", last.end == tailStart {
                stages[stages.count - 1] = StageSegment(start: last.start, end: newEnd, stage: "wake")
            } else {
                stages.append(StageSegment(start: tailStart, end: newEnd, stage: "wake"))
            }
        }
        guard newEnd != session.end || stages != session.stages else { return session }
        return SleepSession(start: session.start, end: newEnd,
                            efficiency: SleepStager.efficiency(start: session.start, end: newEnd, stages: stages),
                            stages: stages, restingHR: session.restingHR, avgHRV: session.avgHRV,
                            hrOnly: session.hrOnly)
    }

    /// `enabled = false` is an unchanged passthrough.
    public static func apply(_ session: SleepSession, alarmFires: [Int], hr: [HRSample],
                             enabled: Bool) -> SleepSession {
        enabled ? refine(session, alarmFires: alarmFires, hr: hr) : session
    }

    /// Fire times of the strap's own alarm among stored strap events.
    public static func alarmFires(_ events: [WhoopEvent]) -> [Int] {
        events.filter { $0.kind.hasPrefix("STRAP_DRIVEN_ALARM_EXECUTED") }.map(\.ts)
    }
}
