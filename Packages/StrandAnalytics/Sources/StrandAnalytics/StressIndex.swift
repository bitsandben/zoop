import Foundation
import WhoopProtocol

// StressIndex: Baevsky's Stress Index, a histogram-based autonomic-balance metric. PURELY ADDITIVE display
// metric; touches no Charge / Effort / Rest / sleep output. APPROXIMATE, non-clinical.
//
//     SI = AMo / (2 * Mo * MxDMn)
//
//   - Mo (s): the most common R-R value (centre of the highest-count histogram bin).
//   - AMo (%): share of intervals in the modal bin; a tall narrow peak means a rigid, sympathetic rhythm.
//   - MxDMn (s): max - min R-R; a wide range (flexible, vagal) lowers SI.
//
// Units follow the classic convention: R-R, Mo and MxDMn in SECONDS, AMo as 0-100, so SI is dimensionless.

public enum StressIndex {

    /// Histogram bin width in SECONDS; Baevsky's canonical 50 ms grid.
    public static let binWidthSec: Double = 0.05

    /// Minimum clean intervals before an SI is computed (the histogram needs a mode).
    public static let minBeats: Int = 20

    /// The intermediate histogram terms, exposed so the UI / a test can show the "why" behind an SI.
    public struct Components: Equatable, Sendable {
        /// Mode of the R-R histogram (s), centre of the most populated bin.
        public let moSec: Double
        /// Amplitude of the mode (%), share of intervals in the modal bin, 0–100.
        public let aMoPercent: Double
        /// Variation range MxDMn (s), max R-R minus min R-R over the cleaned series.
        public let mxDMnSec: Double
        /// SI = AMo / (2 * Mo * MxDMn).
        public let si: Double

        public init(moSec: Double, aMoPercent: Double, mxDMnSec: Double, si: Double) {
            self.moSec = moSec; self.aMoPercent = aMoPercent; self.mxDMnSec = mxDMnSec; self.si = si
        }
    }

    /// Baevsky Stress Index from R-R intervals (shared range + Malik ectopic cleaning). Nil when too few clean
    /// beats survive or MxDMn == 0 (all-equal beats), rather than Infinity.
    public static func stressIndex(rr: [RRInterval]) -> Double? {
        components(rr: rr)?.si
    }

    /// As `stressIndex(rr:)` but from a raw R-R series in milliseconds.
    public static func stressIndex(rawRR: [Double]) -> Double? {
        components(rawRR: rawRR)?.si
    }

    /// Full SI components from R-R intervals.
    public static func components(rr: [RRInterval]) -> Components? {
        components(rawRR: rr.map { Double($0.rrMs) })
    }

    /// Full SI components from a raw R-R series (ms).
    public static func components(rawRR: [Double]) -> Components? {
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }
        // #585 spot-honesty gate, as in HRVAnalyzer.analyze: a mostly-rejected capture is too noisy to label as stress.
        guard 1.0 - Double(clean.count) / Double(rawRR.count) <= HRVAnalyzer.defaultSpotMaxRejectedFraction else { return nil }

        // Work in seconds (Baevsky's convention).
        let sec = clean.map { $0 / 1000.0 }
        let minV = sec.min()!
        let maxV = sec.max()!
        let mxDMn = maxV - minV
        guard mxDMn > 0 else { return nil }   // all-equal beats: no histogram spread, SI undefined.

        // Bin index is floor((v - minV) / binWidth); the last value lands in the final bin.
        let binCount = max(1, Int((mxDMn / binWidthSec).rounded(.down)) + 1)
        var counts = [Int](repeating: 0, count: binCount)
        for v in sec {
            var idx = Int(((v - minV) / binWidthSec).rounded(.down))
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            counts[idx] += 1
        }
        // Modal bin: highest count; ties go to the LOWEST index (deterministic).
        var modeIdx = 0
        var modeCount = counts[0]
        for i in 1..<binCount where counts[i] > modeCount {
            modeCount = counts[i]
            modeIdx = i
        }
        // Mo is the modal bin's CENTRE (s).
        let mo = minV + (Double(modeIdx) + 0.5) * binWidthSec
        let aMo = Double(modeCount) / Double(sec.count) * 100.0   // percentage in the modal bin

        guard mo > 0 else { return nil }
        let si = aMo / (2.0 * mo * mxDMn)
        return Components(moSec: mo, aMoPercent: aMo, mxDMnSec: mxDMn, si: si)
    }
}
