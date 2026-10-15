import Foundation

// MARK: - RecoveryFactors
//
// "What set this morning's recovery?" as a short ranked list. Each factor carries the observed deviation
// (yesterday's strain against the user's average, sleep against need, bedtime against the usual, HRV and
// resting HR against baseline, a logged journal answer, an illness signal) and, where the user's own
// history can size it, the estimated effect on recovery in points:
//
// - strain:  `BodyInsights.strainSensitivity` slope (points per 10 effort) × yesterday's distance from the
//            average. Association from the user's own days, not a causal model.
// - sleep, HRV, resting HR: the scorer's own driver points (`RecoveryScorer.chargeDrivers`), passed in, so
//            a line can never claim an effect the score did not feel.
// - bedtime: least-squares slope of recovery on bedtime lateness over the user's history.
// - logged:  mean recovery with vs without the answer, only when `BehaviorInsights` calls it significant.
//
// Factors overlap (a hard day also lowers HRV), so the points are not additive; the screen says so.
// Ranking: an illness signal first, then sized factors by |points|, then unsized ones.

public enum RecoveryFactors {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case illness, strain, sleep, bedtime, hrv, restingHR, logged
    }

    public struct Factor: Equatable, Sendable {
        public let kind: Kind
        /// Estimated effect on this morning's recovery in points (negative lowers); nil when unsized.
        public let points: Double?
        /// What was observed, per kind: strain % vs average · sleep minutes vs need · bedtime minutes later
        /// than usual · HRV % vs baseline · resting HR bpm vs baseline · illness signal count · logged 0.
        public let deviation: Double
        /// The journal question, for `.logged`.
        public let question: String?

        public init(kind: Kind, points: Double?, deviation: Double, question: String? = nil) {
            self.kind = kind
            self.points = points
            self.deviation = deviation
            self.question = question
        }

        /// Whether this factor pulled recovery down: an illness signal always, otherwise by its points.
        public var lowers: Bool { kind == .illness || (points ?? 0) < 0 }
    }

    /// A journal answer logged for the night behind this morning, with its personal effect if any.
    public struct Logged: Equatable, Sendable {
        public let question: String
        public let effect: BehaviorEffect?
        public init(question: String, effect: BehaviorEffect?) {
            self.question = question
            self.effect = effect
        }
    }

    public struct Input: Equatable, Sendable {
        public var strainYesterday: Double?
        public var strainAverage: Double?
        /// `BodyInsights.StrainSensitivity.pointsPer10`.
        public var strainPointsPer10: Double?
        public var sleepMinutesVsNeed: Double?
        public var sleepPoints: Double?
        public var bedtimeLateMinutes: Double?
        public var bedtimePointsPerHour: Double?
        public var hrvPercent: Double?
        public var hrvPoints: Double?
        public var restingHRDelta: Double?
        public var restingHRPoints: Double?
        public var logged: [Logged]
        public var illnessSignals: Int

        public init(strainYesterday: Double? = nil, strainAverage: Double? = nil, strainPointsPer10: Double? = nil,
                    sleepMinutesVsNeed: Double? = nil, sleepPoints: Double? = nil,
                    bedtimeLateMinutes: Double? = nil, bedtimePointsPerHour: Double? = nil,
                    hrvPercent: Double? = nil, hrvPoints: Double? = nil,
                    restingHRDelta: Double? = nil, restingHRPoints: Double? = nil,
                    logged: [Logged] = [], illnessSignals: Int = 0) {
            self.strainYesterday = strainYesterday
            self.strainAverage = strainAverage
            self.strainPointsPer10 = strainPointsPer10
            self.sleepMinutesVsNeed = sleepMinutesVsNeed
            self.sleepPoints = sleepPoints
            self.bedtimeLateMinutes = bedtimeLateMinutes
            self.bedtimePointsPerHour = bedtimePointsPerHour
            self.hrvPercent = hrvPercent
            self.hrvPoints = hrvPoints
            self.restingHRDelta = restingHRDelta
            self.restingHRPoints = restingHRPoints
            self.logged = logged
            self.illnessSignals = illnessSignals
        }
    }

    /// One concrete next step, picked from the strongest factor that lowered recovery.
    public enum Advice: String, Equatable, Sendable {
        case rest, lightDay, earlierBed, usualBedtime, calmDay, skipLogged
    }

    // MARK: Thresholds

    /// A day counts as harder or easier than usual at 25 % from the average.
    public static let strainMinPercent: Double = 25
    /// A bedtime this much later than usual is worth naming.
    public static let bedtimeMinLateMinutes: Double = 45
    /// Below this many points a scorer input moved the score too little to name.
    public static let minPoints: Double = 2
    /// The illness engine's corroboration rule: two signals out of range on one night.
    public static let minIllnessSignals = 2
    public static let maxFactors = 4

    // MARK: Ranking

    public static func rank(_ input: Input, limit: Int = maxFactors) -> [Factor] {
        var out: [Factor] = []
        if input.illnessSignals >= minIllnessSignals {
            out.append(Factor(kind: .illness, points: nil, deviation: Double(input.illnessSignals)))
        }
        if let y = input.strainYesterday, let avg = input.strainAverage, avg > 0 {
            let pct = (y - avg) / avg * 100
            if abs(pct) >= strainMinPercent {
                let points = input.strainPointsPer10.map { $0 * (y - avg) / 10 }
                out.append(Factor(kind: .strain, points: points, deviation: pct))
            }
        }
        if let minutes = input.sleepMinutesVsNeed, let p = input.sleepPoints, abs(p) >= minPoints {
            out.append(Factor(kind: .sleep, points: p, deviation: minutes))
        }
        if let late = input.bedtimeLateMinutes, late >= bedtimeMinLateMinutes {
            let points = input.bedtimePointsPerHour.map { $0 * late / 60 }
            out.append(Factor(kind: .bedtime, points: points, deviation: late))
        }
        if let pct = input.hrvPercent, let p = input.hrvPoints, abs(p) >= minPoints {
            out.append(Factor(kind: .hrv, points: p, deviation: pct))
        }
        if let delta = input.restingHRDelta, let p = input.restingHRPoints, abs(p) >= minPoints {
            out.append(Factor(kind: .restingHR, points: p, deviation: delta))
        }
        for item in input.logged {
            let points = item.effect.flatMap { $0.significant ? $0.delta : nil }
            out.append(Factor(kind: .logged, points: points, deviation: 0, question: item.question))
        }
        return Array(sorted(out).prefix(limit))
    }

    /// Illness first, then sized factors by |points| (larger first), then unsized ones in input order.
    static func sorted(_ factors: [Factor]) -> [Factor] {
        func tier(_ f: Factor) -> Int { f.kind == .illness ? 0 : (f.points == nil ? 2 : 1) }
        return factors.enumerated().sorted { a, b in
            let ta = tier(a.element), tb = tier(b.element)
            if ta != tb { return ta < tb }
            let pa = abs(a.element.points ?? 0), pb = abs(b.element.points ?? 0)
            if pa != pb { return pa > pb }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func advice(_ factors: [Factor]) -> Advice? {
        guard let top = factors.first(where: \.lowers) else { return nil }
        switch top.kind {
        case .illness: return .rest
        case .strain: return .lightDay
        case .sleep: return .earlierBed
        case .bedtime: return .usualBedtime
        case .hrv, .restingHR: return .calmDay
        case .logged: return .skipLogged
        }
    }

    // MARK: Inputs from history

    /// Pairs needed before a slope is trusted, matching `BodyInsights.strainSensitivity`.
    public static let minPairs = 21

    /// Mean of the last 28 days of effort before yesterday; nil with fewer than 7 such days.
    public static func strainAverage(_ prior: [Double]) -> Double? {
        let recent = prior.suffix(28).filter(\.isFinite)
        guard recent.count >= 7 else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }

    /// Minutes the last bedtime fell after the usual one (median of the earlier nights). Clock minutes are
    /// measured from noon so 23:30 and 00:30 sit an hour apart, not 23 hours. Nil with fewer than 7 nights.
    public static func bedtimeLateness(lastMinuteOfDay: Int, earlierMinutesOfDay: [Int]) -> Double? {
        guard earlierMinutesOfDay.count >= 7 else { return nil }
        let usual = SleepRestlessness.median(earlierMinutesOfDay.map { Double(fromNoonMinutes($0)) })
        return Double(fromNoonMinutes(lastMinuteOfDay)) - usual
    }

    /// Clock minutes counted from noon, so a bedtime either side of midnight stays continuous.
    public static func fromNoonMinutes(_ minuteOfDay: Int) -> Int { ((minuteOfDay + 720) % 1440 + 1440) % 1440 }

    /// Recovery points per hour of later bedtime from (lateness minutes, that morning's recovery) pairs.
    /// Nil with fewer than `minPairs` pairs or bedtimes that barely vary (SD under 15 minutes).
    public static func bedtimePointsPerHour(_ pairs: [(lateMinutes: Double, recovery: Double)]) -> Double? {
        guard pairs.count >= minPairs else { return nil }
        let xs = pairs.map(\.lateMinutes), ys = pairs.map(\.recovery)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxx = 0.0, sxy = 0.0
        for i in xs.indices {
            sxx += (xs[i] - mx) * (xs[i] - mx)
            sxy += (xs[i] - mx) * (ys[i] - my)
        }
        let sd = (sxx / Double(xs.count - 1)).squareRoot()
        guard sd >= 15 else { return nil }
        return sxy / sxx * 60
    }
}
