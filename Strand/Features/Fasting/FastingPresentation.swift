#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - View data for the Fasting screen
//
// Pure builders from engine output to what the views draw: every number is formatted here (through
// `MetricUnit` and `AppClock`), so the views hold no date math and no formatting.

enum FastingFormat {
    static var locale: Locale { AppClock.activeLocale }

    /// "16h" / "16 Std." — the one duration style on this screen.
    static func duration(_ seconds: TimeInterval) -> String {
        MetricUnit.duration.format(max(0, seconds), locale: locale)
    }

    /// Running clock "13:20:05". Positional, so it reads the same in both languages.
    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int64(max(0, seconds))).formatted(.time(pattern: .hourMinuteSecond))
    }

    /// Chart axis label: the duration style, except a bare "0" at the baseline ("0min" reads as noise).
    static func axisHours(_ hours: Double) -> String {
        hours <= 0 ? 0.formatted(.number.locale(locale)) : duration(hours * 3600)
    }

    static func time(_ date: Date) -> String { AppClock.hourMinute(date) }

    /// "Mon 14 Oct, 20:10" style: weekday + day for history rows and "last ended".
    static func dayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
            + ", " + time(date)
    }

    static func planName(_ plan: FastingPlan) -> LocalizedStringResource {
        if plan.id == FastingPlan.omad.id { return FastingStrings.omad }
        if plan.isCustom { return FastingStrings.customHours(Int(plan.fastingHours)) }
        return FastingStrings.ratio(fasting: Int(plan.fastingHours), eating: Int(plan.eatingHours))
    }
}

/// What the timer card shows at one instant.
enum FastingTimerState: Equatable {
    case idle(lastEnded: LocalizedStringResource?)
    case running(Running)

    struct Running: Equatable {
        let clock: String
        let progress: Double
        /// Ring clock marks: fraction of the goal and the hour label ("12h").
        let markers: [Marker]
        let phase: LocalizedStringResource
        let since: LocalizedStringResource
        let goal: LocalizedStringResource
        /// "of 16h" under the clock.
        let ofGoal: LocalizedStringResource
        /// "2h 40min to go" or "Goal reached".
        let status: LocalizedStringResource
        let goalReached: Bool
    }

    struct Marker: Equatable, Hashable {
        let fraction: Double
        let label: String
    }

    static func make(active: FastingInterval?, lastEnd: Date?, now: Date) -> FastingTimerState {
        guard let active else {
            return .idle(lastEnded: lastEnd.map { FastingStrings.lastEnded(FastingFormat.dayAndTime($0)) })
        }
        let s = FastingEngine.status(of: active, now: now)
        let markers = FastingEngine.markerFractions(goal: s.goal).map {
            Marker(fraction: $0.fraction, label: FastingFormat.duration($0.hours * 3600))
        }
        return .running(Running(
            clock: FastingFormat.clock(s.elapsed),
            progress: s.progress,
            markers: markers,
            phase: FastingStrings.phase(s.phase),
            since: FastingStrings.since(FastingFormat.time(active.start)),
            goal: FastingStrings.goalAt(FastingFormat.time(s.goalDate)),
            ofGoal: FastingStrings.ofGoal(FastingFormat.duration(s.goal)),
            status: s.goalReached ? FastingStrings.goalReached
                : FastingStrings.remaining(FastingFormat.duration(s.remaining)),
            goalReached: s.goalReached))
    }
}

/// The plan card: name, split and (when there is an anchor) today's eating window.
struct FastingPlanSummary: Equatable {
    let name: LocalizedStringResource
    let split: LocalizedStringResource
    let window: LocalizedStringResource?

    /// The eating window opens when the running fast reaches its goal, or when the last fast ended.
    static func make(plan: FastingPlan, active: FastingInterval?, lastEnd: Date?, now: Date) -> FastingPlanSummary {
        let opens = active.map { $0.start.addingTimeInterval($0.goal) } ?? lastEnd
        let closes = opens?.addingTimeInterval(plan.eatingHours * 3600)
        var window: LocalizedStringResource?
        if let opens, let closes, closes > now, plan.eatingHours > 0 {
            window = FastingStrings.eatingWindow(FastingFormat.time(opens), FastingFormat.time(closes))
        }
        return FastingPlanSummary(name: FastingFormat.planName(plan),
                                  split: FastingStrings.split(fasting: Int(plan.fastingHours),
                                                              eating: Int(plan.eatingHours)),
                                  window: window)
    }
}

struct FastingWeekBar: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let hours: Double
    let met: Bool
}

struct FastingWeek: Equatable {
    let bars: [FastingWeekBar]
    let goalHours: Double
    let takeaway: LocalizedStringResource
    let isEmpty: Bool

    static func make(_ days: [FastingDay], plan: FastingPlan) -> FastingWeek {
        let bars = days.map { FastingWeekBar(day: $0.dayStart, hours: $0.fasted / 3600, met: $0.met) }
        let logged = days.filter { $0.goal != nil }
        return FastingWeek(bars: bars, goalHours: plan.fastingHours,
                           takeaway: logged.isEmpty ? FastingStrings.weekEmpty
                               : FastingStrings.weekTakeaway(met: days.filter(\.met).count, days: days.count),
                           isEmpty: logged.isEmpty)
    }
}

struct FastingHistoryItem: Identifiable, Equatable {
    var id: String { row.id }
    let row: FastingSessionRow
    let when: String
    let duration: String
    let goalMet: Bool
    let goal: LocalizedStringResource

    static func make(_ row: FastingSessionRow) -> FastingHistoryItem? {
        let interval = FastingInterval(row)
        guard let end = interval.end else { return nil }
        return FastingHistoryItem(row: row, when: FastingFormat.dayAndTime(end),
                                  duration: FastingFormat.duration(end.timeIntervalSince(interval.start)),
                                  goalMet: interval.metGoal,
                                  goal: FastingStrings.historyGoal(FastingFormat.duration(interval.goal)))
    }
}

/// The patterns card: either one "not enough data" line, or one row per overnight outcome.
enum FastingPatterns: Equatable {
    case notEnough(LocalizedStringResource)
    case rows([Row])

    struct Row: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let label: LocalizedStringResource
        let result: LocalizedStringResource
        let sample: LocalizedStringResource
    }

    struct Outcome {
        let key: String
        let label: LocalizedStringResource
        let unit: MetricUnit
        let byDay: [String: Double]
    }

    static func make(split: FastingNightSplit, outcomes: [Outcome]) -> FastingPatterns {
        var rows: [Row] = []
        // When every outcome is short, report the one with the most nights: it is the closest to an answer.
        var closest: (fasting: Int, other: Int, needed: Int)?
        for o in outcomes {
            switch FastingEngine.compare(split: split, outcomeByDay: o.byDay, outcome: o.key) {
            case .notEnoughData(let f, let other, let needed):
                if (closest.map { $0.fasting + $0.other } ?? -1) < f + other { closest = (f, other, needed) }
            case .noClearDifference(let e):
                rows.append(Row(key: o.key, label: o.label, result: FastingStrings.noClearDifference,
                                sample: FastingStrings.sample(fasting: e.nWith, other: e.nWithout)))
            case .difference(let e):
                let delta = o.unit.formatDelta(e.delta, locale: FastingFormat.locale)
                rows.append(Row(key: o.key, label: o.label, result: FastingStrings.onFastingNights(delta),
                                sample: FastingStrings.sample(fasting: e.nWith, other: e.nWithout)))
            }
        }
        if rows.isEmpty {
            let s = closest ?? (0, 0, BehaviorInsights.minGroupForSignificance)
            return .notEnough(FastingStrings.notEnough(fasting: s.fasting, other: s.other, needed: s.needed))
        }
        return .rows(rows)
    }
}
#endif
