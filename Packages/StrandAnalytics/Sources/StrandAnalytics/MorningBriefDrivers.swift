import Foundation

// MARK: - MorningBriefDrivers
//
// Decides what the morning brief explains, and whether the morning is worth a push at all.
//
// The brief answers "why is my recovery what it is today": it names the adverse drivers behind the
// score (a restless night, resting HR or HRV off the personal normal, a short night, a late bedtime, a
// hard yesterday, a logged confounder, an illness signal), each with its own number. A morning where
// nothing crosses a meaningful threshold is not notable: the app then sends no push and shows one quiet
// line instead, because "all good" is not news.
//
// Inputs come from the same resolvers the Recovery and Sleep screens use (`RecoveryFactors`,
// `SleepRestlessness`, the scorer's driver points), so the brief cannot quote a number the screens show
// differently. Notable means at least one of:
//   - an illness signal,
//   - recovery below the personal range (mean ± SD of the last 30 scored days) or in the red band,
//   - a driver past its strong threshold (`strong*` constants; a sized factor costing ≥ 5 points).
// Recovery ABOVE the range never triggers on its own.

public enum MorningBriefDrivers {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case illness, restless, restlessMinutes, restingHR, hrv, sleep, bedtime, strain, logged
    }

    public struct Driver: Equatable, Sendable {
        public let kind: Kind
        /// What was observed, per kind: illness signal count · restless bouts · restless minutes · resting HR bpm above normal
        /// · HRV % vs normal · sleep minutes vs need · bedtime minutes later than usual · strain % vs
        /// average · logged 0.
        public let value: Double
        /// The personal reference where the sentence cites one (typical bouts or minutes), else nil.
        public let typical: Double?
        /// Estimated effect on recovery in points (negative lowers), when the user's history sizes it.
        public let points: Double?
        /// The journal question, for `.logged`.
        public let question: String?
        /// Crosses the notable threshold on its own.
        public let strong: Bool
        /// Ordering weight, roughly on the points scale.
        let severity: Double

        public init(kind: Kind, value: Double, typical: Double? = nil, points: Double? = nil,
                    question: String? = nil, strong: Bool, severity: Double = 0) {
            self.kind = kind
            self.value = value
            self.typical = typical
            self.points = points
            self.question = question
            self.strong = strong
            self.severity = severity
        }
    }

    /// Recovery against the personal range.
    public enum Tone: String, Equatable, Sendable { case below, within, above, unknown }

    public struct Input: Equatable, Sendable {
        public var recovery: Double?
        public var recoveryRange: ClosedRange<Double>?
        /// `RecoveryFactors.rank` output (any limit; the strongest come first).
        public var factors: [RecoveryFactors.Factor] = []
        /// Raw deviations, so a large one counts even when the scorer weighed it lightly.
        public var restingHRDelta: Double?
        public var hrvPercent: Double?
        public var sleepMinutesVsNeed: Double?
        /// Last night's movement bouts and restless minutes, with earlier nights for the personal range.
        public var restlessBouts: Int?
        public var restlessMinutes: Double?
        public var restlessHistoryBouts: [Double] = []
        public var restlessHistoryMinutes: [Double] = []
        /// False when the night's motion coverage was thin (`SleepRestlessness.Confidence.low`).
        public var restlessSolid = true
        public var illness = false

        public init() {}
    }

    public struct Brief: Equatable, Sendable {
        /// Worth a push.
        public let notable: Bool
        public let tone: Tone
        /// Adverse drivers, most telling first, at most `maxDrivers`.
        public let drivers: [Driver]
    }

    // MARK: Thresholds

    public static let maxDrivers = 3
    /// The red band of the readiness scale (`CoachMorningRules.redCutoff`).
    public static let redRecovery: Double = 34
    /// A sized factor costing this many points is notable by itself.
    public static let strongPoints: Double = 5
    /// A sized factor costing this many points is worth naming.
    public static let namePoints: Double = 2
    public static let nameRHRBpm: Double = 3, strongRHRBpm: Double = 5
    public static let nameHRVPercent: Double = -10, strongHRVPercent: Double = -20
    public static let nameSleepMin: Double = -45, strongSleepMin: Double = -90
    /// Restless: SDs above the personal mean (with at least `restlessMinExtraBouts` more bouts than usual).
    public static let nameRestlessZ: Double = 1.0, strongRestlessZ: Double = 1.5
    public static let restlessMinExtraBouts: Double = 2

    // MARK: Evaluation

    public static func evaluate(_ input: Input) -> Brief {
        let tone = tone(input.recovery, input.recoveryRange)
        var drivers: [Driver] = []
        func factor(_ kind: RecoveryFactors.Kind) -> RecoveryFactors.Factor? { input.factors.first { $0.kind == kind } }

        if input.illness || factor(.illness) != nil {
            drivers.append(Driver(kind: .illness, value: factor(.illness)?.deviation ?? 0, strong: true, severity: 100))
        }
        if let d = restless(input) { drivers.append(d) }
        if let d = scorerDriver(.restingHR, raw: input.restingHRDelta ?? factor(.restingHR)?.deviation,
                                points: factor(.restingHR)?.points, name: { $0 >= nameRHRBpm },
                                strong: { $0 >= strongRHRBpm }, weight: { $0 }) { drivers.append(d) }
        if let d = scorerDriver(.hrv, raw: input.hrvPercent ?? factor(.hrv)?.deviation, points: factor(.hrv)?.points,
                                name: { $0 <= nameHRVPercent }, strong: { $0 <= strongHRVPercent },
                                weight: { abs($0) / 4 }) { drivers.append(d) }
        if let d = scorerDriver(.sleep, raw: input.sleepMinutesVsNeed ?? factor(.sleep)?.deviation,
                                points: factor(.sleep)?.points, name: { $0 <= nameSleepMin },
                                strong: { $0 <= strongSleepMin }, weight: { abs($0) / 18 }) { drivers.append(d) }
        if let f = factor(.bedtime), f.deviation > 0, (f.points ?? -1) < 0 {
            drivers.append(sized(.bedtime, f, fallbackSeverity: f.deviation / 30))
        }
        if let f = factor(.strain), f.deviation > 0, let p = f.points, p < 0 {
            drivers.append(sized(.strain, f, fallbackSeverity: 1))
        }
        for f in input.factors where f.kind == .logged && (f.points ?? -1) < 0 {
            drivers.append(sized(.logged, f, fallbackSeverity: 1.5))
        }

        let ordered = drivers.enumerated().sorted { a, b in
            a.element.severity != b.element.severity ? a.element.severity > b.element.severity : a.offset < b.offset
        }.map(\.element)
        let lowScore = tone == .below || (input.recovery.map { $0 < redRecovery } ?? false)
        let notable = input.recovery != nil && (lowScore || drivers.contains(where: \.strong))
        return Brief(notable: notable, tone: tone, drivers: Array(ordered.prefix(maxDrivers)))
    }

    static func tone(_ recovery: Double?, _ range: ClosedRange<Double>?) -> Tone {
        guard let r = recovery, let range else { return .unknown }
        if r < range.lowerBound { return .below }
        if r > range.upperBound { return .above }
        return .within
    }

    /// Sleep, HRV, resting HR: named by either the raw deviation or the scorer's points.
    private static func scorerDriver(_ kind: Kind, raw: Double?, points: Double?, name: (Double) -> Bool,
                                     strong: (Double) -> Bool, weight: (Double) -> Double) -> Driver? {
        guard let raw else { return nil }
        let costly = (points ?? 0) <= -namePoints
        guard name(raw) || costly else { return nil }
        let isStrong = strong(raw) || (points ?? 0) <= -strongPoints
        let severity = max(abs(min(points ?? 0, 0)), name(raw) ? weight(raw) : 0)
        return Driver(kind: kind, value: raw, points: points, strong: isStrong, severity: severity)
    }

    private static func sized(_ kind: Kind, _ f: RecoveryFactors.Factor, fallbackSeverity: Double) -> Driver {
        Driver(kind: kind, value: f.deviation, points: f.points, question: f.question,
               strong: (f.points ?? 0) <= -strongPoints, severity: f.points.map { abs($0) } ?? fallbackSeverity)
    }

    /// Movement bouts or restless minutes, whichever stands out more, against the user's earlier nights.
    private static func restless(_ input: Input) -> Driver? {
        var best: Driver?
        func consider(_ kind: Kind, _ value: Double?, _ history: [Double], minExtra: Double, sdFloor: Double) {
            guard let value, let st = stats(history), value - st.mean >= minExtra else { return }
            let z = (value - st.mean) / max(st.sd, sdFloor)
            guard z >= nameRestlessZ, z * 3 > (best?.severity ?? 0) else { return }
            best = Driver(kind: kind, value: value, typical: st.mean.rounded(),
                          strong: input.restlessSolid && z >= strongRestlessZ, severity: 3 * z)
        }
        consider(.restless, input.restlessBouts.map(Double.init), input.restlessHistoryBouts,
                 minExtra: restlessMinExtraBouts, sdFloor: 1)
        consider(.restlessMinutes, input.restlessMinutes, input.restlessHistoryMinutes, minExtra: 5, sdFloor: 2)
        return best
    }

    static func stats(_ values: [Double]) -> (mean: Double, sd: Double)? {
        let v = values.filter(\.isFinite).suffix(30)
        guard v.count >= SleepRestlessness.minHistoryNights else { return nil }
        let mean = v.reduce(0, +) / Double(v.count)
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1)
        return (mean, variance.squareRoot())
    }
}
