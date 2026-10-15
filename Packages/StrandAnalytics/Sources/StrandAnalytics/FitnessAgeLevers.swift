import Foundation

// FitnessAgeLevers.swift - "which single change would lower the fitness age most?".
//
// Re-runs the same blend as `FitnessAgeEngine` with one input nudged by a realistic step, so there
// is no second formula to drift from the headline. Steps are round numbers a few weeks of consistent
// effort can plausibly move, not predictions. Levers overlap (training lifts VO2max and lowers
// resting HR together), so the years are not additive: word them as "the biggest single lever".

public struct FitnessAgeLever: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case aerobicFitness, restingHeartRate, activity, sleepRegularity, bodyComposition
    }

    public let kind: Kind
    /// Years the fitness age would drop if only this input moved by `step` (always > 0).
    public let yearsSaved: Double
    public let step: Double
}

public enum FitnessAgeLevers {

    /// The smallest saving worth naming; below this the model is within its own rounding.
    public static let minimumYears = 0.1

    static let vo2Step = 2.0, rhrStep = 3.0, activityStep = 2.0, sleepStep = 0.10
    static let bodyFatStep = 2.0, bmiStep = 2.0

    /// Levers that lower the fitness age by at least `minimumYears`, biggest first.
    public static func rank(_ x: FitnessAgeInputs) -> [FitnessAgeLever] {
        guard let base = FitnessAgeEngine.compute(x) else { return [] }
        let baseOffset = base.contributions.values.reduce(0, +)

        func lever(_ kind: FitnessAgeLever.Kind, step: Double, _ change: (inout FitnessAgeInputs) -> Bool)
            -> FitnessAgeLever? {
            var moved = x
            guard change(&moved), let result = FitnessAgeEngine.compute(moved) else { return nil }
            // Compare offsets, not displayed ages: those are rounded and clamped to +/-15 years, hiding a
            // lever for someone already on a bound.
            let saved = baseOffset - result.contributions.values.reduce(0, +)
            return saved >= minimumYears ? FitnessAgeLever(kind: kind, yearsSaved: saved, step: step) : nil
        }

        let all: [FitnessAgeLever?] = [
            lever(.aerobicFitness, step: vo2Step) { i in
                guard let v = i.vo2max else { return false }
                i.vo2max = v + vo2Step; return true
            },
            lever(.restingHeartRate, step: rhrStep) { i in i.restingHR -= rhrStep; return i.restingHR > 0 },
            lever(.activity, step: activityStep) { i in
                guard let a = i.activityIndex else { return false }
                i.activityIndex = min(15, a + activityStep); return true
            },
            lever(.sleepRegularity, step: sleepStep) { i in
                guard let c = i.sleepConsistency else { return false }
                i.sleepConsistency = min(1, c + sleepStep); return true
            },
            lever(.bodyComposition, step: bodyComposition(x)) { i in
                if let bf = i.bodyFatPct, bf > 0 { i.bodyFatPct = bf - bodyFatStep; return true }
                guard let b = i.bmi, b > 25 else { return false }   // under 18.5 is not a lever to push
                i.bmi = b - bmiStep; return true
            },
        ]
        return all.compactMap { $0 }.sorted { $0.yearsSaved > $1.yearsSaved }
    }

    /// The body lever's step: body-fat points when measured, else BMI units.
    private static func bodyComposition(_ x: FitnessAgeInputs) -> Double {
        (x.bodyFatPct ?? 0) > 0 ? bodyFatStep : bmiStep
    }
}
