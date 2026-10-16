import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One line of "What set your recovery today".
struct RecoveryFactorItem: Identifiable {
    let id: String
    let sentence: LocalizedStringResource
    /// lowers / raises when the factor moved recovery by at least a whole point (an illness signal always
    /// lowers); neutral when unsized or too small to show.
    let effect: MetricExplanation.Contributor.Effect
}

struct RecoveryFactorsContent {
    /// Ranked strongest first; empty when nothing stood out (the card then says so).
    let items: [RecoveryFactorItem]
    /// One next step from the strongest factor that lowered recovery; nil when none did.
    let advice: LocalizedStringResource?
}

// MARK: - RecoveryFactorsBuilder
//
// Gathers the deviations behind this morning's score from stored rows and hands them to
// `RecoveryFactors` for sizing and ranking. Scorer-backed terms (sleep, HRV, resting HR) reuse the
// scorer's own driver points, so a line can never claim more than the score felt.

enum RecoveryFactorsBuilder {

    /// Journal answers that are known recovery confounders; any other answer is listed only when the
    /// user's own history shows a significant effect.
    static let confounders: [String: LocalizedStringResource] = [
        "Did you drink any alcohol?": RecoveryStrings.loggedAlcohol,
        "Did you have caffeine late in the day?": RecoveryStrings.loggedCaffeine,
        "Did you eat close to bedtime?": RecoveryStrings.loggedLateMeal,
        "Did you feel stressed?": RecoveryStrings.loggedStress,
        "Did you feel sick or ill?": RecoveryStrings.loggedSick,
    ]

    /// Only for a score earned this morning: "yesterday" is then the day before the anchor.
    static func build(_ input: RecoveryInput, drivers: [ChargeDriver]) -> RecoveryFactorsContent? {
        guard let factors = factorsInput(input, drivers: drivers) else { return nil }
        let ranked = RecoveryFactors.rank(factors)
        let items = ranked.enumerated().map { index, factor in
            RecoveryFactorItem(id: "\(factor.kind.rawValue)-\(index)",
                               sentence: RecoveryStrings.factorSentence(factor, name: name(factor.question)),
                               effect: effect(factor))
        }
        return RecoveryFactorsContent(items: items, advice: RecoveryFactors.advice(ranked).map(RecoveryStrings.advice))
    }

    /// The deviations behind this morning's score, unranked. Shared with the morning brief so the two
    /// cannot name different drivers. Nil unless the anchor is today's score.
    static func factorsInput(_ input: RecoveryInput, drivers: [ChargeDriver]) -> RecoveryFactors.Input? {
        guard let row = input.anchor, row.day == input.todayKey,
              let today = RecoveryDayKey.date(row.day),
              let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) else { return nil }
        let yesterdayKey = Repository.localDayKey(yesterday)
        let days = input.days.filter { $0.day <= row.day }.sorted { $0.day < $1.day }
        func points(_ label: String) -> Double? { drivers.first { $0.label == label }.map { Double($0.deltaPoints) } }

        var factors = RecoveryFactors.Input(illnessSignals: input.illnessSignals)
        factors.strainYesterday = days.first { $0.day == yesterdayKey }?.strain
        factors.strainAverage = RecoveryFactors.strainAverage(days.filter { $0.day < yesterdayKey }.compactMap(\.strain))
        factors.strainPointsPer10 = BodyInsights.strainSensitivity(BodyInsights.loads(days))?.pointsPer10
        factors.sleepMinutesVsNeed = row.totalSleepMin.map { $0 - input.scoring.needHours * 60 }
        factors.sleepPoints = points("Sleep vs need")
        if let hrv = row.avgHrv, let base = input.baselines?.hrv, base.baseline > 0 {
            factors.hrvPercent = (hrv - base.baseline) / base.baseline * 100
            factors.hrvPoints = points("Heart rate variability")
        }
        if let rhr = row.restingHr, let base = input.baselines?.restingHR, base.usable {
            factors.restingHRDelta = Double(rhr) - base.baseline
            factors.restingHRPoints = points("Resting heart rate")
        }
        bedtime(into: &factors, input: input, days: days, todayKey: row.day)
        factors.logged = logged(input: input, days: days, keys: [row.day, yesterdayKey])
        return factors
    }

    private static func effect(_ factor: RecoveryFactors.Factor) -> MetricExplanation.Contributor.Effect {
        if factor.kind == .illness { return .lowers }
        guard let points = factor.points, abs(points) >= 1 else { return .neutral }
        // A harder day that went with higher recovery (or an easier one with lower) is worded as "rarely
        // moves recovery", so the arrow must not claim a direction the sentence does not.
        if factor.kind == .strain, (factor.deviation > 0) == (points > 0) { return .neutral }
        return points < 0 ? .lowers : .raises
    }

    // MARK: Bedtime

    private static func bedtime(into factors: inout RecoveryFactors.Input, input: RecoveryInput,
                                days: [DailyMetric], todayKey: String) {
        // One onset per wake day: the longest block ending that day is the main night.
        var onsetByDay: [String: Int] = [:]
        var lengthByDay: [String: Int] = [:]
        for s in input.sleeps {
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            let length = s.endTs - s.effectiveStartTs
            if length > lengthByDay[key] ?? 0 {
                lengthByDay[key] = length
                onsetByDay[key] = minuteOfDay(s.effectiveStartTs)
            }
        }
        guard let last = onsetByDay[todayKey] else { return }
        let earlier = onsetByDay.filter { $0.key < todayKey }.sorted { $0.key < $1.key }
        guard let late = RecoveryFactors.bedtimeLateness(lastMinuteOfDay: last,
                                                         earlierMinutesOfDay: earlier.suffix(30).map(\.value))
        else { return }
        factors.bedtimeLateMinutes = late
        // The slope ignores where lateness is measured from, so any one reference serves every pair.
        let recovery = Dictionary(days.compactMap { d in d.recovery.map { (d.day, $0) } }, uniquingKeysWith: { a, _ in a })
        let pairs = earlier.suffix(180).compactMap { day, minute -> (lateMinutes: Double, recovery: Double)? in
            recovery[day].map { (Double(RecoveryFactors.fromNoonMinutes(minute)), $0) }
        }
        factors.bedtimePointsPerHour = RecoveryFactors.bedtimePointsPerHour(pairs)
    }

    private static func minuteOfDay(_ ts: Int) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: Logged

    private static func logged(input: RecoveryInput, days: [DailyMetric], keys: Set<String>) -> [RecoveryFactors.Logged] {
        var yes: [String: Set<String>] = [:], no: [String: Set<String>] = [:]
        for e in input.journal {
            if e.answeredYes { yes[e.question, default: []].insert(e.day) } else { no[e.question, default: []].insert(e.day) }
        }
        let outcome = Dictionary(days.filter { !keys.contains($0.day) }.compactMap { d in d.recovery.map { (d.day, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        return yes.keys.sorted().compactMap { question in
            guard let days = yes[question], !days.isDisjoint(with: keys) else { return nil }
            let effect = BehaviorInsights.effect(behaviorDays: days, controlDays: no[question] ?? [],
                                                 outcomeByDay: outcome, behavior: question, outcome: "recovery")
            guard confounders[question] != nil || effect?.significant == true else { return nil }
            return .init(question: question, effect: effect)
        }
    }

    /// The display name of a logged answer: a localised name for the known confounders, else the user's
    /// own question in quotes.
    static func name(_ question: String?) -> String {
        guard let question else { return "" }
        if var known = confounders[question] {
            known.locale = AppLanguage.activeLocale
            return String(localized: known)
        }
        return "“\(question)”"
    }
}
