import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Readouts only the dashboard shows: the day's stress average and the fasting streak
//
// Pure builders, like the rest of `TodayBodyReadouts`. The vitals, sleep debt and VO₂max tiles reuse
// the readouts of the screens that own them instead, so a tile and its screen cannot disagree.

extension TodayBodyReadouts {

    /// The selected day's own stress average against the wearer's resting-baseline bands. Another
    /// day's level is never carried onto this one.
    static func stressDaily(_ daily: DaytimeStress.Daily?, dayKey: String) -> MetricReadout {
        let unit = MetricUnit.score(fractionDigits: 1)
        guard let level = daily?.trend.last(where: { $0.day == dayKey })?.level
                ?? (daily?.day == dayKey ? daily?.level : nil) else {
            return MetricReadout(id: .stressDaily, label: TodayCopy.tileStressDaily, value: nil, unit: unit,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.stressDailyNoData,
                                 tint: .stress)
        }
        let word = rangeVerdict(level, stressTypical)
        let confidence: MetricReadout.Confidence = (daily?.baselineNights ?? 0) >= minOwnDays ? .solid : .building
        return MetricReadout(id: .stressDaily, label: TodayCopy.tileStressDaily, value: level, unit: unit,
                             typicalRange: stressTypical, verdict: word.verdict,
                             meaning: TodayCopy.vitalMeaning(.stress, word), confidence: confidence, tint: .stress)
    }

    /// Goal-met days in a row, with the verdict from the last 30 days' consistency (High / Medium / Low).
    static func fastingStreak(days: Int, metDays: Int, consideredDays: Int) -> MetricReadout {
        guard consideredDays > 0 else {
            return MetricReadout(id: .fastingStreak, label: TodayCopy.tileFasting, value: nil, unit: .days,
                                 verdict: .unavailable(.noData(since: nil)), meaning: TodayCopy.fastingNoData,
                                 tint: .fasting)
        }
        let share = Double(metDays) / Double(consideredDays) * 100
        return MetricReadout(id: .fastingStreak, label: TodayCopy.tileFasting, value: Double(days), unit: .days,
                             verdict: .score(ScoreBand(score: share)),
                             meaning: TodayCopy.fastingMeaning(met: metDays, of: consideredDays), tint: .fasting)
    }

    /// A tile whose source has nothing for the selected day.
    static func unavailable(_ kind: TodayTileKind, id: MetricID, unit: MetricUnit,
                            meaning: LocalizedStringResource) -> MetricReadout {
        MetricReadout(id: id, label: kind.label, value: nil, unit: unit,
                      verdict: .unavailable(.noData(since: nil)), meaning: meaning)
    }
}
