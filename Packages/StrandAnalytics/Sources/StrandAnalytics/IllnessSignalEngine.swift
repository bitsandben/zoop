import Foundation

// Multi-signal "Heads-Up" early warning with explicit false-positive suppression. Pure, deterministic, DB-free.
//
// Resting HR up, skin temp up, HRV down and respiration up tend to move together days before symptoms
// (pre-symptomatic signature literature, e.g. Stanford/Snyder). Zoop scores the pattern against the user's
// own rolling baseline, never a population cutoff:
//   - a 0-100 composite score, gated on >= 2 corroborating signals,
//   - confounder suppression from same-day journal tags (alcohol, stress, sauna, late/intense workout,
//     travel), since alcohol mimics early illness,
//   - a visible "why" (signals fired) and "ruled out" (confounders), and silence without a trusted baseline.
//
// Wellness only, approximate, not a diagnosis: the engine never names a condition.
public enum IllnessSignalEngine {

    // MARK: - Tuning constants (pinned by test)

    /// Composite (0-100) at/above which the heads-up is raised; below it is "mild" (detail view only, no notification).
    public static let raiseThreshold: Double = 50.0
    /// Score floor below which the engine returns `.quiet`.
    public static let mildThreshold: Double = 25.0
    /// Minimum signals pointing the illness way before anything can raise.
    public static let minCorroboratingSignals: Int = 2

    /// A signal's |z| must reach this to count as firing (~the user's 95th percentile night; matches VitalBands.sigmaK).
    public static let signalZThreshold: Double = 2.0
    /// Per-signal sub-score is `min(perSignalCap, kZToScore * max(0, zIllnessward - signalZThreshold))`; the composite is their sum clamped to 100.
    public static let kZToScore: Double = 22.0
    public static let perSignalCap: Double = 40.0

    /// Multiplier applied to the composite (and level downgrade) when a confounder is present.
    public static let confounderDampen: Double = 0.45

    // MARK: - Inputs

    /// One signal's recent-vs-baseline reading, already z-scored by the caller (`Baselines.deviation`).
    /// `zIllnessward` is oriented so positive means more illness-like (HRV passes the negated z).
    /// `present == false` means no usable data; the signal is skipped, not counted as corroboration.
    public struct SignalReading: Equatable, Sendable {
        public let zIllnessward: Double
        public let present: Bool
        public init(zIllnessward: Double, present: Bool = true) {
            self.zIllnessward = zIllnessward
            self.present = present
        }
    }

    /// All four signal readings for the recent window; any may be absent (sparse 5/MG nights).
    public struct Inputs: Equatable, Sendable {
        public var restingHR: SignalReading?   // z of recent RHR vs baseline (↑ illness-ward)
        public var skinTemp: SignalReading?    // z of recent skin-temp deviation vs baseline (↑ illness-ward)
        public var hrv: SignalReading?         // NEGATED z of recent HRV vs baseline (drop = illness-ward)
        public var respiration: SignalReading? // z of recent respiration vs baseline (↑ illness-ward)
        public init(restingHR: SignalReading? = nil, skinTemp: SignalReading? = nil,
                    hrv: SignalReading? = nil, respiration: SignalReading? = nil) {
            self.restingHR = restingHR; self.skinTemp = skinTemp
            self.hrv = hrv; self.respiration = respiration
        }
    }

    /// Same-day context that can explain an anomaly away. Defaults are false/nil so a caller with no journal
    /// still gets the raw read. `travelPhaseJump` flags a CircadianEngine body-clock jump (jet lag).
    public struct Context: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var hardOrLateWorkout: Bool
        public var travelPhaseJump: Bool
        public var alreadyUnwell: Bool
        /// True iff the baseline is trusted (>= 14 valid nights, not stale); below that the engine stays silent.
        public var baselineTrusted: Bool
        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    hardOrLateWorkout: Bool = false, travelPhaseJump: Bool = false,
                    alreadyUnwell: Bool = false, baselineTrusted: Bool = true) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna
            self.hardOrLateWorkout = hardOrLateWorkout; self.travelPhaseJump = travelPhaseJump
            self.alreadyUnwell = alreadyUnwell; self.baselineTrusted = baselineTrusted
        }
    }

    // MARK: - Output

    /// How loud the heads-up is. `.alreadyUnwell` is the "rest up" path when the user logged feeling ill;
    /// `.suppressed` means signals are up but a confounder explains it.
    public enum Level: String, Equatable, Sendable, Codable {
        case quiet           // nothing worth saying (below mild, or not enough corroboration, or untrusted baseline)
        case mild            // some signals up — detail view only, no notification
        case raised          // clear multi-signal anomaly, no confounder — surface + notify
        case suppressed      // anomaly present but a behaviour tag / travel explains it — quietly informative
        case alreadyUnwell   // user logged feeling unwell — "rest up", not a scare
    }

    /// Semantic presentation state the UI localizes, so it never parses the English notification sentence.
    public enum Message: String, Equatable, Sendable, Codable {
        case learningBaseline, alreadyUnwellAgree, alreadyUnwell, normal, suppressed, mild, raised
    }

    /// Locale-free confounder identity for presentation; `suppressedBy` stays the human-readable payload.
    public enum SuppressionReason: String, Equatable, Sendable, Codable {
        case alcohol, stress, sauna, hardOrLateWorkout, travel
    }

    public struct Result: Equatable, Sendable {
        /// 0-100 composite anomaly score (post-dampening for the suppressed level).
        public let score: Double
        public let level: Level
        /// Caller-rendered phrases for the signals that fired, e.g. "RHR +6".
        public let firedSignals: [String]
        /// Confounders that were present and damped the score, e.g. "alcohol".
        public let suppressedBy: [String]
        public let suppressionReasons: [SuppressionReason]
        /// Signals over the firing threshold, regardless of level.
        public let signalCount: Int
        /// One-line non-clinical copy, ending in the not-a-diagnosis framing when it raises.
        public let copy: String
        public let message: Message?

        public init(score: Double, level: Level, firedSignals: [String], suppressedBy: [String],
                    signalCount: Int, copy: String, message: Message? = nil,
                    suppressionReasons: [SuppressionReason] = []) {
            self.score = score; self.level = level; self.firedSignals = firedSignals
            self.suppressedBy = suppressedBy; self.signalCount = signalCount; self.copy = copy
            self.message = message
            self.suppressionReasons = suppressionReasons
        }
    }

    /// Standing not-a-diagnosis tail shared with IllnessNotifier copy.
    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    // MARK: - Evaluate

    /// Scores the recent window and decides the heads-up level and copy.
    ///
    /// `firedLabels` maps a signal key to the caller-rendered phrase shown when it fires (only keys clearing
    /// `signalZThreshold` are surfaced), keeping number formatting out of the engine.
    public static func evaluate(_ inputs: Inputs, context: Context,
                                firedLabels: [String: String] = [:]) -> Result {
        // Fixed order keeps firedSignals deterministic.
        let ordered: [(key: String, reading: SignalReading?)] = [
            ("restingHR", inputs.restingHR),
            ("skinTemp", inputs.skinTemp),
            ("hrv", inputs.hrv),
            ("respiration", inputs.respiration),
        ]

        var rawScore = 0.0
        var firedKeys: [String] = []
        for (key, reading) in ordered {
            guard let r = reading, r.present else { continue }
            let over = r.zIllnessward - signalZThreshold
            guard over > 0 else { continue }
            firedKeys.append(key)
            rawScore += min(perSignalCap, kZToScore * over)
        }
        let score = min(100.0, rawScore)
        let signalCount = firedKeys.count
        let firedSignals = firedKeys.compactMap { firedLabels[$0] }

        // Gate 0: untrusted baseline -> silent; score still reported for a detail view, never raised.
        if !context.baselineTrusted {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Still learning your baseline - keeping an eye out.",
                          message: .learningBaseline)
        }

        // Already-unwell: the user's log is ground truth, so show a gentle "rest up" regardless of score.
        if context.alreadyUnwell {
            let agreeing = score >= mildThreshold && signalCount >= 1
            let copy = agreeing
                ? "Rest up - you logged feeling unwell, and your numbers agree. \(disclaimerTail)"
                : "Rest up - you logged feeling unwell. Take it easy today. \(disclaimerTail)"
            return Result(score: score, level: .alreadyUnwell, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy,
                          message: agreeing ? .alreadyUnwellAgree : .alreadyUnwell)
        }

        // Need >= 2 firing signals and a mild-or-better composite, else quiet.
        guard signalCount >= minCorroboratingSignals, score >= mildThreshold else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Nothing notable - your signals look like your normal range.",
                          message: .normal)
        }

        // Confounder suppression: any present behaviour/travel tag with a plainer explanation dampens and downgrades.
        var suppressedBy: [String] = []
        var suppressionReasons: [SuppressionReason] = []
        if context.alcohol { suppressedBy.append("alcohol"); suppressionReasons.append(.alcohol) }
        if context.stress { suppressedBy.append("stress"); suppressionReasons.append(.stress) }
        if context.sauna { suppressedBy.append("sauna"); suppressionReasons.append(.sauna) }
        if context.hardOrLateWorkout {
            suppressedBy.append("a hard or late workout")
            suppressionReasons.append(.hardOrLateWorkout)
        }
        if context.travelPhaseJump { suppressedBy.append("travel"); suppressionReasons.append(.travel) }

        let signalsPhrase = firedSignals.isEmpty ? "Some signals are up" : firedSignals.joined(separator: ", ")

        if !suppressedBy.isEmpty {
            let dampened = score * confounderDampen
            let reason = joinReasons(suppressedBy)
            let copy = "Some signals are up (\(signalsPhrase)), but you logged \(reason) - likely that, "
                + "not illness. \(disclaimerTail)"
            return Result(score: dampened, level: .suppressed, firedSignals: firedSignals,
                          suppressedBy: suppressedBy, signalCount: signalCount, copy: copy,
                          message: .suppressed, suppressionReasons: suppressionReasons)
        }

        // No confounder: mild stays in the detail view; a strong composite raises.
        if score < raiseThreshold {
            let copy = "A few signals are mildly up (\(signalsPhrase)). Nothing alarming - worth a calmer "
                + "day. \(disclaimerTail)"
            return Result(score: score, level: .mild, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy, message: .mild)
        }

        let ruledOut = "no alcohol or travel logged"
        let copy = "Heads-up - your body looks strained. \(signalsPhrase). With \(ruledOut), consider "
            + "taking it easy. \(disclaimerTail)"
        return Result(score: score, level: .raised, firedSignals: firedSignals,
                      suppressedBy: [], signalCount: signalCount, copy: copy, message: .raised)
    }

    // MARK: - Helpers

    /// Joins confounders into a natural list ("a, b and c").
    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default:
            let head = reasons.dropLast().joined(separator: ", ")
            return "\(head) and \(reasons.last!)"
        }
    }
}
