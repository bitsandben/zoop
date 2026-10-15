import Foundation
import StrandAnalytics
import StrandDesign

/// One mindfulness number with everything its explainer shows.
struct MindfulMetric: Identifiable {
    let readout: MetricReadout
    let explanation: MetricExplanation
    var id: MetricID { readout.id }
}

enum MindfulMetricID {
    static let minutes: MetricID = "mindful_minutes"
    static let days: MetricID = "mindful_days"
    static let hrDrop: MetricID = "mindful_hr_drop"
    static let hrvChange: MetricID = "mindful_hrv_change"
    static let stress: MetricID = "mindful_stress_shift"
    static let rhrContrast: MetricID = "mindful_rhr_contrast"
    static let hrvContrast: MetricID = "mindful_hrv_contrast"
}

// MARK: - Readout builders (pure)
//
// Every number in the mindfulness section is built here from the StrandAnalytics results. Verdicts come
// from the analytics' own classification (clear / not clear / not enough data), so the copy can never
// claim more than the sample sizes allow.

enum MindfulnessReadouts {

    struct Inputs {
        var summary: MindfulPractice.Summary
        var progress: MindfulResponse.Progress
        var stress: MindfulOutcomes.StressSummary
        var rhr: MindfulOutcomes.DayContrast
        var hrv: MindfulOutcomes.DayContrast
        /// Start of the history the effect figures were measured over.
        var window: DateInterval
    }

    /// Reference week for a new user: 5 to 20 minutes on most days.
    static let populationMinutes: ClosedRange<Double> = 35...140
    static let populationDays: ClosedRange<Double> = 3...6
    /// A change inside these bands is read as "no clear change".
    static let hrDropBand = 1.5
    static let hrvChangeBand = 5.0
    static let stressBand = 0.2

    // MARK: Practice volume

    static func minutes(_ s: MindfulPractice.Summary) -> MindfulMetric {
        let value = s.minutesThisWeek * 60
        let personal = s.typicalMinutesRange.map { ($0.lowerBound * 60)...($0.upperBound * 60) }
        let range = personal ?? (populationMinutes.lowerBound * 60)...(populationMinutes.upperBound * 60)
        let verdict = MetricVerdict.vital(value, typicalRange: range)
        let meaning: LocalizedStringResource
        if s.minutesThisWeek == 0 { meaning = MindfulnessStrings.minutesNone } else {
            switch verdict {
            case .above: meaning = MindfulnessStrings.minutesAbove
            case .below: meaning = MindfulnessStrings.minutesBelow
            default: meaning = MindfulnessStrings.minutesTypical
            }
        }
        let readout = MetricReadout(
            id: MindfulMetricID.minutes, label: MindfulnessStrings.minutesLabel, value: value, unit: .duration,
            typicalRange: range, rangeIsPersonal: personal != nil,
            delta: s.typicalWeekMinutes.map { value - $0 * 60 },
            verdict: verdict, meaning: meaning, confidence: confidence(weeks: s.pastWeekMinutes.count),
            tint: .neutral, polarity: .higherIsBetter)
        return MindfulMetric(readout: readout, explanation: MindfulnessExplanations.minutes(weeks: s.pastWeekMinutes.count))
    }

    static func days(_ s: MindfulPractice.Summary) -> MindfulMetric {
        let value = Double(s.practiceDaysThisWeek)
        let personal = s.typicalDaysRange
        let range = personal ?? populationDays
        let readout = MetricReadout(
            id: MindfulMetricID.days, label: MindfulnessStrings.daysLabel, value: value, unit: .days,
            typicalRange: range, rangeIsPersonal: personal != nil,
            verdict: .vital(value, typicalRange: range),
            meaning: s.streakDays >= 2 ? MindfulnessStrings.streak(s.streakDays) : MindfulnessStrings.daysMeaning,
            confidence: confidence(weeks: s.pastWeekDays.count), tint: .neutral, polarity: .higherIsBetter)
        return MindfulMetric(readout: readout, explanation: MindfulnessExplanations.days(weeks: s.pastWeekDays.count))
    }

    /// Weeks of history become a personal range at `MindfulPractice.minWeeksForNormal`.
    private static func confidence(weeks: Int) -> MetricReadout.Confidence {
        let left = MindfulPractice.minWeeksForNormal - weeks
        return left > 0 ? .calibrating(nightsLeft: left * 7) : .solid
    }

    // MARK: Session response

    static func hrDrop(_ p: MindfulResponse.Progress, window: DateInterval) -> MindfulMetric {
        let explanation = MindfulnessExplanations.hrDrop(sessions: p.sessions, window: window)
        guard let drop = p.meanHRDrop else {
            return MindfulMetric(readout: unavailable(MindfulMetricID.hrDrop, MindfulnessStrings.hrDropLabel,
                                                      unit: .beatsPerMinute, meaning: MindfulnessStrings.needSessions(p.sessions)),
                                 explanation: explanation)
        }
        let verdict = effect(drop, band: hrDropBand)
        var meaning: LocalizedStringResource
        switch verdict {
        case .load(.restorative): meaning = MindfulnessStrings.hrDropClear(p.sessions)
        case .load(.demanding): meaning = MindfulnessStrings.hrDropRises
        default: meaning = MindfulnessStrings.hrDropNone(p.sessions)
        }
        if p.trend == .deeper { meaning = MindfulnessStrings.trendDeeper }
        if p.trend == .shallower { meaning = MindfulnessStrings.trendShallower }
        let readout = MetricReadout(id: MindfulMetricID.hrDrop, label: MindfulnessStrings.hrDropLabel, value: drop,
                                    unit: .beatsPerMinute, verdict: verdict, meaning: meaning,
                                    confidence: p.sessions < MindfulResponse.minSessionsForTrend ? .building : .solid,
                                    polarity: .higherIsBetter)
        return MindfulMetric(readout: readout, explanation: explanation)
    }

    static func hrvChange(_ p: MindfulResponse.Progress, window: DateInterval) -> MindfulMetric {
        let explanation = MindfulnessExplanations.hrvChange(sessions: p.rmssdSessions, window: window)
        guard let change = p.meanRMSSDChange else {
            return MindfulMetric(readout: unavailable(MindfulMetricID.hrvChange, MindfulnessStrings.hrvChangeLabel,
                                                      unit: .percent, meaning: MindfulnessStrings.needSessions(p.rmssdSessions)),
                                 explanation: explanation)
        }
        let verdict = effect(change, band: hrvChangeBand)
        let n = p.rmssdSessions
        let meaning: LocalizedStringResource
        switch verdict {
        case .load(.restorative): meaning = MindfulnessStrings.hrvUp(n)
        case .load(.demanding): meaning = MindfulnessStrings.hrvDown(n)
        default: meaning = MindfulnessStrings.hrvFlat(n)
        }
        let readout = MetricReadout(id: MindfulMetricID.hrvChange, label: MindfulnessStrings.hrvChangeLabel, value: change,
                                    unit: .percent, verdict: verdict, meaning: meaning,
                                    confidence: n < MindfulResponse.minSessionsForTrend ? .building : .solid,
                                    polarity: .higherIsBetter)
        return MindfulMetric(readout: readout, explanation: explanation)
    }

    static func stress(_ s: MindfulOutcomes.StressSummary, window: DateInterval) -> MindfulMetric {
        let explanation = MindfulnessExplanations.stress(sessions: s.sessions, window: window)
        guard let change = s.meanChange, let share = s.calmerShare else {
            return MindfulMetric(readout: unavailable(MindfulMetricID.stress, MindfulnessStrings.stressLabel,
                                                      unit: .score(fractionDigits: 1), meaning: MindfulnessStrings.stressNeed(s.sessions)),
                                 explanation: explanation)
        }
        let calmer = Int((share * Double(s.sessions)).rounded())
        let readout = MetricReadout(id: MindfulMetricID.stress, label: MindfulnessStrings.stressLabel, value: change,
                                    unit: .score(fractionDigits: 1), verdict: effect(-change, band: stressBand),
                                    meaning: MindfulnessStrings.stressCalmer(calmer, s.sessions),
                                    confidence: s.sessions < 6 ? .building : .solid, tint: .stress,
                                    polarity: .lowerIsBetter)
        return MindfulMetric(readout: readout, explanation: explanation)
    }

    // MARK: Days with vs without practice

    static func contrast(_ c: MindfulOutcomes.DayContrast, id: MetricID, label: LocalizedStringResource,
                         unit: MetricUnit, polarity: MetricPolarity, window: DateInterval) -> MindfulMetric {
        let explanation = MindfulnessExplanations.contrast(id: id, with: c.daysWith, without: c.daysWithout, window: window)
        guard let diff = c.difference, c.comparison != .notEnoughDays else {
            return MindfulMetric(readout: unavailable(id, label, unit: unit,
                                                      meaning: MindfulnessStrings.contrastNeed(c.daysWith, c.daysWithout)),
                                 explanation: explanation)
        }
        let verdict: MetricVerdict
        switch c.comparison {
        case .clearlyHigher: verdict = .above
        case .clearlyLower: verdict = .below
        default: verdict = .typical
        }
        let assessment = MetricAssessment(verdict: verdict, polarity: polarity)
        let meaning: LocalizedStringResource
        switch assessment {
        case .better: meaning = MindfulnessStrings.contrastBetter(c.daysWith, c.daysWithout)
        case .worse: meaning = MindfulnessStrings.contrastWorse(c.daysWith, c.daysWithout)
        case .neutral: meaning = MindfulnessStrings.contrastNone(c.daysWith, c.daysWithout)
        }
        // The practice-night mean, with its gap to the other nights as the delta.
        let readout = MetricReadout(id: id, label: label, value: c.withPractice, unit: unit, delta: diff,
                                    verdict: verdict, meaning: meaning, confidence: .building, polarity: polarity)
        return MindfulMetric(readout: readout, explanation: explanation)
    }

    // MARK: Helpers

    /// Restorative when the calming change exceeds the band, demanding when it goes the other way.
    private static func effect(_ calming: Double, band: Double) -> MetricVerdict {
        if calming >= band { return .load(.restorative) }
        if calming <= -band { return .load(.demanding) }
        return .typical
    }

    private static func unavailable(_ id: MetricID, _ label: LocalizedStringResource, unit: MetricUnit,
                                    meaning: LocalizedStringResource) -> MetricReadout {
        MetricReadout(id: id, label: label, value: nil, unit: unit, verdict: .unavailable(.noData(since: nil)),
                      meaning: meaning, confidence: .building)
    }

    static func all(_ i: Inputs) -> (practice: [MindfulMetric], effect: [MindfulMetric]) {
        let practice = [minutes(i.summary), days(i.summary)]
        let effect = [
            hrDrop(i.progress, window: i.window),
            hrvChange(i.progress, window: i.window),
            stress(i.stress, window: i.window),
            contrast(i.rhr, id: MindfulMetricID.rhrContrast, label: MindfulnessStrings.rhrLabel, unit: .beatsPerMinute,
                     polarity: .lowerIsBetter, window: i.window),
            contrast(i.hrv, id: MindfulMetricID.hrvContrast, label: MindfulnessStrings.hrvNightLabel, unit: .milliseconds,
                     polarity: .higherIsBetter, window: i.window),
        ]
        return (practice, effect)
    }
}
