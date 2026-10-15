import Foundation

// CoachMorningRules+Rules.swift - the individual morning rules, one slot each.
//
// Slots and their priorities (higher first, `evaluate` keeps the top three):
//   training  illness 100 · low recovery / poor night 80-90 · trend caution 75 · deload 70 ·
//             routine nudge 60 · go / push 50-55
//   fasting   a long fast on a low day 85
//   sleep     sleep debt 70 · short night 65 · irregular bedtime 45
//   stress    usual peak 45 · high yesterday 40
//   habit     one low HRV morning 35

extension CoachMorningRules {

    typealias C = Candidate

    // MARK: Training (one decision per day)

    static func trainingCandidate(_ i: Input, _ readiness: Readiness) -> Candidate? {
        let band = i.strainTarget.map { CoachSuggestion.Action.strainTarget(low: $0.lowerBound, high: $0.upperBound) }
            ?? .none
        let rec = recoveryEvidence(i)
        let night = poorNightEvidence(i)
        let caution = cautionEvidence(i)
        let loadHigh = i.loadState == .high
        let load = loadEvidence(i)
        let missed = i.adherence.flatMap { $0.missed >= missedWorthNudge ? $0 : nil }
        let missedEv = missed.map { [Evidence.missedRoutine(missed: $0.missed, planned: $0.planned)] } ?? []
        let planned = i.plannedRoutines.first
        let plannedEv = planned.map { [Evidence.planned(name: $0.name)] } ?? []

        if i.illness { return C(kind: .recovery, reason: .illnessRest, action: band, evidence: [.illness] + rec, priority: 100) }

        switch readiness {
        case .unknown:
            guard !night.isEmpty else { return nil }
            return C(kind: .recovery, reason: .poorSleepEasy, action: band, evidence: night, priority: 85)
        case .low:
            if planned != nil {
                return C(kind: .trainingToday, reason: .plannedRoutineEaseOff, action: band, evidence: rec + plannedEv, priority: 90)
            }
            if !night.isEmpty {
                return C(kind: .recovery, reason: .poorSleepEasy, action: band, evidence: night + rec, priority: 90)
            }
            return C(kind: .recovery, reason: .lowRecoveryRest, action: band, evidence: rec, priority: 90)
        case .medium:
            if planned != nil {
                let why = night + caution + (loadHigh ? load : [])
                if !why.isEmpty {
                    return C(kind: .trainingToday, reason: .plannedRoutineEaseOff, action: band,
                             evidence: Array(why.prefix(1)) + plannedEv, priority: 80)
                }
                if !missedEv.isEmpty {
                    return C(kind: .routine, reason: .routineBackOnTrack, action: band, evidence: missedEv + rec, priority: 60)
                }
                return C(kind: .trainingToday, reason: .plannedRoutineGo, action: band, evidence: rec + plannedEv, priority: 55)
            }
            if !night.isEmpty {
                return C(kind: .recovery, reason: .poorSleepEasy, action: band, evidence: night + rec, priority: 80)
            }
            if !caution.isEmpty {
                return C(kind: .trainingToday, reason: .hrvTrendCaution, action: band, evidence: caution + rec, priority: 75)
            }
            if loadHigh {
                return C(kind: .trainingToday, reason: .loadDeload, action: band, evidence: load + rec, priority: 70)
            }
            if let r = missedRoutine(i) {
                return C(kind: .routine, reason: .routineMissed, action: .routine(programId: r.id, name: r.name),
                         evidence: missedEv + rec, priority: 60)
            }
            return C(kind: .trainingToday, reason: .moderateSession, action: band, evidence: rec, priority: 50)
        case .high:
            if !caution.isEmpty {
                return C(kind: .trainingToday, reason: .hrvTrendCaution, action: band, evidence: caution + rec, priority: 75)
            }
            if loadHigh {
                return C(kind: .trainingToday, reason: .loadDeload, action: band, evidence: load + rec, priority: 70)
            }
            if planned != nil {
                if !missedEv.isEmpty {
                    return C(kind: .routine, reason: .routineBackOnTrack, action: band, evidence: missedEv + rec, priority: 60)
                }
                return C(kind: .trainingToday, reason: .plannedRoutineGo, action: band, evidence: rec + plannedEv, priority: 55)
            }
            if let r = missedRoutine(i) {
                return C(kind: .routine, reason: .routineMissed, action: .routine(programId: r.id, name: r.name),
                         evidence: missedEv + rec, priority: 60)
            }
            let green = greenTrendEvidence(i)
            if !green.isEmpty {
                return C(kind: .trainingToday, reason: .trendGreenLight, action: band, evidence: green + rec, priority: 55)
            }
            if let next = i.availableRoutines.first {
                return C(kind: .routine, reason: .greenRoutine, action: .routine(programId: next.id, name: next.name),
                         evidence: rec, priority: 55)
            }
            return C(kind: .trainingToday, reason: .greenPush, action: band,
                     evidence: rec + (i.loadState == .low ? load : []), priority: 55)
        }
    }

    // MARK: Tonight

    /// An earlier or steadier night, only when the planner (or the best-bedtime window) knows a time.
    /// The planner's time is already `TonightBedtime`'s; `reasonableBedtime` with the same usual bedtime
    /// leaves it unchanged and only clamps a raw time (tests, the best-bedtime fallback).
    static func sleepCandidate(_ i: Input) -> Candidate? {
        guard let raw = i.bedtimeMinute ?? i.bestBedtimeMinute else { return nil }
        let bed = reasonableBedtime(raw, usual: i.usualBedtimeMinute ?? i.bestBedtimeMinute)
        let action = CoachSuggestion.Action.bedtime(minuteOfDay: bed)
        if i.sleepDebtMin >= debtWorthActing {
            return C(kind: .sleepTiming, reason: .sleepDebtBedtime, action: action,
                     evidence: [.sleepDebt(minutes: Int(i.sleepDebtMin.rounded()))], priority: 70)
        }
        if let s = i.sleepMin, s > 0, s < shortNightMin {
            return C(kind: .sleepTiming, reason: .shortNightBedtime, action: action,
                     evidence: [.sleep(minutes: Int(s.rounded()))], priority: 65)
        }
        if let last = i.lastBedtimeMinute, clockDistance(last, bed) >= bedtimeDriftMin {
            return C(kind: .sleepTiming, reason: .bedtimeRegularity, action: action,
                     evidence: [.bedtimeDrift(lastMinute: minuteOfDay(last), usualMinute: bed)], priority: 45)
        }
        return nil
    }

    // MARK: Stress and habits

    /// A breather a quarter of an hour before the hour stress usually peaks; without a known peak, a
    /// plain word after a stressful yesterday.
    static func stressCandidate(_ i: Input) -> Candidate? {
        let level = i.stressLevel ?? 0
        let highYesterday = level >= highStress
        if let hour = i.stressPeakHour, highYesterday || (i.stressPeakLevel ?? 0) >= peakWorthBreathing {
            let evidence: [Evidence] = [.stressPeak(hour: hour)] + (highYesterday ? [.stressYesterday(level: level)] : [])
            return C(kind: .habit, reason: .stressPeakBreathe, action: .breathe(minuteOfDay: minuteOfDay(hour * 60 - 15)),
                     evidence: evidence, priority: 45)
        }
        if highYesterday {
            return C(kind: .habit, reason: .highStress, action: .none, evidence: [.stressYesterday(level: level)], priority: 40)
        }
        return nil
    }

    /// One low HRV morning, when the training slot has not already acted on it.
    static func hrvCandidate(_ i: Input, _ readiness: Readiness) -> Candidate? {
        guard readiness != .low, !i.illness, cautionEvidence(i).isEmpty,
              let h = i.hrv, let base = i.hrvBaseline, base > 0, h < hrvLowRatio * base else { return nil }
        return C(kind: .habit, reason: .hrvBelowRange, action: .none,
                 evidence: [.hrvToday(ms: Int(h.rounded()), typicalMs: Int(base.rounded()))], priority: 35)
    }

    // MARK: Fasting

    /// Only while a long fast is running AND the body asks for care: no generic fasting reminders.
    static func fastingCandidate(_ i: Input, _ readiness: Readiness) -> Candidate? {
        guard let f = i.fasting, max(f.elapsedHours, f.targetHours) >= longFastHours,
              readiness == .low || i.illness else { return nil }
        return C(kind: .fasting, reason: .fastingBreak, action: .none,
                 evidence: [.fasting(hours: Int(f.elapsedHours.rounded(.down)))] + recoveryEvidence(i), priority: 85)
    }

    // MARK: Evidence

    static func poorNightEvidence(_ i: Input) -> [Evidence] {
        if let s = i.sleepMin, s > 0, s < shortNightMin { return [.sleep(minutes: Int(s.rounded()))] }
        if i.sleepDebtMin >= heavyDebtMin { return [.sleepDebt(minutes: Int(i.sleepDebtMin.rounded()))] }
        return []
    }

    /// HRV below its normal, or resting HR above it, for several mornings in a row.
    static func cautionEvidence(_ i: Input) -> [Evidence] {
        var out: [Evidence] = []
        if let t = i.hrvTrend, t.below, t.streakDays >= trendStreak {
            out.append(.hrvTrend(days: t.streakDays, deltaPercent: Int(t.deltaPercent.rounded())))
        }
        if let t = i.rhrTrend, !t.below, t.streakDays >= trendStreak {
            out.append(.rhrTrend(days: t.streakDays, deltaPercent: Int(t.deltaPercent.rounded())))
        }
        return out
    }

    /// HRV above its normal, or resting HR below it, for several mornings in a row.
    static func greenTrendEvidence(_ i: Input) -> [Evidence] {
        if let t = i.hrvTrend, !t.below, t.streakDays >= trendStreak {
            return [.hrvTrend(days: t.streakDays, deltaPercent: Int(t.deltaPercent.rounded()))]
        }
        if let t = i.rhrTrend, t.below, t.streakDays >= trendStreak {
            return [.rhrTrend(days: t.streakDays, deltaPercent: Int(t.deltaPercent.rounded()))]
        }
        return []
    }

    static func loadEvidence(_ i: Input) -> [Evidence] {
        guard let r = i.loadRatio, r.isFinite, r > 0 else { return [] }
        return [.load(percentOfNormal: Int((r * 100).rounded()))]
    }

    /// The most recently skipped program, when the user can still run it today.
    static func missedRoutine(_ i: Input) -> Routine? {
        guard let a = i.adherence, a.missed >= missedWorthNudge, let id = a.missedProgramId else { return nil }
        return i.availableRoutines.first { $0.id == id }
    }
}
