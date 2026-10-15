import Foundation

// MARK: - Per-exercise progression
//
// Double progression from the logged sets, no model involved: two sessions in a row with every target
// rep done at RPE ≤ 8 earn a step up (weight for loaded lifts, a rep or a harder variant for bodyweight
// and band work); two missed sessions earn a deload; anything else holds. Progression starts from what
// was actually lifted last time, so it needs no stored state and cannot run away from the log.

public enum LiftProgression {

    public struct Target: Equatable, Sendable {
        public var sets: Int
        public var repsLow: Int?
        public var repsHigh: Int?
        public var weightKg: Double?
        public init(sets: Int, repsLow: Int?, repsHigh: Int?, weightKg: Double?) {
            self.sets = sets
            self.repsLow = repsLow
            self.repsHigh = repsHigh
            self.weightKg = weightKg
        }
    }

    /// One working set as logged.
    public struct Performed: Equatable, Sendable {
        public let reps: Int?
        public let weightKg: Double?
        public let rpe: Double?
        public init(reps: Int?, weightKg: Double?, rpe: Double?) {
            self.reps = reps
            self.weightKg = weightKg
            self.rpe = rpe
        }
    }

    public enum Step: Equatable, Sendable {
        case addWeight(from: Double, to: Double)
        case addReps(to: Int)
        /// Bodyweight / band work at 20+ reps: next band level or harder variant, reps back down.
        case harderVariant(repsTo: Int)
        case hold
        case deload(from: Double, to: Double)
    }

    public struct Advice: Equatable, Sendable {
        public let step: Step
        public let next: Target
    }

    public static let rpeCeiling = 8.0
    public static let failRpe = 9.5
    public static let bodyweightRepCap = 20

    /// - Parameters:
    ///   - sessions: working sets per session for this exercise, most recent LAST.
    ///   - lowerBody: legs progress in bigger weight steps.
    /// - Returns: nil without history or without a rep target.
    public static func advise(target: Target, sessions: [[Performed]], lowerBody: Bool) -> Advice? {
        guard let last = sessions.last, !last.isEmpty,
              let goal = target.repsHigh ?? target.repsLow else { return nil }
        let floor = target.repsLow ?? goal
        let lastWeight = last.compactMap(\.weightKg).max().flatMap { $0 > 0 ? $0 : nil }
        let recent = sessions.suffix(2)

        func hit(_ sets: [Performed]) -> Bool {
            sets.count >= target.sets && sets.allSatisfy { ($0.reps ?? 0) >= goal && ($0.rpe ?? 0) <= rpeCeiling }
        }
        func missed(_ sets: [Performed]) -> Bool {
            let short = sets.filter { ($0.reps ?? 0) < floor }.count
            return short * 2 >= max(1, target.sets) || sets.contains { ($0.rpe ?? 0) >= failRpe }
        }

        var next = target
        next.weightKg = lastWeight ?? target.weightKg
        if recent.count == 2 && recent.allSatisfy(hit) {
            if let w = lastWeight {
                let to = roundPlate(w + increment(for: w, lowerBody: lowerBody))
                next.weightKg = to
                next.repsLow = target.repsLow
                return Advice(step: .addWeight(from: w, to: to), next: next)
            }
            if goal < bodyweightRepCap {
                next.repsLow = target.repsLow.map { $0 + 1 }
                next.repsHigh = target.repsHigh.map { $0 + 1 }
                if next.repsLow == nil && next.repsHigh == nil { next.repsLow = goal + 1 }
                return Advice(step: .addReps(to: goal + 1), next: next)
            }
            let reset = max(6, (target.repsLow ?? goal) / 2)
            next.repsLow = reset
            next.repsHigh = target.repsHigh.map { _ in reset + 2 }
            return Advice(step: .harderVariant(repsTo: reset), next: next)
        }
        if recent.count == 2 && recent.allSatisfy(missed), let w = lastWeight {
            let to = roundPlate(w * 0.9)
            if to < w {
                next.weightKg = to
                return Advice(step: .deload(from: w, to: to), next: next)
            }
        }
        return Advice(step: .hold, next: next)
    }

    static func increment(for weight: Double, lowerBody: Bool) -> Double {
        if weight < 10 { return 1 }
        if weight < 20 { return lowerBody ? 2.5 : 1.25 }
        return lowerBody ? 5 : 2.5
    }

    /// Nearest 1.25 kg (a pair of the smallest common plates).
    static func roundPlate(_ kg: Double) -> Double { (kg / 1.25).rounded() * 1.25 }

    // MARK: Muscle recovery

    public enum RecoveryAction: Equatable, Sendable {
        case keep
        /// One set fewer today.
        case reduceSet
        case skip
    }

    public static let recoveredThreshold = 50

    /// Today's action per routine line from the recovery of its primary muscle group. Lines under the
    /// threshold are skipped, least recovered first, but never more than half the routine: the rest of
    /// the under-recovered lines lose one set instead.
    public static func recoveryActions(groups: [MuscleLoad.Group?], recovered: [MuscleLoad.Group: Int]) -> [RecoveryAction] {
        var actions = Array(repeating: RecoveryAction.keep, count: groups.count)
        let tired = groups.enumerated().compactMap { index, group -> (Int, Int)? in
            guard let group, let pct = recovered[group], pct < recoveredThreshold else { return nil }
            return (index, pct)
        }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        let maxSkips = groups.count / 2
        for (n, entry) in tired.enumerated() {
            actions[entry.0] = n < maxSkips ? .skip : .reduceSet
        }
        return actions
    }
}
