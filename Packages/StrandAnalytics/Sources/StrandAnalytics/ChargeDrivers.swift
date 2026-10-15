import Foundation

// ChargeDrivers.swift - the ordered "why is my Charge what it is" driver list.
//
// One row per term that actually fed the Charge score, with its signed contribution in points,
// the measured value, the baseline it was compared against, and a plain-English verdict. The UI
// renders one row per driver and never recomputes the score.
//
// A driver exists only when its term fed the score: a missing or uncalibrated input produces no
// row, never a fabricated zero. deltaPoints is the term's real marginal contribution (see
// chargeDrivers). The score is logistic, so deltas do not sum to the headline; rows are ordered
// by magnitude. Pure and side-effect-free.

/// One row of the Charge driver breakdown.
public struct ChargeDriver: Equatable, Sendable {
    public let label: String
    /// Signed contribution to the 0-100 Charge score, in points (positive supported recovery).
    public let deltaPoints: Int
    /// The measured value, formatted with units, e.g. "58 bpm".
    public let valueText: String
    /// The baseline this value was compared against, e.g. "61 bpm baseline". Empty for terms whose
    /// reference is a fixed centre or zero; the UI then omits the baseline line.
    public let baselineText: String
    /// Short plain-English read of the direction, e.g. "below baseline, supporting recovery".
    public let verdict: String

    public init(label: String, deltaPoints: Int, valueText: String,
                baselineText: String, verdict: String) {
        self.label = label
        self.deltaPoints = deltaPoints
        self.valueText = valueText
        self.baselineText = baselineText
        self.verdict = verdict
    }
}

/// A skin-temperature reading as a relative deviation from the personal baseline (a trend, never
/// a clinical absolute), with a warmer / typical / cooler tier.
public struct SkinTempRelative: Equatable, Sendable {

    /// Where tonight's skin temp sits versus the personal baseline; a deviation band only.
    public enum Tier: String, Equatable, Sendable, Codable {
        case cooler   // meaningfully below the personal baseline
        case typical  // within the normal personal range
        case warmer   // meaningfully above the personal baseline
    }

    /// Signed deviation from the personal baseline, in °C (value - baseline).
    public let deviationC: Double
    public let tier: Tier

    public init(deviationC: Double, tier: Tier) {
        self.deviationC = deviationC
        self.tier = tier
    }
}

extension RecoveryScorer {

    // MARK: - Skin-temp relative tier

    /// Half-width (°C) of the "typical" band around the baseline. Matches
    /// `VitalBands.skinTempDeviationCfg.floorSpread` so the band tracks measurement noise.
    public static let skinTempTypicalBandC: Double = 0.3

    /// Builds the relative skin-temp marker from a signed deviation (°C). Nil when no deviation is
    /// available, so the UI shows nothing rather than a fake absolute.
    public static func skinTempRelative(deviationC: Double?) -> SkinTempRelative? {
        guard let dev = deviationC else { return nil }
        let tier: SkinTempRelative.Tier
        if dev > skinTempTypicalBandC {
            tier = .warmer
        } else if dev < -skinTempTypicalBandC {
            tier = .cooler
        } else {
            tier = .typical
        }
        return SkinTempRelative(deviationC: dev, tier: tier)
    }

    // MARK: - Charge driver list

    /// Builds the ordered Charge driver list from the same inputs `recovery(...)` reads.
    ///
    /// Each row's `deltaPoints` is the full score minus the score with that term held at baseline.
    /// Terms whose input is missing are omitted; rows sort by |deltaPoints| descending, ties in term
    /// order (hrv, rhr, sleepPerf, resp, skinTempDev). Empty when there is no score (cold start).
    /// `*ValueText` closures format each measured value so the engine stays unit-agnostic.
    public static func chargeDrivers(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: BaselineState,
                                     rhrBaseline: BaselineState?,
                                     respBaseline: BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil,
                                     weights: ChargeWeights = .standard,
                                     symptomLoad: Double? = nil) -> [ChargeDriver] {

        // No score => no driver rows. The RHR row is built from this baseline directly, so it is gated
        // once here (#1988) to match the headline's exclusion of an unusable baseline.
        let rhrB = rhrBaseline.flatMap { $0.usable ? $0 : nil }
        guard let full = recovery(hrv: hrv, rhr: rhr, resp: resp,
                                  hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                  respBaseline: respBaseline, sleepPerf: sleepPerf,
                                  skinTempDev: skinTempDev, weights: weights,
                                  symptomLoad: symptomLoad) else {
            return []
        }

        // A term's deltaPoints is the full score minus the score with THAT term's z forced to 0 (held
        // at its baseline) while every term keeps its weight, routed through recovery(...) so points
        // cannot drift from the headline. Renormalised leave-one-out would be wrong: dropping a term
        // that sits at the average z returns the same score and collapses the delta to 0.
        func points(_ neutralised: Double?) -> Int {
            // Nearest integer, exact half-ties away from zero.
            Int((full - (neutralised ?? full)).rounded(.toNearestOrAwayFromZero))
        }

        var drivers: [ChargeDriver] = []

        // Detection only: did the parasympathetic-saturation signature fire (low HRV with a low,
        // decoupled resting HR)? The guard's easing is not applied, so deltaPoints is the full HRV
        // penalty; the verdict just names the pattern.
        let hrvZFull = zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        let rhrZFull: Double? = rhrB.map { zScore($0.baseline, mean: rhr, spread: $0.spread) }
        let hrvSaturationDetected = parasympatheticSaturation(hrvZ: hrvZFull, rhrZ: rhrZFull).active

        // HRV: dominant driver, present whenever a score exists. Neutral = baseline mean.
        let hrvPoints = points(recovery(hrv: hrvBaseline.baseline, rhr: rhr, resp: resp,
                                        hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                        respBaseline: respBaseline, sleepPerf: sleepPerf,
                                        skinTempDev: skinTempDev, weights: weights,
                                  symptomLoad: symptomLoad))
        drivers.append(ChargeDriver(
            label: "Heart rate variability",
            deltaPoints: hrvPoints,
            valueText: "\(Int(hrv.rounded())) ms",
            baselineText: "\(Int(hrvBaseline.baseline.rounded())) ms baseline",
            verdict: hrvVerdict(value: hrv, baseline: hrvBaseline.baseline,
                                deltaPoints: hrvPoints,
                                saturationDetected: hrvSaturationDetected)))

        // Resting HR: lower vs baseline supports recovery. Neutral = baseline mean.
        if let b = rhrB {
            let rhrPoints = points(recovery(hrv: hrv, rhr: b.baseline, resp: resp,
                                            hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                            respBaseline: respBaseline, sleepPerf: sleepPerf,
                                            skinTempDev: skinTempDev, weights: weights,
                                  symptomLoad: symptomLoad))
            drivers.append(ChargeDriver(
                label: "Resting heart rate",
                deltaPoints: rhrPoints,
                valueText: "\(Int(rhr.rounded())) bpm",
                baselineText: "\(Int(b.baseline.rounded())) bpm baseline",
                verdict: rhrVerdict(value: rhr, baseline: b.baseline, deltaPoints: rhrPoints)))
        }

        // Sleep vs need; neutral at sleepPerfCenter.
        if let sp = sleepPerf {
            drivers.append(ChargeDriver(
                label: "Sleep vs need",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                             respBaseline: respBaseline, sleepPerf: sleepPerfCenter,
                                             skinTempDev: skinTempDev, weights: weights,
                                  symptomLoad: symptomLoad)),
                valueText: "\(Int((sp * 100).rounded()))%",
                baselineText: "",   // centred on a fixed "good night", not a learned baseline
                verdict: sleepVerdict(sleepPerf: sp)))
        }

        // Respiration: lower vs baseline supports recovery. Neutral = baseline mean.
        if let r = resp, let b = respBaseline {
            let respPoints = points(recovery(hrv: hrv, rhr: rhr, resp: b.baseline,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: skinTempDev, weights: weights,
                                  symptomLoad: symptomLoad))
            drivers.append(ChargeDriver(
                label: "Respiratory rate",
                deltaPoints: respPoints,
                valueText: String(format: "%.1f br/min", locale: Locale(identifier: "en_US_POSIX"),
                                  displayRounded(r, fractionDigits: 1)),
                baselineText: String(format: "%.1f br/min baseline", locale: Locale(identifier: "en_US_POSIX"),
                                     displayRounded(b.baseline, fractionDigits: 1)),
                verdict: respVerdict(value: r, baseline: b.baseline, deltaPoints: respPoints)))
        }

        // Skin-temp deviation: symmetric penalty, so the delta is always <= 0.
        if let dev = skinTempDev {
            let skinTempPoints = points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                                 hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                                 respBaseline: respBaseline, sleepPerf: sleepPerf,
                                                 skinTempDev: 0, weights: weights,
                                  symptomLoad: symptomLoad))
            drivers.append(ChargeDriver(
                label: "Skin temperature",
                deltaPoints: skinTempPoints,
                valueText: skinTempDevText(dev),
                baselineText: "",   // a deviation already; the reference is the personal baseline (0)
                verdict: skinTempVerdict(dev, deltaPoints: skinTempPoints)))
        }

        // Morning check-in symptoms: penalty only, present only when reported.
        if let load = symptomLoad, load > 0 {
            let symptomPoints = points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                                hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                                                respBaseline: respBaseline, sleepPerf: sleepPerf,
                                                skinTempDev: skinTempDev, weights: weights,
                                                symptomLoad: nil))
            drivers.append(ChargeDriver(
                label: "Morning symptoms",
                deltaPoints: symptomPoints,
                valueText: "",
                baselineText: "",
                verdict: "reported this morning, limiting recovery"))
        }

        // Biggest mover first; stable on ties.
        return drivers.enumerated()
            .sorted { a, b in
                let am = abs(a.element.deltaPoints), bm = abs(b.element.deltaPoints)
                return am != bm ? am > bm : a.offset < b.offset
            }
            .map { $0.element }
    }

    // MARK: - Plain-English verdicts (direction only, no fabricated numbers)

    // Every returned literal is also a localization key consumed by ChargeBreakdownFormat; add any
    // new or reworded verdict to Localizable.xcstrings (Tools/test_home_i18n.py enforces this).

    static func hrvVerdict(value: Double, baseline: Double, deltaPoints: Int,
                           saturationDetected: Bool = false) -> String {
        let verdict = baselineVerdict(value: value, baseline: baseline,
                                      deltaPoints: deltaPoints, fractionDigits: 0)
        // Saturation signature: name the pattern only when the displayed direction and rounded points
        // support the full statement; a sub-display difference keeps the "slightly below" verdict.
        if saturationDetected && verdict == "below baseline, limiting recovery" {
            return "below baseline, limiting recovery, though low resting HR suggests this may be parasympathetic saturation rather than fatigue"
        }
        return verdict
    }

    static func rhrVerdict(value: Double, baseline: Double, deltaPoints: Int) -> String {
        baselineVerdict(value: value, baseline: baseline,
                        deltaPoints: deltaPoints, fractionDigits: 0)
    }

    static func respVerdict(value: Double, baseline: Double, deltaPoints: Int) -> String {
        baselineVerdict(value: value, baseline: baseline,
                        deltaPoints: deltaPoints, fractionDigits: 1)
    }

    /// The value as a row shows it, rounded once so the printed number and its verdict agree.
    /// Explicit rounding because glibc, swift-corelibs and Java HALF_UP round `%.1f` differently
    /// at a half.
    static func displayRounded(_ value: Double, fractionDigits: Int) -> Double {
        let scale = pow(10.0, Double(fractionDigits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    static func baselineVerdict(value: Double, baseline: Double, deltaPoints: Int,
                                fractionDigits: Int) -> String {
        let displayedValue = displayRounded(value, fractionDigits: fractionDigits)
        let displayedBaseline = displayRounded(baseline, fractionDigits: fractionDigits)

        if displayedValue == displayedBaseline {
            if deltaPoints == 0 || value == baseline { return "at baseline" }
            if value > baseline {
                return deltaPoints > 0
                    ? "slightly above baseline, supporting recovery"
                    : "slightly above baseline, limiting recovery"
            }
            return deltaPoints > 0
                ? "slightly below baseline, supporting recovery"
                : "slightly below baseline, limiting recovery"
        }

        let above = displayedValue > displayedBaseline
        if deltaPoints == 0 {
            return above
                ? "above baseline, too small to change Charge"
                : "below baseline, too small to change Charge"
        }
        if above {
            return deltaPoints > 0
                ? "above baseline, supporting recovery"
                : "above baseline, limiting recovery"
        }
        return deltaPoints > 0
            ? "below baseline, supporting recovery"
            : "below baseline, limiting recovery"
    }

    static func sleepVerdict(sleepPerf: Double) -> String {
        if sleepPerf > sleepPerfCenter { return "a strong night, supporting recovery" }
        if sleepPerf < sleepPerfCenter { return "below a good night, limiting recovery" }
        return "a typical night"
    }

    static func skinTempVerdict(_ dev: Double, deltaPoints: Int) -> String {
        // Symmetric penalty: "near" only when the displayed score moved by 0 points.
        if deltaPoints == 0 { return "near baseline" }
        return dev > 0
            ? "warmer than baseline, limiting recovery"
            : "cooler than baseline, limiting recovery"
    }

    static func skinTempDevText(_ dev: Double) -> String {
        // Take the sign of negative zero from the IEEE bit: `-0.0 >= 0` is true and would print "+-0.0".
        // `%+.1f` handles both zeroes; the branch just pins the edge.
        if dev == 0 {
            return dev.sign == .minus ? "-0.0 C vs baseline" : "+0.0 C vs baseline"
        }
        return String(format: "%+.1f C vs baseline", locale: Locale(identifier: "en_US_POSIX"), dev)
    }
}
