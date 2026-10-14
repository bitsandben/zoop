import Foundation
import StrandDesign
import WhoopStore

// MARK: - Workout readouts (metric anatomy for the detail screen)
//
// Builds the `MetricReadout` for a session's Effort and heart rate. "Typical" is the mean +/- one standard
// deviation of the user's OTHER sessions of the same sport, and only exists once there are
// `minimumHistory` of them: a range from two sessions would be noise dressed as a baseline.

enum WorkoutReadouts {

    /// Fewer than this many comparable sessions and no typical range is drawn.
    static let minimumHistory = 4
    /// From this many sessions the range is no longer called provisional.
    static let solidHistory = 8

    // MARK: Effort

    /// - Parameters:
    ///   - strain: the session's stored 0-100 Effort.
    ///   - others: stored Effort of the user's other sessions of this sport.
    static func effort(strain: Double?, others: [Double], scale: EffortScale) -> MetricReadout {
        let label = LocalizedStringResource("zoop.training.detail.effort", defaultValue: "Effort", bundle: .main)
        guard let strain else {
            return MetricReadout(
                id: .strain, label: label, value: nil, unit: .score(fractionDigits: 1),
                verdict: .unavailable(.noData(since: nil)),
                meaning: LocalizedStringResource("zoop.training.detail.effort.none",
                    defaultValue: "No heart rate was recorded, so this session has no Effort.", bundle: .main),
                tint: .strain)
        }
        let band = TrainingEffort.band(forStored: strain)
        let typical = typicalRange(of: others)
        func shown(_ v: Double) -> Double { TrainingEffort.value(v, scale: scale) }
        return MetricReadout(
            id: .strain, label: label, value: shown(strain), unit: .score(fractionDigits: 1),
            typicalRange: typical.map { shown(max(0, $0.lowerBound))...shown($0.upperBound) },
            delta: typical.map { shown(strain - ($0.lowerBound + $0.upperBound) / 2) },
            verdict: .load(band), meaning: effortMeaning(band),
            confidence: others.count >= minimumHistory && others.count < solidHistory ? .building : .solid,
            tint: .strain)
    }

    private static func effortMeaning(_ band: LoadBand) -> LocalizedStringResource {
        switch band {
        case .restorative:
            return LocalizedStringResource("zoop.training.detail.effort.restorative",
                defaultValue: "An easy session. It barely taxed your heart.", bundle: .main)
        case .building:
            return LocalizedStringResource("zoop.training.detail.effort.building",
                defaultValue: "A solid session that builds fitness without draining you.", bundle: .main)
        case .demanding:
            return LocalizedStringResource("zoop.training.detail.effort.demanding",
                defaultValue: "A hard session. Give your body time to recover.", bundle: .main)
        case .overreaching:
            return LocalizedStringResource("zoop.training.detail.effort.overreaching",
                defaultValue: "An all-out session. Plan an easy day next.", bundle: .main)
        }
    }

    // MARK: Heart rate

    /// Nil without a value or without enough history: the tile then shows the plain number instead.
    static func heartRate(id: MetricID, label: LocalizedStringResource, value: Int?, others: [Int]) -> MetricReadout? {
        guard let value, let range = typicalRange(of: others.map(Double.init)) else { return nil }
        let verdict = MetricVerdict.vital(Double(value), typicalRange: range)
        return MetricReadout(
            id: id, label: label, value: Double(value), unit: .beatsPerMinute, typicalRange: range,
            delta: Double(value) - (range.lowerBound + range.upperBound) / 2,
            verdict: verdict, meaning: heartRateMeaning(verdict),
            confidence: others.count < solidHistory ? .building : .solid)
    }

    private static func heartRateMeaning(_ verdict: MetricVerdict) -> LocalizedStringResource {
        switch verdict {
        case .above:
            return LocalizedStringResource("zoop.training.detail.hr.above",
                defaultValue: "Higher than in your usual sessions of this sport.", bundle: .main)
        case .below:
            return LocalizedStringResource("zoop.training.detail.hr.below",
                defaultValue: "Lower than in your usual sessions of this sport.", bundle: .main)
        default:
            return LocalizedStringResource("zoop.training.detail.hr.typical",
                defaultValue: "In line with your usual sessions of this sport.", bundle: .main)
        }
    }

    // MARK: Range

    /// Mean +/- one standard deviation, or nil below `minimumHistory` values.
    static func typicalRange(of values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= minimumHistory else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        // A zero-width band would draw nothing and call every other value "above" or "below".
        return (mean - max(sd, 0.5))...(mean + max(sd, 0.5))
    }
}
