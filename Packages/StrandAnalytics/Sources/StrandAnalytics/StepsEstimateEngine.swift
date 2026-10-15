import Foundation
import WhoopProtocol

/// Estimates daily steps for a WHOOP 4.0 from strap MOTION, calibrated per user against a phone step count.
///
/// A 4.0 sends no step count over BLE and its gravity data is sparse (~one vector per record), far below
/// what a pedometer needs. What it can measure is movement VOLUME, mapped to steps with a personal
/// coefficient: `steps = k * motionIntensity` (through-origin fit). `k` depends on placement and gait, and is
/// fit as a MOTION-WEIGHTED median of per-day `steps/motion` ratios (#682) so one odd day cannot drag it and
/// busy days (less ratio noise) count more. Users without phone history can set `k` manually.
/// Output is always framed as an estimate.
public enum StepsEstimateEngine {

    // MARK: - Tunables

    /// Fewest calibration days (motion plus reference steps) before an auto-fit `k` is trusted; below this
    /// the estimate is withheld unless a manual `k` is set.
    public static let minCalibrationDays = 3
    /// Calibration days at/above which confidence saturates toward 1.
    public static let goodCalibrationDays = 14
    /// A day must move at least this much (summed gravity-delta) to enter the ratio fit and to produce an
    /// estimate; near-still days make steps/motion explode.
    public static let minMotionForFit = 1.0
    /// Sanity clamp on a daily estimate.
    public static let maxDailySteps = 60_000

    // MARK: - Types

    /// One calibration day: the strap's motion volume and the phone's step count for the SAME day.
    public struct CalibrationPoint: Equatable {
        public let motion: Double
        public let steps: Double
        public init(motion: Double, steps: Double) { self.motion = motion; self.steps = steps }
    }

    /// The fitted (or manually-set) personal model.
    public struct Calibration: Equatable {
        /// Steps per unit of motion.
        public let coefficient: Double
        /// How many usable auto-fit days exist alongside this model (0 when none).
        public let sampleDays: Int
        /// 0-1 trust from sample size and fit spread; 1.0 for a manual `k`.
        public let confidence: Double
        /// True when the user set `k` by hand rather than it being fit from phone data.
        public let manual: Bool
        public init(coefficient: Double, sampleDays: Int, confidence: Double, manual: Bool) {
            self.coefficient = coefficient; self.sampleDays = sampleDays
            self.confidence = confidence; self.manual = manual
        }
    }

    /// Coarse confidence tier for a one-word badge; a manual `k` reports `.high`. (#760/#792)
    public enum ConfidenceTier: String, Equatable {
        case low, medium, high

        /// 0-1 confidence to tier: < 0.34 low, < 0.67 medium, else high.
        public static func from(_ confidence: Double) -> ConfidenceTier {
            if confidence < 0.34 { return .low }
            if confidence < 0.67 { return .medium }
            return .high
        }

        /// The badge word the tile/Settings renders.
        public var word: String {
            switch self {
            case .low: return "low confidence"
            case .medium: return "medium confidence"
            case .high: return "high confidence"
            }
        }
    }

    /// Read-out of the calibration state for the Today steps tile and Settings.
    public enum CalibrationStatus: Equatable {
        /// A manual `k` is in force; `sampleDays` is the auto-fit days alongside it (informational).
        case manual(coefficient: Double, sampleDays: Int)
        /// Enough overlapping days fit an auto coefficient.
        case calibrated(coefficient: Double, sampleDays: Int, confidence: Double)
        /// Not yet calibrated: `have` of `need` overlapping phone-counted days.
        case needsMoreDays(have: Int, need: Int)

        /// True when an estimate can be produced right now.
        public var canEstimate: Bool {
            switch self {
            case .manual, .calibrated: return true
            case .needsMoreDays: return false
            }
        }

        /// Short one-liner for the tile/Settings (headline only; no confidence badge).
        public var headline: String {
            switch self {
            case .manual:
                return "Calibrated by hand"
            case let .calibrated(_, sampleDays, _):
                return "Estimated from \(sampleDays) day\(sampleDays == 1 ? "" : "s") your phone also counted"
            case let .needsMoreDays(have, need):
                // #589: have == 0 means no day had both motion and a phone step total (a 4.0 always streams
                // motion), so the "Need N more days" countdown would never advance. Say what unblocks it.
                if have == 0 {
                    return "Connect your phone's step count to estimate steps"
                }
                let more = Swift.max(0, need - have)
                return "Need \(more) more day\(more == 1 ? "" : "s") where your phone also counted steps"
            }
        }

        /// The confidence tier: `.calibrated` maps its confidence, manual is `.high`, uncalibrated is `.low`. (#760/#792)
        public var confidenceTier: ConfidenceTier {
            switch self {
            case .manual: return .high
            case let .calibrated(_, _, confidence): return ConfidenceTier.from(confidence)
            case .needsMoreDays: return .low
            }
        }

        /// The personal coefficient `k` in force, or nil when none is fit/set yet. (#760/#792)
        public var coefficient: Double? {
            switch self {
            case let .manual(k, _): return k
            case let .calibrated(k, _, _): return k
            case .needsMoreDays: return nil
            }
        }

        /// Denser status line (tier, `k`, day count), e.g. "k=12.3 from 6 days, medium confidence" or
        /// "calibrating: 1/3 days". (#760/#792)
        public var detail: String {
            switch self {
            case let .manual(k, _):
                return "manual k=\(StepsEstimateEngine.formatK(k))"
            case let .calibrated(k, sampleDays, confidence):
                let tier = ConfidenceTier.from(confidence)
                return "k=\(StepsEstimateEngine.formatK(k)) from \(sampleDays) day\(sampleDays == 1 ? "" : "s"), \(tier.word)"
            case let .needsMoreDays(have, need):
                return "calibrating: \(Swift.min(have, need))/\(need) days"
            }
        }
    }

    /// Formats `k` to one decimal, locale-free. (#760/#792)
    static func formatK(_ k: Double) -> String {
        String(format: "%.1f", k)
    }

    /// Classifies the calibration state from the same inputs `calibrate` sees. A positive `manualOverride`
    /// reports `.manual`; otherwise `.calibrated` once `minCalibrationDays` usable days exist, else `.needsMoreDays`.
    public static func status(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> CalibrationStatus {
        let usableDays = points.filter(isUsableCalibrationPoint).count
        if let k = manualOverride, k > 0 {
            return .manual(coefficient: k, sampleDays: usableDays)
        }
        guard let cal = calibrate(points), usableDays >= minCalibrationDays else {
            return .needsMoreDays(have: usableDays, need: minCalibrationDays)
        }
        return .calibrated(coefficient: cal.coefficient, sampleDays: cal.sampleDays, confidence: cal.confidence)
    }

    // MARK: - Motion feature

    /// Total daily MOTION INTENSITY: the sum of L2 gravity-vector deltas between consecutive samples
    /// (movement volume, the same proxy the sleep stager uses for stillness).
    public static func dayMotionIntensity(_ grav: [GravitySample]) -> Double {
        guard grav.count > 1 else { return 0 }
        var total = 0.0
        var prev = grav[0]
        for i in 1..<grav.count {
            let r = grav[i]
            let dx = prev.x - r.x, dy = prev.y - r.y, dz = prev.z - r.z
            total += (dx * dx + dy * dy + dz * dz).squareRoot()
            prev = r
        }
        return total
    }

    // MARK: - Calibration

    /// Fits the personal coefficient from days with both motion volume and a reference step count: the
    /// MOTION-WEIGHTED median of `steps / motion` (days below `minMotionForFit` skipped; weight = motion, #682).
    /// Nil when too few usable days and no manual override; a non-nil `manualOverride` always wins (confidence 1.0).
    public static func calibrate(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> Calibration? {
        let usable = points.filter(isUsableCalibrationPoint)
        if let k = manualOverride, k > 0 {
            return Calibration(coefficient: k, sampleDays: usable.count, confidence: 1.0, manual: true)
        }
        // Weight = motion volume: a busier day votes harder.
        let weighted = usable
            .map { (ratio: $0.steps / $0.motion, weight: $0.motion) }
        guard weighted.count >= minCalibrationDays else { return nil }
        let ratios = weighted.map { $0.ratio }
        let weights = weighted.map { $0.weight }
        let k = weightedMedian(ratios, weights: weights)
        guard k > 0 else { return nil }
        // Confidence grows with sample size toward goodCalibrationDays, discounted by relative spread
        // (weighted MAD / weighted median, weighted by the same days that drove `k`).
        let sizeTerm = min(1.0, Double(weighted.count) / Double(goodCalibrationDays))
        let mad = weightedMedian(ratios.map { abs($0 - k) }, weights: weights)
        let spread = k > 0 ? mad / k : 1.0
        let tightness = max(0.0, 1.0 - spread)              // 1 = all ratios equal, 0 = wildly scattered
        let confidence = (0.5 * sizeTerm + 0.5 * tightness).clampedUnit
        return Calibration(coefficient: k, sampleDays: weighted.count, confidence: confidence, manual: false)
    }

    // MARK: - Estimate

    /// Estimated steps for a day from its motion volume. Nil below `minMotionForFit`; the UI shows a dash, never a fake 0.
    public static func estimate(motion: Double, calibration: Calibration) -> Int? {
        guard motion >= minMotionForFit, calibration.coefficient > 0 else { return nil }
        let raw = motion * calibration.coefficient
        return Int(raw.rounded()).clamped(0, maxDailySteps)
    }

    // MARK: - Helpers

    static func isUsableCalibrationPoint(_ point: CalibrationPoint) -> Bool {
        point.motion >= minMotionForFit && point.steps > 0
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Weighted median (#682): the value where cumulative weight first reaches half the total; exactly on the
    /// boundary it averages the two straddling values, so equal weights match the plain median. Falls back to
    /// the plain median for absent/degenerate weights.
    static func weightedMedian(_ xs: [Double], weights: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        guard weights.count == xs.count else { return median(xs) }
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return median(xs) }
        let half = total / 2
        var cum = 0.0
        for (pos, idx) in order.enumerated() {
            let w = max(0.0, weights[idx])
            cum += w
            if cum > half { return xs[idx] }
            if cum == half {
                // Half-mass on a boundary: average with the next value.
                let next = pos + 1 < order.count ? order[pos + 1] : idx
                return (xs[idx] + xs[next]) / 2
            }
        }
        return xs[order[order.count - 1]]
    }
}

private extension Double {
    var clampedUnit: Double { Swift.max(0.0, Swift.min(1.0, self)) }
}
private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}
