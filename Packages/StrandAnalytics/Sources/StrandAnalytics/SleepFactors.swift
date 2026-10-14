import Foundation

// MARK: - Sleep factors (Zoop)
//
// A one-word verdict per contributor to a night: duration, deep, REM, efficiency, consistency and
// wake-ups. Each verdict is read from numbers the Sleep screen already computes, against the
// wearer's own baseline where one exists and a broad population floor where it does not.
//
// These are presentation bands, not clinical thresholds. They exist to answer "which part of the
// night was the weak one", so they are deliberately coarse (three steps) and every one is pinned by
// a test in `SleepFactorsTests`.

public enum SleepFactors {

    /// The three-step verdict a factor cell shows.
    public enum Verdict: Int, Comparable, Sendable {
        case poor, fair, good
        public static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Factor: String, CaseIterable, Sendable {
        case duration, deep, rem, efficiency, consistency, wakeUps
    }

    /// One evaluated factor: its verdict and a 0...1 fill for the cell's thin bar.
    public struct Result: Equatable, Sendable {
        public let factor: Factor
        public let verdict: Verdict
        public let progress: Double
        public init(factor: Factor, verdict: Verdict, progress: Double) {
            self.factor = factor
            self.verdict = verdict
            self.progress = Swift.max(0, Swift.min(1, progress))
        }
    }

    /// Everything the grid reads for one night. Any nil input drops that factor rather than guessing.
    public struct Inputs: Equatable, Sendable {
        public var hoursVsNeededPct: Double?
        public var asleepMin: Double?
        public var deepMin: Double?
        public var remMin: Double?
        public var typicalDeepMin: Double?
        public var typicalRemMin: Double?
        public var efficiencyPct: Double?
        public var consistencyPct: Double?
        public var wakeUps: Double?
        public var typicalWakeUps: Double?

        public init(hoursVsNeededPct: Double? = nil, asleepMin: Double? = nil,
                    deepMin: Double? = nil, remMin: Double? = nil,
                    typicalDeepMin: Double? = nil, typicalRemMin: Double? = nil,
                    efficiencyPct: Double? = nil, consistencyPct: Double? = nil,
                    wakeUps: Double? = nil, typicalWakeUps: Double? = nil) {
            self.hoursVsNeededPct = hoursVsNeededPct
            self.asleepMin = asleepMin
            self.deepMin = deepMin
            self.remMin = remMin
            self.typicalDeepMin = typicalDeepMin
            self.typicalRemMin = typicalRemMin
            self.efficiencyPct = efficiencyPct
            self.consistencyPct = consistencyPct
            self.wakeUps = wakeUps
            self.typicalWakeUps = typicalWakeUps
        }
    }

    // MARK: Bands

    /// Asleep as a share of need: good from 90 %, fair from 75 %.
    public static let durationGoodPct = 90.0
    public static let durationFairPct = 75.0
    /// Efficiency: good from 85 % (the common sleep-medicine floor), fair from 75 %.
    public static let efficiencyGoodPct = 85.0
    public static let efficiencyFairPct = 75.0
    /// Bedtime-consistency score: good from 75, fair from 55.
    public static let consistencyGoodPct = 75.0
    public static let consistencyFairPct = 55.0
    /// A stage reaching this fraction of its personal mean counts as good / fair.
    public static let stageGoodRatio = 0.9
    public static let stageFairRatio = 0.7
    /// Population share-of-asleep floors, used alone when there is no personal mean yet and as a
    /// floor beside it, so a person whose own mean is low is not called "good" for matching it.
    public static let deepGoodShare = 0.16
    public static let deepFairShare = 0.10
    public static let remGoodShare = 0.21
    public static let remFairShare = 0.15
    /// A personal stage mean shorter than this is too thin to compare against.
    public static let minTypicalStageMin = 10.0

    // MARK: Per-factor verdicts

    public static func duration(hoursVsNeededPct pct: Double) -> Result {
        Result(factor: .duration, verdict: band(pct, good: durationGoodPct, fair: durationFairPct),
               progress: pct / 100)
    }

    public static func efficiency(pct: Double) -> Result {
        Result(factor: .efficiency, verdict: band(pct, good: efficiencyGoodPct, fair: efficiencyFairPct),
               progress: pct / 100)
    }

    public static func consistency(pct: Double) -> Result {
        Result(factor: .consistency, verdict: band(pct, good: consistencyGoodPct, fair: consistencyFairPct),
               progress: pct / 100)
    }

    /// A stage's verdict. With a personal mean the night must reach 90 % of it AND the share floor
    /// for "good" to be earned the easy way; either one reaching its band is enough, so a long night
    /// with a normal share is not penalised for missing a high personal mean, and vice versa.
    public static func stage(_ factor: Factor, minutes: Double, asleepMin: Double,
                             typicalMin: Double?) -> Result? {
        guard asleepMin > 0, minutes >= 0 else { return nil }
        let (goodShare, fairShare) = factor == .deep ? (deepGoodShare, deepFairShare) : (remGoodShare, remFairShare)
        let share = minutes / asleepMin
        let shareVerdict = band(share, good: goodShare, fair: fairShare)
        guard let typical = typicalMin, typical >= minTypicalStageMin else {
            return Result(factor: factor, verdict: shareVerdict, progress: share / goodShare)
        }
        let ratio = minutes / typical
        let ratioVerdict = band(ratio, good: stageGoodRatio, fair: stageFairRatio)
        return Result(factor: factor, verdict: Swift.max(ratioVerdict, shareVerdict), progress: ratio)
    }

    /// Wake-ups: lower is better. Good at or under the personal mean (or two, whichever is higher),
    /// fair up to one and a half times it (or four), poor beyond.
    public static func wakeUps(count: Double, typical: Double?) -> Result {
        let base = typical.map { Swift.max(0, $0) }
        let goodCeiling = Swift.max(2, base ?? 2)
        let fairCeiling = Swift.max(4, (base ?? 0) * 1.5)
        let verdict: Verdict = count <= goodCeiling ? .good : (count <= fairCeiling ? .fair : .poor)
        let scale = Swift.max(fairCeiling * 1.5, 1)
        return Result(factor: .wakeUps, verdict: verdict, progress: 1 - count / scale)
    }

    /// Every factor the inputs can support, in display order.
    public static func evaluate(_ i: Inputs) -> [Result] {
        var out: [Result] = []
        if let p = i.hoursVsNeededPct, p.isFinite { out.append(duration(hoursVsNeededPct: p)) }
        if let a = i.asleepMin, let d = i.deepMin, let r = stage(.deep, minutes: d, asleepMin: a, typicalMin: i.typicalDeepMin) {
            out.append(r)
        }
        if let a = i.asleepMin, let m = i.remMin, let r = stage(.rem, minutes: m, asleepMin: a, typicalMin: i.typicalRemMin) {
            out.append(r)
        }
        if let e = i.efficiencyPct, e.isFinite { out.append(efficiency(pct: e)) }
        if let c = i.consistencyPct, c.isFinite { out.append(consistency(pct: c)) }
        if let w = i.wakeUps, w.isFinite, w >= 0 { out.append(wakeUps(count: w, typical: i.typicalWakeUps)) }
        return out
    }

    private static func band(_ v: Double, good: Double, fair: Double) -> Verdict {
        v >= good ? .good : (v >= fair ? .fair : .poor)
    }
}
