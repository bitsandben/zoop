import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Contributors
//
// The rows under "What shaped it". Direction and order come from `RecoveryScorer.chargeDrivers` (via
// `ChargeBreakdownWiring`, the same wiring the Home sheet used), so a row can never claim an effect the
// score did not feel. The measured value, the personal range and the verdict word come from the same
// baselines, so every row reads against the user's own normal.

enum RecoveryContributors {

    static func build(row: DailyMetric, baselines: ChargeBaselines.Resolved, input: RecoveryInput) -> [RecoveryContributor] {
        guard let breakdown = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row, charge: input.scoring)
        else { return [] }
        let driven: [(kind: RecoveryContributor.Kind, points: Int)] = breakdown.drivers.compactMap { driver in
            kind(forDriver: driver.label).map { ($0, driver.deltaPoints) }
        }
        let totalWeight = driven.reduce(0.0) { $0 + input.scoring.weights.weight(term($1.kind)) }
        return driven.compactMap { entry in
            guard let reading = reading(entry.kind, row: row, baselines: baselines, scoring: input.scoring) else { return nil }
            let readout = MetricReadout(
                id: id(entry.kind), label: RecoveryStrings.label(entry.kind),
                value: reading.value, unit: reading.unit, typicalRange: reading.range,
                delta: reading.delta, verdict: reading.verdict,
                meaning: RecoveryStrings.meaning(entry.kind, reading.verdict),
                confidence: reading.confidence)
            let share = totalWeight > 0
                ? Int((100 * input.scoring.weights.weight(term(entry.kind)) / totalWeight).rounded()) : 0
            let trend = series(entry.kind, input: input)
            return RecoveryContributor(
                kind: entry.kind, readout: readout, effect: effect(entry.points),
                explanation: RecoveryExplanations.contributor(
                    kind: entry.kind, share: share, nights: reading.nights, trend: trend,
                    window: trend.first.flatMap { first in trend.last.map { DateInterval(start: first.date, end: $0.date) } }))
        }
    }

    // MARK: Mapping

    /// The engine's English driver labels are its stable keys (also the Android twin's); the check-in
    /// symptoms driver has no row here because the personalisation card owns that story.
    private static func kind(forDriver label: String) -> RecoveryContributor.Kind? {
        switch label {
        case "Heart rate variability": return .hrv
        case "Resting heart rate": return .restingHR
        case "Sleep vs need": return .sleep
        case "Respiratory rate": return .respiration
        case "Skin temperature": return .skinTemperature
        default: return nil
        }
    }

    private static func term(_ kind: RecoveryContributor.Kind) -> ChargeTerm {
        switch kind {
        case .hrv: return .hrv
        case .restingHR: return .rhr
        case .sleep: return .sleep
        case .respiration: return .resp
        case .skinTemperature: return .skinTemp
        }
    }

    private static func id(_ kind: RecoveryContributor.Kind) -> MetricID {
        switch kind {
        case .hrv: return .hrv
        case .restingHR: return .restingHeartRate
        case .sleep: return .sleepScore
        case .respiration: return .respiratoryRate
        case .skinTemperature: return .skinTemperature
        }
    }

    /// One whole point is the smallest difference the headline can show, so anything under it is no effect.
    private static func effect(_ points: Int) -> MetricExplanation.Contributor.Effect {
        points >= 1 ? .raises : (points <= -1 ? .lowers : .neutral)
    }

    // MARK: Readings

    private struct Reading {
        let value: Double
        let unit: MetricUnit
        let range: ClosedRange<Double>?
        let delta: Double?
        let verdict: MetricVerdict
        let confidence: MetricReadout.Confidence
        let nights: Int
    }

    private static func reading(_ kind: RecoveryContributor.Kind, row: DailyMetric,
                                baselines: ChargeBaselines.Resolved, scoring: ChargeScoring) -> Reading? {
        switch kind {
        case .hrv:
            return row.avgHrv.map { vital($0, .milliseconds, baselines.hrv) }
        case .restingHR:
            return row.restingHr.map { vital(Double($0), .beatsPerMinute, baselines.restingHR) }
        case .respiration:
            return row.respRateBpm.map { vital($0, .breathsPerMinute, baselines.resp) }
        case .skinTemperature:
            // Already a deviation from the personal baseline, so the range is the engine's own
            // "typical" band around zero and no delta repeats the value.
            return row.skinTempDevC.map { dev in
                let band = RecoveryScorer.skinTempTypicalBandC
                return Reading(value: dev, unit: .temperatureDeviation(UnitPrefs.currentMetricTemperatureSystem()), range: -band...band, delta: nil,
                               verdict: .vital(dev, typicalRange: -band...band), confidence: .solid,
                               nights: baselines.hrv.nValid)
            }
        case .sleep:
            // Asleep time against the user's own need; the scorer treats 85 % as a good night.
            return scoring.sleepTerm(row).map { sufficiency in
                let percent = sufficiency * 100
                let range = (RecoveryScorer.sleepPerfCenter * 100)...100
                return Reading(value: percent, unit: .percent, range: range, delta: nil,
                               verdict: .vital(percent, typicalRange: range), confidence: .solid,
                               nights: baselines.hrv.nValid)
            }
        }
    }

    /// Typical range = baseline ± one SD-equivalent; `spread` is a mean absolute deviation and
    /// 1.253 converts it to a Gaussian sigma (see `BaselineState`).
    private static func vital(_ value: Double, _ unit: MetricUnit, _ baseline: BaselineState) -> Reading {
        let sigma = baseline.spread * 1.253
        let range = (baseline.baseline - sigma)...(baseline.baseline + sigma)
        return Reading(value: value, unit: unit, range: range, delta: value - baseline.baseline,
                       verdict: .vital(value, typicalRange: range),
                       confidence: baseline.trusted ? .solid : .building, nights: baseline.nValid)
    }

    // MARK: Series

    /// The last 30 days of one input, oldest first, for the contributor's explainer chart.
    private static func series(_ kind: RecoveryContributor.Kind, input: RecoveryInput) -> [MetricExplanation.TrendPoint] {
        input.days.suffix(30).compactMap { day in
            guard let date = RecoveryDayKey.date(day.day) else { return nil }
            let value: Double?
            switch kind {
            case .hrv: value = day.avgHrv
            case .restingHR: value = day.restingHr.map(Double.init)
            case .respiration: value = day.respRateBpm
            case .skinTemperature: value = day.skinTempDevC
            case .sleep: value = input.scoring.sleepTerm(day).map { $0 * 100 }
            }
            return value.map { MetricExplanation.TrendPoint(date: date, value: $0) }
        }
    }
}

// MARK: - Day keys

enum RecoveryDayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A stored "yyyy-MM-dd" day key as local midnight.
    static func date(_ key: String) -> Date? { formatter.date(from: key) }

    /// Whole days from `earlier` to `later`; 0 when either key does not parse.
    static func daysBetween(_ earlier: String, _ later: String) -> Int {
        guard let a = date(earlier), let b = date(later) else { return 0 }
        return Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
