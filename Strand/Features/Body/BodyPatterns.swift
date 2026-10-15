#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Patterns (habits, weekdays, evening stress)
//
// Each pattern says how big the difference is, how many days it rests on, and whether it is a clear
// difference at all. "No clear difference" is a real answer and is shown, not hidden.
//
// "Clear" for a habit is `RankedEffect.fdrSignificant`: Benjamini–Hochberg at 10 % over every
// habit×lag test of the run (StrandAnalytics), not the raw per-test p < 0.05.

struct BodyPatternsContent: Equatable {
    var habits: [BodyFinding] = []
    var others: [BodyFinding] = []
    /// What each missing pattern waits for.
    var pending: [LocalizedStringResource] = []
}

enum BodyPatterns {

    /// Evening-stress splits smaller than this many minutes of deep sleep read as no clear difference.
    static let deepSleepNoise = 10.0

    static func build(_ s: BodySnapshot, outcome: BodyOutcome) -> BodyPatternsContent {
        var c = BodyPatternsContent()
        let ranked = EffectRanker.rank(behaviors: s.yesDays, controls: s.noDays,
                                       outcomeByDay: s.outcomes[outcome] ?? [:], outcome: outcome.rawValue)
        c.habits = ranked.map { habit($0, outcome: outcome) }
        if c.habits.isEmpty { c.pending.append(BodyStrings.pendingHabits) }
        if let w = weekday(s) { c.others.append(w) } else { c.pending.append(BodyStrings.pendingWeekday) }
        if let e = s.eveningStress { c.others.append(eveningStress(e)) } else { c.pending.append(BodyStrings.pendingEvening) }
        return c
    }

    // MARK: Habits

    static func habit(_ r: RankedEffect, outcome: BodyOutcome) -> BodyFinding {
        let e = r.effect
        let unit = metricUnit(outcome)
        let clear = r.fdrSignificant
        let name = habitName(r.behavior)
        let magnitude = e.pctChange.map { MetricUnit.percent.format(abs($0), locale: BodyFormat.locale) }
            ?? unit.format(abs(e.delta), locale: BodyFormat.locale)
        let value = e.pctChange.map { MetricUnit.percent.formatDelta($0, locale: BodyFormat.locale) }
            ?? unit.formatDelta(e.delta, locale: BodyFormat.locale)
        let possessive = String(localized: BodyStrings.possessive(outcome))
        let meaning: LocalizedStringResource
        if !clear {
            meaning = BodyStrings.habitNoClear(name, possessive)
        } else if e.delta > 0 {
            meaning = BodyStrings.habitHigher(name, possessive, magnitude)
        } else {
            meaning = BodyStrings.habitLower(name, possessive, magnitude)
        }
        let with = unit.format(e.meanWith, locale: BodyFormat.locale)
        let without = unit.format(e.meanWithout, locale: BodyFormat.locale)
        let d = e.cohensD.formatted(.number.precision(.fractionLength(2)).locale(BodyFormat.locale))
        return BodyFinding(
            id: "habit-\(r.behavior)",
            title: BodyStrings.verbatim(name),
            meaning: meaning,
            value: value,
            comparison: BodyStrings.withVsWithout(String(localized: lag(r.lag))),
            verdict: clear ? .clearDifference : .noClearDifference,
            sample: BodyStrings.withWithoutDays(e.nWith, e.nWithout),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.habitWhat,
                methodName: BodyStrings.habitMethod,
                methodSummary: BodyStrings.habitMethodSummary,
                citation: "Welch, 1947; Cohen, 1988",
                dataUsed: BodyStrings.habitData(with, e.nWith, without, e.nWithout, d),
                confidence: r.confidence == .solid ? .solid : .building,
                confidenceReason: BodyStrings.habitConfidence),
            visual: .groups(first: e.meanWith, second: e.meanWithout,
                            firstLabel: BodyStrings.with, secondLabel: BodyStrings.without, unit: unit))
    }

    static func metricUnit(_ outcome: BodyOutcome) -> MetricUnit {
        switch outcome.unit {
        case .percent: return .percent
        case .milliseconds: return .milliseconds
        case .beatsPerMinute: return .beatsPerMinute
        }
    }

    private static func lag(_ lag: Int) -> LocalizedStringResource {
        switch lag {
        case 0: return BodyStrings.sameDay
        case 1: return BodyStrings.nextMorning
        default: return BodyStrings.afterDays(lag)
        }
    }

    /// Display name for a journal question: the starter questions get a short noun, anything else is
    /// looked up in the catalogue so a translated custom question shows its translation.
    static func habitName(_ question: String) -> String {
        if let short = starterNames[question] { return String(localized: short) }
        return String(localized: String.LocalizationValue(question))
    }

    private static let starterNames: [String: LocalizedStringResource] = [
        "Did you drink any alcohol?": BodyStrings.habitAlcohol,
        "Did you have caffeine late in the day?": BodyStrings.habitLateCaffeine,
        "Did you view a screen in bed?": BodyStrings.habitScreen,
        "Did you eat close to bedtime?": BodyStrings.habitLateMeal,
        "Did you feel stressed?": BodyStrings.habitStress,
        "Did you use a sauna?": BodyStrings.habitSauna,
        "Did you share your bed?": BodyStrings.habitSharedBed,
        "Did you feel sick or ill?": BodyStrings.habitIll,
        "Did you take magnesium?": BodyStrings.habitMagnesium,
        "Did you read before bed?": BodyStrings.habitReading,
    ]

    // MARK: Weekday

    /// The engine names a weekday only when it stood out in most weeks. With enough weeks and no such
    /// day, the honest reading is "no weekday stands out", drawn from the plain weekday means.
    static func weekday(_ s: BodySnapshot) -> BodyFinding? {
        if let w = s.weekday, let e = w.lowest ?? w.highest {
            let low = w.lowest != nil
            let name = BodyFormat.weekday(e.weekday)
            let pct = MetricUnit.percent
            return weekdayFinding(
                meaning: low ? BodyStrings.weekdayWeakest(name) : BodyStrings.weekdayStrongest(name),
                value: name,
                comparison: BodyStrings.weekdayVsOthers(pct.format(e.mean, locale: BodyFormat.locale),
                                                        pct.format(e.othersMean, locale: BodyFormat.locale)),
                verdict: .clearDifference, weeks: e.weeks,
                visual: .weekdays(means: w.means, low: w.lowest?.weekday, high: w.highest?.weekday))
        }
        guard let means = plainWeekdayMeans(s.recovery) else { return nil }
        let spread = (means.means.values.max() ?? 0) - (means.means.values.min() ?? 0)
        return weekdayFinding(meaning: BodyStrings.weekdayNone,
                              value: MetricUnit.score.format(spread, locale: BodyFormat.locale),
                              comparison: BodyStrings.weekdaySpread,
                              verdict: .noClearDifference, weeks: means.weeks,
                              visual: .weekdays(means: means.means, low: nil, high: nil))
    }

    private static func weekdayFinding(meaning: LocalizedStringResource, value: String,
                                       comparison: LocalizedStringResource, verdict: BodyVerdict,
                                       weeks: Int, visual: BodyFindingVisual) -> BodyFinding {
        BodyFinding(
            id: "weekday",
            title: BodyStrings.weekdayTitle,
            meaning: meaning,
            value: value,
            comparison: comparison,
            verdict: verdict,
            sample: BodyStrings.weeks(weeks),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.weekdayWhat,
                methodName: BodyStrings.weekdayMethod,
                methodSummary: BodyStrings.weekdayMethodSummary,
                citation: nil,
                dataUsed: BodyStrings.weeks(weeks),
                confidence: .confidence(samples: weeks, solidAt: 16),
                confidenceReason: BodyStrings.sampleReason(weeks, 16)),
            visual: visual)
    }

    /// Mean recovery per ISO weekday over the last 26 weeks, when at least 8 weeks and 6 days per
    /// weekday exist (the engine's own minimums).
    static func plainWeekdayMeans(_ recovery: [BodyInsights.DayValue]) -> (means: [Int: Double], weeks: Int)? {
        guard let lastDay = recovery.last?.day else { return nil }
        let last = BodyFormat.date(lastDay)
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var groups: [Int: [Double]] = [:]
        var weeks = Set<Int>()
        for v in recovery {
            let date = BodyFormat.date(v.day)
            guard let age = cal.dateComponents([.day], from: date, to: last).day, age < 182 else { continue }
            let wd = (cal.component(.weekday, from: date) + 5) % 7 + 1
            groups[wd, default: []].append(v.value)
            weeks.insert(age / 7)
        }
        let means = groups.filter { $0.value.count >= 6 }.mapValues { $0.reduce(0, +) / Double($0.count) }
        guard weeks.count >= 8, means.count >= 6 else { return nil }
        return (means, weeks.count)
    }

    // MARK: Evening stress → deep sleep

    static func eveningStress(_ e: PatternInsights.SplitEffect) -> BodyFinding {
        let clear = abs(e.delta) >= deepSleepNoise
        let meaning: LocalizedStringResource = !clear ? BodyStrings.eveningNoClear
            : e.delta < 0 ? BodyStrings.eveningLess : BodyStrings.eveningMore
        let duration = MetricUnit.duration
        return BodyFinding(
            id: "evening",
            title: BodyStrings.eveningTitle,
            meaning: meaning,
            value: duration.formatDelta(e.delta * 60, locale: BodyFormat.locale),
            comparison: BodyStrings.eveningComparison,
            verdict: clear ? .clearDifference : .noClearDifference,
            sample: BodyStrings.evenings(e.n),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.eveningWhat,
                methodName: BodyStrings.eveningMethod,
                methodSummary: BodyStrings.eveningMethodSummary,
                citation: nil,
                dataUsed: BodyStrings.eveningData(duration.format(e.highMean * 60, locale: BodyFormat.locale),
                                                  duration.format(e.lowMean * 60, locale: BodyFormat.locale), e.n),
                confidence: .confidence(samples: e.n, solidAt: 21),
                confidenceReason: BodyStrings.sampleReason(e.n, 21)),
            visual: .groups(first: e.highMean * 60, second: e.lowMean * 60,
                            firstLabel: BodyStrings.stressfulEvenings, secondLabel: BodyStrings.calmEvenings,
                            unit: duration))
    }
}
#endif
