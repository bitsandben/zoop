import Foundation
import WhoopProtocol

/// How the body behaves after a workout: HR recovery in the first minutes, time back to near resting and
/// afterburn over the next hours, and next-morning HRV / resting HR / Recovery against baseline.
///
/// Pure. The caller passes raw HR from shortly before the end to three hours after, the daily readings of the
/// 30 days up to the workout day, and the next morning's reading. Missing data yields nil, never interpolation.
/// HRR1/HRR2 come from `HeartRateRecovery` unchanged, so its intensity eligibility (#516) applies.
public enum PostWorkoutRecovery {

    /// One day's morning figures (resting HR, HRV, Recovery); any may be missing.
    public struct DayReading: Equatable, Sendable {
        public let restingHr: Double?
        public let hrv: Double?
        public let recovery: Double?

        public init(restingHr: Double?, hrv: Double?, recovery: Double?) {
            self.restingHr = restingHr
            self.hrv = hrv
            self.recovery = recovery
        }
    }

    /// One morning metric against its 30-day mean.
    public struct Delta: Equatable, Sendable {
        public let value: Double
        public let baseline: Double
        public var delta: Double { value - baseline }
    }

    public struct MorningImpact: Equatable, Sendable {
        public let hrv: Delta?
        public let restingHr: Delta?
        public let recovery: Delta?
        public var isEmpty: Bool { hrv == nil && restingHr == nil && recovery == nil }
    }

    /// Mean HR of one minute after the workout end (minute 0 = first 60 s).
    public struct MinutePoint: Equatable, Sendable {
        public let minute: Int
        public let bpm: Double
    }

    public enum Verdict: String, Equatable, Sendable {
        case fast, normal, slow
    }

    public struct Result: Equatable, Sendable {
        public let hrr: HeartRateRecovery.Result?
        public var hrr1: Int? { hrr?.after1Minute }
        public var hrr2: Int? { hrr?.after2Minutes }
        /// Resting HR baseline (30-day mean); nil = too little history.
        public let restingBaseline: Double?
        /// Minutes after the end until HR stayed near resting for `nearRestingHoldMinutes`; nil = not reached or no baseline.
        public let minutesToNearResting: Int?
        /// Mean HR in the afterburn window (1-3 h after the end).
        public let afterburnAvg: Double?
        /// Per-minute curve for the three hours after the end (minutes with data only).
        public let curve: [MinutePoint]
        public let morning: MorningImpact?
        public let verdict: Verdict?

        public var afterburnDelta: Double? {
            guard let avg = afterburnAvg, let rest = restingBaseline else { return nil }
            return avg - rest
        }

        public var hasAnything: Bool {
            hrr1 != nil || hrr2 != nil || minutesToNearResting != nil || afterburnAvg != nil
                || curve.count >= minimumCurvePoints || morning != nil
        }
    }

    public enum TrendKind: Equatable, Sendable { case faster, usual, slower }
    public struct Trend: Equatable, Sendable {
        public let kind: TrendKind
        /// This workout's HRR1 minus the rounded mean of recent HRR1s (bpm; positive = faster).
        public let delta: Int
    }

    // MARK: - Thresholds

    /// Observation window after the workout end.
    public static let windowMinutes = 180
    /// "Near resting" = within this many bpm of the resting baseline; the baseline is SLEEP resting HR and awake sitting HR runs 10-15 bpm higher, so a tighter margin is rarely met.
    public static let nearRestingMarginBpm = 15.0
    /// HR must stay near resting this many consecutive minutes (gaps break the run).
    public static let nearRestingHoldMinutes = 5
    /// A minute bucket needs this many samples (guards a single optical spike).
    public static let minimumSamplesPerMinute = 3
    /// Afterburn window: minutes 60..<180 after the end.
    public static let afterburnStartMinute = 60
    /// The afterburn mean needs at least this many minutes with data.
    public static let minimumAfterburnMinutes = 20
    /// Minutes with data needed before the curve is worth drawing.
    public static let minimumCurvePoints = 10
    /// A 30-day morning-metric mean needs at least this many days.
    public static let minimumBaselineDays = 7
    /// Verdict from HRR1 (first-minute bpm drop): <= 12 is the classic abnormal cut-off (Cole et al., NEJM 1999); >= 25 is typical of well-trained recovery.
    public static let fastHRR1 = 25
    public static let slowHRR1 = 12
    /// Fallback verdict from time back to near resting when there is no HRR1.
    public static let fastMinutesToResting = 30
    public static let slowMinutesToResting = 90
    /// Trend needs at least this many recent workouts with an HRR1; a |delta| above this counts as different.
    public static let minimumTrendHistory = 3
    public static let usualBandBpm = 2

    // MARK: - Entry point

    /// - Parameters:
    ///   - samples: raw HR from at least `HeartRateRecovery.eligibilityLookbackSeconds` before the end through `windowMinutes` after.
    ///   - now: current time, so a still-open window isn't called slow for lack of data.
    ///   - baselineDays: daily readings of the 30 days up to the workout day.
    ///   - nextMorning: first morning after the workout, nil if not there yet.
    public static func analyze(samples: [HRSample], workoutStart: Int, workoutEnd: Int, maxHR: Double,
                               baselineDays: [DayReading], nextMorning: DayReading?, now: Int) -> Result {
        let hrr = HeartRateRecovery.calculate(samples: samples, workoutStart: workoutStart,
                                              workoutEnd: workoutEnd, maxHR: maxHR)
        let restingValues = baselineDays.compactMap(\.restingHr)
        let resting = restingValues.count >= minimumBaselineDays ? mean(restingValues) : nil
        let curve = minuteCurve(samples: samples, from: workoutEnd, minutes: windowMinutes)
        let toResting = resting.flatMap { minutesToNearResting(curve: curve, resting: $0) }
        let afterburn = afterburnAverage(curve: curve)
        let morning = nextMorning.map { morningImpact(next: $0, baseline: baselineDays) }
        let windowClosed = now >= workoutEnd + windowMinutes * 60
        let v = verdict(hrr1: hrr?.after1Minute, minutesToResting: toResting,
                        windowClosed: windowClosed && resting != nil && curve.count >= minimumAfterburnMinutes)
        return Result(hrr: hrr, restingBaseline: resting, minutesToNearResting: toResting,
                      afterburnAvg: afterburn, curve: curve,
                      morning: (morning?.isEmpty ?? true) ? nil : morning, verdict: v)
    }

    // MARK: - Parts

    /// Per-minute mean HR; minutes with fewer than `minimumSamplesPerMinute` plausible samples are omitted (a gap, not a zero).
    public static func minuteCurve(samples: [HRSample], from: Int, minutes: Int) -> [MinutePoint] {
        var sums = [Int: (sum: Int, n: Int)]()
        let end = from + minutes * 60
        for s in samples where s.ts >= from && s.ts < end && (30...250).contains(s.bpm) {
            let m = (s.ts - from) / 60
            let cur = sums[m] ?? (0, 0)
            sums[m] = (cur.sum + s.bpm, cur.n + 1)
        }
        return sums.keys.sorted().compactMap { m in
            guard let v = sums[m], v.n >= minimumSamplesPerMinute else { return nil }
            return MinutePoint(minute: m, bpm: Double(v.sum) / Double(v.n))
        }
    }

    /// First minute from which HR stays within `nearRestingMarginBpm` of `resting` for `nearRestingHoldMinutes` consecutive minutes with data.
    public static func minutesToNearResting(curve: [MinutePoint], resting: Double) -> Int? {
        let limit = resting + nearRestingMarginBpm
        var runStart: Int?
        var previous: Int?
        for p in curve {
            let contiguous = previous.map { p.minute == $0 + 1 } ?? true
            if p.bpm <= limit {
                if runStart == nil || !contiguous { runStart = p.minute }
                if let start = runStart, p.minute - start + 1 >= nearRestingHoldMinutes { return start }
            } else {
                runStart = nil
            }
            previous = p.minute
        }
        return nil
    }

    /// Mean of the minute buckets in the afterburn window.
    public static func afterburnAverage(curve: [MinutePoint]) -> Double? {
        let window = curve.filter { $0.minute >= afterburnStartMinute && $0.minute < windowMinutes }
        guard window.count >= minimumAfterburnMinutes else { return nil }
        return window.map(\.bpm).reduce(0, +) / Double(window.count)
    }

    /// Next morning's figures against `baseline` means (each metric needs `minimumBaselineDays` values).
    public static func morningImpact(next: DayReading, baseline: [DayReading]) -> MorningImpact {
        func delta(_ value: Double?, _ history: [Double?]) -> Delta? {
            let values = history.compactMap { $0 }
            guard let value, values.count >= minimumBaselineDays, let m = mean(values) else { return nil }
            return Delta(value: value, baseline: m)
        }
        return MorningImpact(hrv: delta(next.hrv, baseline.map(\.hrv)),
                             restingHr: delta(next.restingHr, baseline.map(\.restingHr)),
                             recovery: delta(next.recovery, baseline.map(\.recovery)))
    }

    /// HRR1 decides when present; otherwise time back to near resting, where "not reached" counts as slow only once the window has closed with enough data.
    public static func verdict(hrr1: Int?, minutesToResting: Int?, windowClosed: Bool) -> Verdict? {
        if let hrr1 {
            if hrr1 >= fastHRR1 { return .fast }
            if hrr1 <= slowHRR1 { return .slow }
            return .normal
        }
        if let m = minutesToResting {
            if m <= fastMinutesToResting { return .fast }
            if m > slowMinutesToResting { return .slow }
            return .normal
        }
        return windowClosed ? .slow : nil
    }

    /// This workout's HRR1 against recent workouts'; nil with fewer than `minimumTrendHistory`.
    public static func trend(currentHRR1: Int, recentHRR1: [Int]) -> Trend? {
        guard recentHRR1.count >= minimumTrendHistory else { return nil }
        let usual = Int((Double(recentHRR1.reduce(0, +)) / Double(recentHRR1.count)).rounded())
        let delta = currentHRR1 - usual
        let kind: TrendKind = delta > usualBandBpm ? .faster : (delta < -usualBandBpm ? .slower : .usual)
        return Trend(kind: kind, delta: delta)
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
