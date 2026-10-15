import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The "Stillness in sleep" card: three readouts for the displayed night and whether its motion data
/// was thin enough to say so on the card.
struct SleepRestlessContent {
    let metrics: [SleepMetric]
    let lowConfidence: Bool
}

// MARK: - SleepRestlessReadouts
//
// Movement bouts, restless time and the longest still stretch of a night, each against the user's own
// earlier nights. The numbers come from `SleepRestlessness` over the motion the stager stored beside the
// stages; this file only gathers each night's motion and wraps the results as readouts.

enum SleepRestlessReadouts {

    static let bouts: MetricID = "sleep_restless_bouts"
    static let restless: MetricID = "sleep_restless_minutes"
    static let still: MetricID = "sleep_still_longest"

    /// One analysed night, keyed by its wake day.
    struct Entry {
        let day: String
        let night: SleepRestlessness.Night
    }

    /// Nights analysed per navigation offset (newest = 0). The main-night group's stored motion in
    /// timeline order, so every night is read the same way the displayed one is.
    static func entries(navDays: [[CachedSleepSession]], habitualMidsleepSec: Int?,
                        motions: [Int: [Double]], limit: Int = 120) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        for (offset, blocks) in navDays.prefix(limit).enumerated() {
            let group = SleepScreen.mainNightGroup(blocks, habitualMidsleepSec: habitualMidsleepSec)
            let epochs = group.flatMap { motions[$0.startTs] ?? [] }
            guard let last = group.last,
                  let night = SleepRestlessness.analyze(epochCounts: epochs,
                                                        sparse: group.contains { $0.stagingSparse == true })
            else { continue }
            out[offset] = Entry(day: Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(last.endTs))),
                                night: night)
        }
        return out
    }

    /// The card for the night at `offset`, compared with the nights before it; nil when it has no motion.
    static func content(offset: Int, entries: [Int: Entry]) -> SleepRestlessContent? {
        guard let tonight = entries[offset] else { return nil }
        let earlier = entries.filter { $0.key > offset }.sorted { $0.key > $1.key }.map(\.value)
        let low = tonight.night.confidence == .low
        func metric(_ id: MetricID, unit: MetricUnit, polarity: MetricPolarity,
                    _ pick: (SleepRestlessness.Night) -> Double) -> SleepMetric {
            let history = earlier.map { (day: $0.day, value: pick($0.night)) }
            return readout(id: id, unit: unit, polarity: polarity, value: pick(tonight.night),
                           day: tonight.day, history: history, low: low)
        }
        return SleepRestlessContent(metrics: [
            metric(bouts, unit: .score(fractionDigits: 0), polarity: .lowerIsBetter) { Double($0.bouts) },
            metric(restless, unit: .duration, polarity: .lowerIsBetter) { $0.restlessMinutes * 60 },
            metric(still, unit: .duration, polarity: .higherIsBetter) { $0.longestStillMinutes * 60 },
        ], lowConfidence: low)
    }

    private static func readout(id: MetricID, unit: MetricUnit, polarity: MetricPolarity, value: Double,
                                day: String, history: SleepReadouts.History, low: Bool) -> SleepMetric {
        let range = SleepRestlessness.typicalRange(history.suffix(30).map(\.value))
        let readout: MetricReadout
        if let range {
            let verdict = MetricVerdict.vital(value, typicalRange: range)
            readout = MetricReadout(
                id: id, label: SleepRestlessStrings.label(id), value: value, unit: unit, typicalRange: range,
                delta: value - (range.lowerBound + range.upperBound) / 2, verdict: verdict,
                meaning: SleepRestlessStrings.meaning(id, MetricAssessment(verdict: verdict, polarity: polarity)),
                confidence: low ? .building : .solid, tint: .sleep, polarity: polarity)
        } else {
            let left = max(SleepRestlessness.minHistoryNights - history.count, 1)
            readout = MetricReadout(
                id: id, label: SleepRestlessStrings.label(id), value: value, unit: unit,
                verdict: .unavailable(.calibrating(nightsLeft: left)),
                meaning: SleepRestlessStrings.learning, confidence: .calibrating(nightsLeft: left),
                tint: .sleep, polarity: polarity)
        }
        var points = Array(history.suffix(29))
        points.append((day, value))
        let trend = points.map { MetricExplanation.TrendPoint(date: SleepReadouts.date($0.day), value: $0.value) }
        let window = trend.first.flatMap { first in trend.last.map { DateInterval(start: first.date, end: $0.date) } }
        let nights = min(history.count, 30)
        let explanation = MetricExplanation(
            whatItIs: SleepRestlessStrings.whatItIs(id),
            method: .init(name: SleepRestlessStrings.methodName, summary: SleepRestlessStrings.methodSummary),
            dataUsed: .init(count: .nights(nights), window: window),
            confidenceReason: low ? SleepRestlessStrings.lowReason : SleepRestlessStrings.limits,
            trend: trend)
        return SleepMetric(readout: readout, explanation: explanation)
    }
}

// MARK: - Copy (zoop.sleep.restless.*)

enum SleepRestlessStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    static let card = r("zoop.sleep.restless.card", "Stillness in sleep")
    static let lowNote = r("zoop.sleep.restless.lowNote",
        "Little motion data this night, so these values are uncertain.")
    static let learning = r("zoop.sleep.restless.learning", "Zoop is still learning how you usually move at night.")

    static func label(_ id: MetricID) -> LocalizedStringResource {
        switch id {
        case SleepRestlessReadouts.bouts: return r("zoop.sleep.restless.label.bouts", "Movement bouts")
        case SleepRestlessReadouts.restless: return r("zoop.sleep.restless.label.restless", "Restless time")
        default: return r("zoop.sleep.restless.label.still", "Longest still stretch")
        }
    }

    static func meaning(_ id: MetricID, _ assessment: MetricAssessment) -> LocalizedStringResource {
        switch (id, assessment) {
        case (SleepRestlessReadouts.still, .better): return r("zoop.sleep.restless.meaning.still.better", "You lay still for longer than usual.")
        case (SleepRestlessReadouts.still, .worse): return r("zoop.sleep.restless.meaning.still.worse", "Your still stretches were shorter than usual.")
        case (SleepRestlessReadouts.still, _): return r("zoop.sleep.restless.meaning.still.typical", "Your longest still stretch was as usual.")
        case (_, .better): return r("zoop.sleep.restless.meaning.calmer", "You moved less than on your usual nights.")
        case (_, .worse): return r("zoop.sleep.restless.meaning.moreRestless", "You moved more than on your usual nights.")
        default: return r("zoop.sleep.restless.meaning.typical", "About as calm as your usual nights.")
        }
    }

    static func whatItIs(_ id: MetricID) -> LocalizedStringResource {
        switch id {
        case SleepRestlessReadouts.bouts: return r("zoop.sleep.restless.explain.bouts",
            "How often your wrist moved clearly during the night, such as turning over. Fewer bouts mean a calmer night.")
        case SleepRestlessReadouts.restless: return r("zoop.sleep.restless.explain.restless",
            "The total time your wrist moved clearly between falling asleep and waking up.")
        default: return r("zoop.sleep.restless.explain.still",
            "The longest stretch without any clear movement. Long still stretches usually mean undisturbed sleep.")
        }
    }

    static let methodName = r("zoop.sleep.restless.method.name", "Movement against the night's resting level")
    static let methodSummary = r("zoop.sleep.restless.method.summary",
        "A 30-second epoch counts as restless when the strap's motion is at least four times the night's resting level. Pauses up to 1 minute stay one bout.")
    static let limits = r("zoop.sleep.restless.limits",
        "Wrist movement is not sleep quality: a partner can move the bed, and a busy mind can lie still.")
    static let lowReason = r("zoop.sleep.restless.lowReason",
        "This night has little motion data, common on WHOOP 4.0. Gaps count as still, so the values are uncertain.")
}
