#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - View data for the Fasting screen
//
// Pure builders from engine output to what the views draw: every number is formatted here (through
// `MetricUnit` and `AppClock`), so the views hold no date math and no formatting. The timer, Today and
// week builders live in FastingCyclePresentation.

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

    /// "Mon 14 Oct, 20:10 – 12:00", with the end's day only when it differs.
    static func range(_ start: Date, _ end: Date) -> String {
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return dayAndTime(start) + " – " + (sameDay ? time(end) : dayAndTime(end))
    }

    /// "20:00" for minutes after midnight, in the user's clock style.
    static func minuteOfDay(_ minute: Int) -> String {
        let day = Calendar.current.startOfDay(for: Date())
        return time(Calendar.current.date(byAdding: .minute, value: minute, to: day) ?? day)
    }

    static func planName(_ plan: FastingPlan) -> LocalizedStringResource {
        if plan.id == FastingPlan.omad.id { return FastingStrings.omad }
        if plan.isCustom { return FastingStrings.customHours(Int(plan.fastingHours)) }
        return FastingStrings.ratio(fasting: Int(plan.fastingHours), eating: Int(plan.eatingHours))
    }
}

/// The schedule card: plan name, split and when fasts start.
struct FastingScheduleSummary: Equatable {
    let name: LocalizedStringResource
    let split: LocalizedStringResource
    let timing: LocalizedStringResource

    static func make(_ schedule: FastingSchedule) -> FastingScheduleSummary {
        let plan = schedule.plan
        let timing: LocalizedStringResource
        switch schedule.mode {
        case .flexible: timing = FastingStrings.flexibleTiming
        case .fixed(let minute): timing = FastingStrings.fixedTiming(FastingFormat.minuteOfDay(minute))
        }
        return FastingScheduleSummary(name: FastingFormat.planName(plan),
                                      split: FastingStrings.split(fasting: Int(plan.fastingHours),
                                                                  eating: Int(plan.eatingHours)),
                                      timing: timing)
    }
}

/// One history row: a finished fast or a logged eating window between two fasts.
struct FastingHistoryItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case fast(FastingSessionRow)
        case window(previous: FastingSessionRow, next: FastingSessionRow)
    }

    let id: String
    let kind: Kind
    let sortDate: Date
    let title: LocalizedStringResource
    let duration: String
    let when: String
    /// "Goal reached" / "Goal 16h" for fasts, nil for windows.
    let goal: LocalizedStringResource?
    let goalMet: Bool

    var isWindow: Bool { if case .window = kind { return true } else { return false } }

    /// Fasts and the windows between them, newest first.
    static func make(rows: [FastingSessionRow], limit: Int) -> [FastingHistoryItem] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fasts: [FastingHistoryItem] = rows.compactMap { row in
            let i = FastingInterval(row)
            guard let end = i.end else { return nil }
            return FastingHistoryItem(
                id: row.id, kind: .fast(row), sortDate: end, title: FastingStrings.historyFast,
                duration: FastingFormat.duration(end.timeIntervalSince(i.start)),
                when: FastingFormat.range(i.start, end),
                goal: i.metGoal ? FastingStrings.goalReached : FastingStrings.historyGoal(FastingFormat.duration(i.goal)),
                goalMet: i.metGoal)
        }
        let windows: [FastingHistoryItem] = FastingCycle.eatingWindows(rows.map(FastingInterval.init)).compactMap { w in
            guard let p = byID[w.previousID], let n = byID[w.nextID] else { return nil }
            return FastingHistoryItem(
                id: w.id, kind: .window(previous: p, next: n), sortDate: w.closes, title: FastingStrings.historyWindow,
                duration: FastingFormat.duration(w.length), when: FastingFormat.range(w.opens, w.closes),
                goal: nil, goalMet: false)
        }
        return Array((fasts + windows).sorted { $0.sortDate > $1.sortDate }.prefix(limit))
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
