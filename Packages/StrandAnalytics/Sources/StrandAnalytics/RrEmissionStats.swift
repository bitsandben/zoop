import Foundation

/// Pre-storage census of a decoded R-R batch (#1008/#1118 instrumentation; nothing in the shipped path reads it).
///
/// Every stored R-R number (`rrCoverage`, `collapsedCoverage`, `hrv diag`) is measured after storage, so it can't
/// tell whether the WHOOP 4.0 over-count is the strap/decoder emitting more beat-time than elapsed, or the same
/// beats being stored twice by two ingest passes. `ratio` (sum of rrMs over the batch's own wall span, before
/// SQLite) settles it: near the ~1.7 the nightly diag reports means the defect is upstream of the database; near
/// 1.0 means duplication is in ingest. `perSecond` gives the shape: at ~69 bpm a one-second record carries one
/// interval (occasionally two), so a fat 3-4 tail looks like an overlapping strap buffer.
///
/// There is deliberately no cross-second repeat counter: a verbatim repeat can't be told from a steady heart
/// (consecutive resting intervals are near-identical), so it read 9 "repeats" in 10 honest beats. `ratio` is
/// bounded by physics instead. Pure and framework-free.
public enum RrEmissionStats {

    public struct Result: Equatable, Sendable {
        /// Distinct timestamps carrying at least one interval (~records that reported R-R).
        public let secondsWithRr: Int
        /// Total intervals offered by the decoder, before storage de-dup.
        public let intervals: Int
        /// Sum of every interval, in milliseconds.
        public let sumRrMs: Int
        /// Wall span the batch covers, inclusive, in seconds; 0 when fewer than one timestamp.
        public let spanSec: Int
        /// `sumRrMs / 1000 / spanSec`: beat-time per wall second. Above 1 is physically impossible, so an emission or decode defect rather than a heart.
        public let ratio: Double
        /// Histogram of intervals per second: index 0 = exactly 1, 1 = 2, 2 = 3, 3 = 4 or more.
        public let perSecond: [Int]
        /// Histogram of the gap (seconds) between consecutive records that carried R-R: index 0 = 1 s ... 6 = 7 s, 7 = 8 s or
        /// more. Healthy `ratioRep` ~ the mean of these gaps (a strap banking R-R every 5 s reads ~5 while healthy, so
        /// comparing against 1.0 would invent a defect, #1451). Ties resolve to the smaller gap on both platforms.
        public let gapHist: [Int]
        /// Histogram of per-record fill: a record's sum(rrMs) over its slot (gap to the next R-R-carrying record):
        /// index 0 = <=1.0, 1 = <=1.5, 2 = <=2.0, 3 = >2.0. Fill ~1.0 means records tile the timeline; a fat tail means
        /// records overflow and no placement built on the record timestamp can be correct. The final record is excluded.
        /// Bias: interleaved intervalless records widen the slot and read fill LOW, so it can understate overflow, never manufacture it.
        public let fill: [Int]

        public init(secondsWithRr: Int, intervals: Int, sumRrMs: Int, spanSec: Int,
                    ratio: Double, perSecond: [Int],
                    gapHist: [Int] = [0, 0, 0, 0, 0, 0, 0, 0], fill: [Int] = [0, 0, 0, 0]) {
            self.secondsWithRr = secondsWithRr
            self.intervals = intervals
            self.sumRrMs = sumRrMs
            self.spanSec = spanSec
            self.ratio = ratio
            self.perSecond = perSecond
            self.gapHist = gapHist
            self.fill = fill
        }

        /// Modal record gap in seconds (the mode of `gapHist`, 8 = "8 or more"); 0 with fewer than two records. The healthy baseline for `ratioRep`.
        public var modalGapSec: Int {
            guard let m = gapHist.max(), m > 0, let i = gapHist.firstIndex(of: m) else { return 0 }
            return i + 1
        }
    }

    /// Census of a decoded batch; `rr` is the decoder's output order and is not mutated.
    public static func compute(_ rr: [(ts: Int, rrMs: Int)]) -> Result {
        guard !rr.isEmpty else {
            return Result(secondsWithRr: 0, intervals: 0, sumRrMs: 0, spanSec: 0,
                          ratio: 0, perSecond: [0, 0, 0, 0])
        }
        var bySecond: [Int: [Int]] = [:]
        var sum = 0
        var minTs = Int.max
        var maxTs = Int.min
        for r in rr {
            bySecond[r.ts, default: []].append(r.rrMs)
            sum += r.rrMs
            if r.ts < minTs { minTs = r.ts }
            if r.ts > maxTs { maxTs = r.ts }
        }
        // Inclusive span so a single-second batch spans 1 s and the ratio stays finite.
        let span = maxTs - minTs + 1
        var hist = [0, 0, 0, 0]
        for (_, vals) in bySecond {
            let i = min(vals.count, 4) - 1
            if i >= 0 { hist[i] += 1 }
        }
        // Per-record cadence and fill (#1451); the last record has no successor to bound its slot, so it is excluded.
        let stamps = bySecond.keys.sorted()
        var gapHist = [0, 0, 0, 0, 0, 0, 0, 0]
        var fill = [0, 0, 0, 0]
        if stamps.count >= 2 {
            for i in 0..<(stamps.count - 1) {
                let gap = stamps[i + 1] - stamps[i]
                guard gap >= 1 else { continue }
                gapHist[min(gap, 8) - 1] += 1
                let recSum = (bySecond[stamps[i]] ?? []).reduce(0, +)
                let f = Double(recSum) / 1000.0 / Double(gap)
                fill[f <= 1.0 ? 0 : (f <= 1.5 ? 1 : (f <= 2.0 ? 2 : 3))] += 1
            }
        }
        let ratio = span > 0 ? Double(sum) / 1000.0 / Double(span) : 0
        return Result(secondsWithRr: bySecond.count, intervals: rr.count, sumRrMs: sum,
                      spanSec: span, ratio: ratio, perSecond: hist, gapHist: gapHist, fill: fill)
    }

    /// 15 minutes: rare enough not to bury the log, frequent enough to sample a night several times.
    public static let liveCensusMinGapSec: Int = 900

    /// Whether a LIVE census line should be emitted now (#1118). The two live paths flush ~every 30 readings, so
    /// per-flush emission would bury the log; one line per path per `minGapSec` suffices. `lastEmitSec` is 0 before
    /// the first line (the first flush always reports). A backwards clock emits rather than wedging the census shut.
    public static func shouldEmitLiveCensus(lastEmitSec: Int, nowSec: Int,
                                            minGapSec: Int = liveCensusMinGapSec) -> Bool {
        // Check the "never emitted" sentinel explicitly: relying on the gap arithmetic only works because a real unix `nowSec` (~1.8e9) clears any gap, and it made the helper untestable with small timestamps.
        if lastEmitSec <= 0 { return true }
        if nowSec < lastEmitSec { return true }
        return nowSec - lastEmitSec >= minGapSec
    }

    /// One compact log line. `inserted` is what the store wrote after its `ON CONFLICT` key, so `offered - inserted`
    /// is what the primary key already absorbs.
    ///
    /// Two ratios print because `ratio` alone misreads a whole session: draining a gap (strap off wrist or on charger)
    /// adds wall time with no beats and pulls `ratio` DOWN, the dangerous direction, since 0.9 reads as "emission is
    /// fine". `ratioRep` divides by seconds that actually reported R-R, so it is immune to gaps; when the two disagree
    /// trust `ratioRep` (it can double-count at most one second per chunk boundary, erring low).
    public static func logLine(path: String, offered: Int, inserted: Int?, _ r: Result) -> String {
        // Nil renders "n/a": only the historical path sees what the conflict key kept, and echoing `offered` on the live paths would falsely read as "the primary key absorbed nothing".
        let ins = inserted.map(String.init) ?? "n/a"
        let ratio = String(format: "%.2f", r.ratio)
        let rep = r.secondsWithRr > 0 ? Double(r.sumRrMs) / 1000.0 / Double(r.secondsWithRr) : 0
        let h = r.perSecond
        return "rr emit path=\(path) offered=\(offered) inserted=\(ins) secs=\(r.secondsWithRr) "
            + "sumRr=\(r.sumRrMs / 1000)s span=\(r.spanSec)s ratio=\(ratio) "
            + "ratioRep=\(String(format: "%.2f", rep)) "
            + "perSec[1/2/3/4+]=\(h[0])/\(h[1])/\(h[2])/\(h[3]) "
            + "modalGap=\(r.modalGapSec)s "
            + "fill[<=1/<=1.5/<=2/>2]=\(r.fill[0])/\(r.fill[1])/\(r.fill[2])/\(r.fill[3])"
    }
}
