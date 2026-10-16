import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - RecoveryContentBuilder
//
// Turns stored data into the screen's content. The score is never recomputed here: it is the stored
// value of the row Home shows, wrapped by `RecoveryScorer.assessment` for its confidence and reason, so
// this screen and Home cannot disagree.

enum RecoveryContentBuilder {

    /// Days a score may trail today before the hero says "Last reading" and greys the number.
    private static let staleAfterDays = 1
    /// Scored days needed before a personal range is drawn; fewer would be a guess dressed as a range.
    private static let minNightsForRange = 7

    static func build(_ input: RecoveryInput) -> RecoveryContent {
        let baselines = input.baselines
        let assessment = RecoveryScorer.assessment(score: input.anchor?.recovery, hrvBaseline: baselines?.hrv)
        let hrvNights = baselines?.hrv.nValid ?? 0

        let history = scoredHistory(input)
        let range = personalRange(history)
        let state: RecoveryContent.State
        switch assessment.reason {
        case .scored: state = .scored
        case .calibrating: state = .calibrating
        case .missingInputs: state = .missingInputs
        }

        let hero = heroReadout(input, assessment: assessment, range: range, nightsKnown: hrvNights)
        let window = history.first.flatMap { first in history.last.map { DateInterval(start: first.date, end: $0.date) } }
        var contributors: [RecoveryContributor] = []
        var factors: RecoveryFactorsContent?
        if state == .scored, let row = input.anchor, let baselines {
            contributors = RecoveryContributors.build(row: row, baselines: baselines, input: input)
            let drivers = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row, charge: input.scoring)?.drivers
            factors = RecoveryFactorsBuilder.build(input, drivers: drivers ?? [])
        }
        return RecoveryContent(
            state: state,
            hero: hero,
            heroExplanation: RecoveryExplanations.hero(confidence: assessment.confidence, hrvNights: hrvNights, window: window),
            contributors: contributors,
            factors: factors,
            trend: history.suffix(90).map { RecoveryTrendDay(date: $0.date, value: $0.value) },
            typicalRange: range,
            forecast: state == .scored ? forecast(input) : nil,
            timeline: hrvNights < Baselines.minNightsTrust ? timeline(nights: hrvNights) : [],
            personalisation: personalisation(input),
            todayFeeling: input.calibrationEnabled ? input.checkIns[input.anchor?.day ?? input.todayKey]?.feeling : nil)
    }

    // MARK: Hero

    private static func heroReadout(_ input: RecoveryInput,
                                    assessment: Assessment<Double, RecoveryScorer.Reason>,
                                    range: ClosedRange<Double>?, nightsKnown: Int) -> MetricReadout {
        let staleDays = input.anchor.map { RecoveryDayKey.daysBetween($0.day, input.todayKey) } ?? 0
        let isStale = staleDays > staleAfterDays
        let staleSince = input.anchor.flatMap { RecoveryDayKey.date($0.day) }

        guard let score = assessment.value else {
            let nightsLeft = max(Baselines.minNightsSeed - nightsKnown, 1)
            let missing = assessment.reason == .missingInputs
            return MetricReadout(
                id: .recovery, label: RecoveryStrings.heroLabelLastNight, value: nil, unit: .score,
                verdict: .unavailable(missing ? .noData(since: staleSince) : .calibrating(nightsLeft: nightsLeft)),
                meaning: missing ? RecoveryStrings.heroMeaningMissing : RecoveryStrings.heroMeaningCalibrating,
                confidence: .calibrating(nightsLeft: nightsLeft), tint: .recovery)
        }
        let band = ScoreBand(score: score)
        let confidence: MetricReadout.Confidence
        switch assessment.confidence {
        case .solid: confidence = .solid
        case .building: confidence = .building
        case .calibrating: confidence = .calibrating(nightsLeft: max(Baselines.minNightsSeed - nightsKnown, 1))
        }
        let mid = range.map { ($0.lowerBound + $0.upperBound) / 2 }
        return MetricReadout(
            // The nav title already says "Recovery"; the hero names which night the number is from.
            id: .recovery, label: isStale ? RecoveryStrings.heroLabelLastReading : RecoveryStrings.heroLabelLastNight,
            value: score, unit: .score, typicalRange: range, delta: mid.map { score - $0 },
            verdict: .score(band), meaning: RecoveryStrings.heroMeaning(band),
            confidence: isStale ? .stale(since: staleSince ?? input.now) : confidence, tint: .recovery)
    }

    // MARK: History and range

    private struct Scored { let date: Date; let value: Double }

    private static func scoredHistory(_ input: RecoveryInput) -> [Scored] {
        input.days.sorted { $0.day < $1.day }.compactMap { day in
            guard let value = day.recovery, let date = RecoveryDayKey.date(day.day) else { return nil }
            return Scored(date: date, value: value)
        }
    }

    /// The personal range of the stored scores, for callers outside this screen (the morning brief).
    static func recoveryRange(days: [DailyMetric]) -> ClosedRange<Double>? {
        personalRange(days.sorted { $0.day < $1.day }.compactMap { day in
            guard let value = day.recovery, let date = RecoveryDayKey.date(day.day) else { return nil }
            return Scored(date: date, value: value)
        })
    }

    /// Recovery has no baseline of its own (it is itself a score against baselines), so its typical
    /// range is mean ± one SD of the user's last 30 scored days.
    private static func personalRange(_ history: [Scored]) -> ClosedRange<Double>? {
        let recent = history.suffix(30).map(\.value)
        guard recent.count >= minNightsForRange else { return nil }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recent.count - 1)
        let sd = variance.squareRoot()
        return max(0, mean - sd)...min(100, mean + sd)
    }

    // MARK: Forecast

    /// Only for a score earned today: tomorrow's estimate leans on today's strain, which a stale
    /// anchor does not have.
    private static func forecast(_ input: RecoveryInput) -> RecoveryForecastContent? {
        guard let row = input.anchor, row.day == input.todayKey else { return nil }
        let days = input.days.sorted { $0.day < $1.day }
        guard let result = RecoveryForecaster.forecast(
            recentCharge: days.compactMap(\.recovery), recentEffort: days.compactMap(\.strain),
            todayEffort: row.strain, plannedSleepHours: input.scoring.needHours,
            needHours: input.scoring.needHours),
              result.confidence != .calibrating
        else { return nil }
        return RecoveryForecastContent(low: result.low, high: result.high, sleepSeconds: input.scoring.needHours * 3600)
    }

    // MARK: Calibration timeline

    private static func timeline(nights: Int) -> [RecoveryTimelineStep] {
        let milestones: [(title: LocalizedStringResource, nights: Int)] = [
            (RecoveryStrings.stepScore, Baselines.minNightsSeed),
            (RecoveryStrings.stepPersonal, Baselines.minNightsTrust),
        ]
        // The first milestone not yet reached is the one the user is on; it shows its own progress.
        let currentIndex = milestones.firstIndex { nights < $0.nights }
        return milestones.enumerated().map { index, milestone in
            let status: RecoveryTimelineStep.Status =
                nights >= milestone.nights ? .done : (index == currentIndex ? .current : .upcoming)
            let detail = status == .current
                ? RecoveryStrings.stepProgress(nights, of: milestone.nights)
                : RecoveryStrings.stepAfter(milestone.nights)
            return RecoveryTimelineStep(id: index, title: milestone.title, detail: detail, status: status)
        }
    }

    // MARK: Personalisation

    private static func personalisation(_ input: RecoveryInput) -> RecoveryPersonalisation {
        guard input.calibrationEnabled else { return .off }
        let result = input.calibration
        guard result.phase != .collecting else {
            return .collecting(mornings: result.mornings, needed: RecoveryCalibration.previewDays)
        }
        let shifts: [RecoveryPersonalisation.Shift] = ChargeTerm.allCases.compactMap { term in
            let standard = ChargeWeights.standard.weight(term)
            guard standard > 0 else { return nil }
            let percent = Int(((result.weights.weight(term) / standard - 1) * 100).rounded())
            return .init(term: term, percent: percent)
        }
        // Below 5 % the shift is noise a sentence should not dwell on.
        let biggest = shifts.max { abs($0.percent) < abs($1.percent) }
        return .learned(shift: biggest.flatMap { abs($0.percent) >= 5 ? $0 : nil })
    }
}
