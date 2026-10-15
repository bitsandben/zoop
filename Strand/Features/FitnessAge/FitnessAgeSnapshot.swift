#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// What the card and the screen show: the stored weekly fitness ages and the latest week's breakdown.
/// `IntelligenceEngine.fitnessAgeRows` writes both, so the card, the dial and the factor rows can only
/// ever show one computation.
struct FitnessAgeSnapshot {
    var history: [(day: String, value: Double)] = []
    /// Weighted years per factor for the latest week (positive = older).
    var contributions: [FitnessAgeFactor: Double] = [:]
    /// Input values for the latest week, by stored key.
    var inputs: [String: Double] = [:]

    var latest: (day: String, value: Double)? { history.last }

    /// True when the latest VO₂max was measured (Apple Health) rather than the waist-based estimate.
    var vo2IsMeasured: Bool { inputs[FitnessAgeKeys.vo2Measured] == 1 }

    static func load(repo: Repository) async -> FitnessAgeSnapshot {
        var snap = FitnessAgeSnapshot()
        snap.history = await repo.exploreSeries(key: "fitness_age", source: "my-whoop", days: 400)
        guard let day = snap.history.last?.day else { return snap }
        for f in FitnessAgeFactor.allCases {
            if let v = await value(repo, f.contributionKey, day) { snap.contributions[f] = v }
        }
        let inputKeys = FitnessAgeFactor.allCases.map(\.inputKey)
            + [FitnessAgeKeys.vo2Measured, FitnessAgeKeys.bodyFat, FitnessAgeKeys.bmi]
        for k in inputKeys {
            if let v = await value(repo, k, day) { snap.inputs[k] = v }
        }
        return snap
    }

    private static func value(_ repo: Repository, _ key: String, _ day: String) async -> Double? {
        await repo.exploreSeries(key: key, source: "my-whoop", days: 400).first { $0.day == day }?.value
    }

    /// The engine inputs of the latest week, so the lever model re-runs the very blend that made the
    /// headline. nil without a resting-HR baseline (the engine's one hard requirement).
    func engineInputs(age: Int, sex: String) -> FitnessAgeInputs? {
        guard let rhr = inputs[FitnessAgeFactor.restingHR.inputKey], rhr > 0, age > 0 else { return nil }
        return FitnessAgeInputs(
            chronoAge: Double(age), sex: sex, restingHR: rhr,
            vo2max: inputs[FitnessAgeFactor.vo2max.inputKey],
            vo2Source: vo2IsMeasured ? .measured : .nesEstimate,
            rmssd: inputs[FitnessAgeFactor.hrv.inputKey],
            activityIndex: inputs[FitnessAgeFactor.activity.inputKey],
            bmi: inputs[FitnessAgeKeys.bmi], bodyFatPct: inputs[FitnessAgeKeys.bodyFat],
            sleepConsistency: inputs[FitnessAgeFactor.sleep.inputKey])
    }
}
#endif
