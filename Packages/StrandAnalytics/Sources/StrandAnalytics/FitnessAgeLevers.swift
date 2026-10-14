import Foundation

// FitnessAgeLevers.swift — "which single change would lower the fitness age most?".
//
// WHY A SCENARIO MODEL: the fitness age is a fixed blend of per-factor years (see `FitnessAgeEngine`).
// Re-running that same blend with ONE input nudged by a realistic step gives the model's own answer to
// "what if", with no second formula that could drift from the headline number.
//
// HONESTY: the steps are round numbers a few weeks of consistent effort can plausibly move, not
// predictions. Levers overlap (training lifts VO₂max and lowers resting HR together), so the years are
// NOT additive and the caller words them as "the biggest single lever", never as a plan total.

public struct FitnessAgeLever: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case aerobicFitness, restingHeartRate, activity, sleepRegularity, bodyComposition
    }

    public let kind: Kind
    /// Years the fitness age would drop if only this input moved by `step` (always > 0).
    public let yearsSaved: Double
    /// Size of the nudge in the input's own unit (ml/kg/min, bpm, activity-index points, share 0…1,
    /// body-fat points or BMI units).
    public let step: Double
}

public enum FitnessAgeLevers {

    /// The smallest saving worth naming. Below this the model is within its own rounding.
    public static let minimumYears = 0.1

    /// Nudges per lever, a few weeks of consistent effort. Documented in the file header.
    static let vo2Step = 2.0, rhrStep = 3.0, activityStep = 2.0, sleepStep = 0.10
    static let bodyFatStep = 2.0, bmiStep = 2.0

    /// Levers that would lower the fitness age by at least `minimumYears`, biggest first.
    public static func rank(_ x: FitnessAgeInputs) -> [FitnessAgeLever] {
        guard let base = FitnessAgeEngine.compute(x) else { return [] }
        let baseOffset = base.contributions.values.reduce(0, +)

        func lever(_ kind: FitnessAgeLever.Kind, step: Double, _ change: (inout FitnessAgeInputs) -> Bool)
            -> FitnessAgeLever? {
            var moved = x
            guard change(&moved), let result = FitnessAgeEngine.compute(moved) else { return nil }
            // Offsets, not the displayed ages: those are rounded and clamped to ±15 years of the real
            // age, which would hide a lever on someone already sitting on a bound.
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

    /// The body lever's step: body-fat points when body fat is measured, else BMI units.
    private static func bodyComposition(_ x: FitnessAgeInputs) -> Double {
        (x.bodyFatPct ?? 0) > 0 ? bodyFatStep : bmiStep
    }
}
