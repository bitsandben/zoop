import Foundation
import WhoopProtocol

// HRVFreqDomain.swift - frequency-domain HRV (LF / HF / LF-HF / total power) over an R-R series.
//
// Purely additive: an opt-in estimator that changes no Charge / Effort / Rest / sleep output; the
// time-domain HRVAnalyzer is untouched.
//
// Why Lomb-Scargle, not an FFT: a tachogram (R-R intervals against their own cumulative time) is
// unevenly sampled. Resampling to a uniform grid for an FFT is a low-pass interpolation that distorts
// the HF (respiratory) band, the one that matters most for parasympathetic tone. Lomb-Scargle
// (Lomb 1976, Scargle 1982) estimates the spectrum directly from the (t_k, rr_k) pairs and is
// recommended for irregular tachograms (Laguna, Moody & Mark 1998; Clifford & Tarassenko 2005).
// Same "evaluate only the frequencies we care about" idea as SleepStagerV2.respRegularity.
//
// Task Force (1996) bands:
//   - VLF 0.0033-0.04 Hz (folded into total power only)
//   - LF  0.04-0.15 Hz (~7-37 s period)
//   - HF  0.15-0.40 Hz (~2.5-6.7 s period; respiratory)
//   - LF/HF: the ratio of the two band powers.
// A periodogram can only resolve a frequency whose period fits in the record several times. The
// Task Force short-term standard is 300 s; we relax it to honest minimum spans:
//   - HF needs >= 60 s of R-R span (0.15 Hz is ~9 cycles in 60 s).
//   - LF (so LF/HF and a meaningful total power) needs >= 250 s (0.04 Hz is a 25 s period).
// Under 60 s the whole result is nil; between 60 s and 250 s HF is returned but LF / LF-HF are nil.
// Approximate, non-clinical. Units are ms^2.

public enum HRVFreqDomain {

    // MARK: - Band edges (Hz) and span gates (s), pinned by test

    /// VLF lower edge (Hz); folded into total power.
    public static let vlfLowHz: Double = 0.0033
    public static let lfLowHz: Double = 0.04
    public static let lfHighHz: Double = 0.15
    public static let hfLowHz: Double = 0.15
    public static let hfHighHz: Double = 0.40

    /// Minimum R-R span (s) before any frequency-domain result is returned.
    public static let minSpanForHFSec: Double = 60.0
    /// Minimum R-R span (s) before LF (and LF/HF, total power) is trusted; below it they are nil.
    public static let minSpanForLFSec: Double = 250.0

    public static let minBeats: Int = 20

    /// Frequency-grid resolution (Hz) for sampling the periodogram within each band: ~22 grid points
    /// across LF and ~50 across HF, enough for a stable trapezoidal band integral.
    public static let freqStepHz: Double = 0.005

    // MARK: - Result

    /// Frequency-domain HRV over a window, powers in ms^2. `lf` / `lfhf` are nil when the span is too
    /// short for LF (60 s <= span < 250 s gives HF only); `hf` and `totalPower` are present on any non-nil result.
    public struct Bands: Equatable, Sendable {
        public let lf: Double?
        public let hf: Double
        /// LF / HF ratio; nil when LF is nil or HF == 0.
        public let lfhf: Double?
        /// Total power across VLF+LF+HF (0.0033-0.40 Hz). On a short HF-only window it reports the HF-band
        /// power so the field is never a misleading partial sum.
        public let totalPower: Double

        public init(lf: Double?, hf: Double, lfhf: Double?, totalPower: Double) {
            self.lf = lf; self.hf = hf; self.lfhf = lfhf; self.totalPower = totalPower
        }
    }

    // MARK: - Public API

    /// Frequency-domain HRV from R-R intervals (wall-clock `ts` seconds, `rrMs`). The series goes
    /// through `HRVAnalyzer.cleanRR` (range + Malik ectopic) first so an artifact beat can't inject
    /// power. Nil with too few clean beats or a span under `minSpanForHFSec`.
    public static func freqDomain(rr: [RRInterval]) -> Bands? {
        // Stable sort: same-second beats keep their emission order (#823).
        let raw = rr.sortedByTsStable().map { Double($0.rrMs) }
        return freqDomain(rawRR: raw)
    }

    /// Frequency-domain HRV from a raw time-ordered R-R series in ms. The cumulative sum of the cleaned
    /// intervals (seconds) is each sample's timestamp; the mean-removed cleaned values are the samples.
    /// Nil under the same gates as the `[RRInterval]` overload.
    public static func freqDomain(rawRR: [Double]) -> Bands? {
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }

        // Tachogram: time of beat k = cumulative sum of the first k clean intervals (s); value = the interval (ms).
        var times = [Double](repeating: 0, count: clean.count)
        var acc = 0.0
        for i in 0..<clean.count {
            times[i] = acc / 1000.0      // ms -> s
            acc += clean[i]
        }
        let span = times.last! - times.first!   // total record length in seconds
        guard span >= minSpanForHFSec else { return nil }

        // Mean-remove: Lomb-Scargle assumes zero mean, and a DC offset would leak across all frequencies.
        let mean = clean.reduce(0, +) / Double(clean.count)
        let y = clean.map { $0 - mean }

        // HF is always computable once span >= 60 s.
        let hf = bandPower(times: times, y: y, fLow: hfLowHz, fHigh: hfHighHz)

        // LF (and so LF/HF and the wide total power) only once span >= 250 s.
        let lfTrusted = span >= minSpanForLFSec
        let lf: Double? = lfTrusted ? bandPower(times: times, y: y, fLow: lfLowHz, fHigh: lfHighHz) : nil

        let lfhf: Double?
        if let lf, hf > 0 { lfhf = lf / hf } else { lfhf = nil }

        // Total power = sum of the sub-band integrals (VLF + LF + HF) when LF is trusted, else just HF.
        // Summing guarantees totalPower >= hf on the same grid; one wide integral samples a grid offset
        // from the HF-only grid and can undercount a narrow HF peak below `hf`.
        let totalPower: Double
        if lfTrusted, let lfVal = lf {
            let vlf = bandPower(times: times, y: y, fLow: vlfLowHz, fHigh: lfLowHz)
            totalPower = vlf + lfVal + hf
        } else {
            totalPower = hf
        }

        return Bands(lf: lf, hf: hf, lfhf: lfhf, totalPower: totalPower)
    }

    // MARK: - Lomb-Scargle band integral

    /// Trapezoidal integral of the Lomb-Scargle power across [fLow, fHigh] every `freqStepHz`; 0 for a
    /// degenerate band. Uses the Press et al. (Numerical Recipes) normalisation, giving a band power (ms^2).
    static func bandPower(times: [Double], y: [Double], fLow: Double, fHigh: Double) -> Double {
        guard fHigh > fLow else { return 0 }
        // Variance of the mean-removed signal; Lomb-Scargle scales power by it.
        let n = Double(y.count)
        var variance = 0.0
        for v in y { variance += v * v }
        variance /= n
        guard variance > 0 else { return 0 }

        var power = 0.0
        var prevP = 0.0
        var prevF = fLow
        var first = true
        var f = fLow
        while f <= fHigh + 1e-12 {
            let p = lombScarglePower(times: times, y: y, freqHz: f, variance: variance)
            if !first {
                // Trapezoid: average of the endpoint powers times the frequency step.
                power += 0.5 * (p + prevP) * (f - prevF)
            }
            prevP = p
            prevF = f
            first = false
            f += freqStepHz
        }
        return power
    }

    /// Lomb-Scargle normalised power at one frequency (Press et al.). `variance` is the sample variance
    /// of the mean-removed series; the time offset tau makes it invariant to time translation, which
    /// handles the uneven spacing.
    static func lombScarglePower(times: [Double], y: [Double], freqHz: Double, variance: Double) -> Double {
        let omega = 2.0 * Double.pi * freqHz

        // tau: the phase offset that orthogonalises the sine and cosine sums (Lomb 1976).
        var sin2 = 0.0, cos2 = 0.0
        for t in times {
            let a = 2.0 * omega * t
            sin2 += sin(a)
            cos2 += cos(a)
        }
        let tau = atan2(sin2, cos2) / (2.0 * omega)

        var cTerm = 0.0, cDen = 0.0
        var sTerm = 0.0, sDen = 0.0
        for i in 0..<times.count {
            let arg = omega * (times[i] - tau)
            let c = cos(arg)
            let s = sin(arg)
            cTerm += y[i] * c
            cDen += c * c
            sTerm += y[i] * s
            sDen += s * s
        }
        let cosPart = cDen > 0 ? (cTerm * cTerm) / cDen : 0.0
        let sinPart = sDen > 0 ? (sTerm * sTerm) / sDen : 0.0
        // Normalised by 2*variance: a power-spectral-density estimate in ms^2/Hz.
        return (cosPart + sinPart) / (2.0 * variance)
    }
}
