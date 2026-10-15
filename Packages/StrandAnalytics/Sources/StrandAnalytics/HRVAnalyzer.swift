import Foundation
import WhoopProtocol

// HRVAnalyzer.swift - RMSSD + SDNN from RR intervals with cleaning.
//
// Task Force (1996) definitions:
//   RMSSD = sqrt(mean((NN[i+1] - NN[i])^2));  SDNN = sample standard deviation of NN (ddof = 1)
//
// Cleaning pipeline:
//   1. Range filter: drop intervals outside [300, 2000] ms.
//   2. Ectopic rejection: drop beats deviating > ~20% from a local median (Malik et al. 1989).
//   3. Require >= minBeats (20) valid intervals for a trustworthy result.
//
// The Malik rule stands in for the Kubios / Lipponen-Tarvainen (2019) artifact classifier, which is
// unavailable on-device: simpler and deterministic, but it does not model missed/extra-beat insertion.

public enum HRVAnalyzer {

    /// Minimum plausible RR interval (ms); 300 ms is ~200 bpm.
    public static let rrMinMs: Double = 300
    /// Maximum plausible RR interval (ms); 2000 ms is ~30 bpm.
    public static let rrMaxMs: Double = 2000
    public static let minBeats: Int = 20
    /// Malik-style ectopic threshold: a beat deviating more than this fraction (20%) from the local median is rejected.
    public static let ectopicThreshold: Double = 0.20
    /// Half-width (beats) of the local-median window for ectopic rejection; 2*radius+1 = 5 beats matches
    /// common Malik moving-window implementations.
    public static let ectopicWindowRadius: Int = 2

    /// Default ceiling on the fraction of input beats the cleaning may reject before a SPOT reading is
    /// refused as too noisy (#585): 0.35, even if `minBeats` clean intervals survive. Spot-only; the
    /// nightly windowed path never passes it.
    public static let defaultSpotMaxRejectedFraction: Double = 0.35

    /// Result of an HRV computation over a window.
    public struct HRVResult: Equatable, Sendable {
        public let rmssd: Double?
        /// SDNN (sample SD, ddof=1) in ms, or nil when too few valid beats. Callers holding timestamps
        /// should refuse it when `beatSpreadIsTrustworthy` or `beatValuesAreTrustworthy` is false (an
        /// over-counted or banked capture inflates a spread); `analyze` gets intervals, not times.
        public let sdnn: Double?
        public let meanNN: Double?
        public let pnn50: Double?
        public let nInput: Int
        public let nClean: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int) {
            self.rmssd = rmssd
            self.sdnn = sdnn
            self.meanNN = meanNN
            self.pnn50 = pnn50
            self.nInput = nInput
            self.nClean = nClean
        }

        static func empty(nInput: Int) -> HRVResult {
            HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                      nInput: nInput, nClean: 0)
        }
    }

    // MARK: - Primitive Task Force statistics (no filtering)

    /// Task Force RMSSD over already-clean NN intervals (ms); nil with fewer than 2 values.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(nn.count - 1)).squareRoot()
    }

    /// Sample SD (ddof = 1) of NN intervals (ms), matching neurokit2 HRV_SDNN; nil with fewer than 2 values.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        var ss = 0.0
        for v in nn { let d = v - mean; ss += d * d }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    // MARK: - Cleaning

    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Malik-style ectopic rejection: drops any beat deviating from its local median (centred window
    /// of `2*ectopicWindowRadius+1`, excluding the beat) by more than `ectopicThreshold`; beats with too
    /// small a neighbourhood are kept.
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        guard nn.count > ectopicWindowRadius else { return nn }
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            guard neighbours.count >= 2 else { kept.append(nn[i]); continue }
            let med = median(neighbours)
            if med <= 0 { kept.append(nn[i]); continue }
            let deviation = abs(nn[i] - med) / med
            if deviation <= ectopicThreshold {
                kept.append(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /// Full clean: range filter then ectopic rejection.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        rejectEctopic(rangeFilter(rr))
    }

    // MARK: - Gap-aware cleaning (successive-difference safety) - #204/#195

    /// A cleaned NN series that remembers where beats were dropped. `nn` equals `cleanRR`; `contiguous[i]`
    /// is true when `nn[i]` and `nn[i-1]` were adjacent in the ORIGINAL series (no beat removed between
    /// them) and false across a splice. Index 0 is always false.
    public struct CleanSeries: Equatable, Sendable {
        public let nn: [Double]
        public let contiguous: [Bool]
    }

    /// Cleans like `cleanRR` while tracking dropped beats, so successive-difference metrics can skip
    /// the difference across a removed beat.
    public static func cleanRRGapAware(_ rr: [Double]) -> CleanSeries {
        // Pass 1: range filter, keeping each survivor's original index.
        var rangedIdx: [Int] = []; rangedIdx.reserveCapacity(rr.count)
        var rangedVal: [Double] = []; rangedVal.reserveCapacity(rr.count)
        for i in 0..<rr.count {
            let v = rr[i]
            if v >= rrMinMs && v <= rrMaxMs { rangedIdx.append(i); rangedVal.append(v) }
        }
        // Pass 2: Malik rejection over the range-filtered values, mirroring `rejectEctopic` exactly while
        // carrying each survivor's original index.
        var keptOrig: [Int] = []; keptOrig.reserveCapacity(rangedVal.count)
        var keptVal: [Double] = []; keptVal.reserveCapacity(rangedVal.count)
        if rangedVal.count <= ectopicWindowRadius {
            // rejectEctopic returns the input unchanged for a series this short.
            for k in 0..<rangedVal.count { keptOrig.append(rangedIdx[k]); keptVal.append(rangedVal[k]) }
        } else {
            for i in 0..<rangedVal.count {
                let lo = max(0, i - ectopicWindowRadius)
                let hi = min(rangedVal.count - 1, i + ectopicWindowRadius)
                var neighbours: [Double] = []; neighbours.reserveCapacity(hi - lo)
                for j in lo...hi where j != i { neighbours.append(rangedVal[j]) }
                let keep: Bool
                if neighbours.count < 2 {
                    keep = true
                } else {
                    let med = median(neighbours)
                    keep = med <= 0 ? true : abs(rangedVal[i] - med) / med <= ectopicThreshold
                }
                if keep { keptOrig.append(rangedIdx[i]); keptVal.append(rangedVal[i]) }
            }
        }
        // Contiguous with the predecessor only when the original indices are adjacent.
        var contiguous: [Bool] = []; contiguous.reserveCapacity(keptVal.count)
        for i in 0..<keptVal.count { contiguous.append(i > 0 && keptOrig[i] == keptOrig[i - 1] + 1) }
        return CleanSeries(nn: keptVal, contiguous: contiguous)
    }

    /// Task Force RMSSD counting a successive difference only when both beats were adjacent in the
    /// source (`CleanSeries.contiguous`), so a removed beat can't splice neighbours into a spurious
    /// delta. Equals `rmssdRaw` with no gaps; nil when no valid difference exists.
    public static func rmssdGapAware(_ nn: [Double], _ contiguous: [Bool]) -> Double? {
        precondition(nn.count == contiguous.count, "nn and contiguous must be the same length")
        var sumSq = 0.0
        var count = 0
        var i = 1
        while i < nn.count {
            if contiguous[i] {
                let d = nn[i] - nn[i - 1]
                sumSq += d * d
                count += 1
            }
            i += 1
        }
        return count < 1 ? nil : (sumSq / Double(count)).squareRoot()
    }

    /// pNN50 counting a successive pair only when adjacent in the source; nil when no valid pair exists.
    public static func pnn50GapAware(_ nn: [Double], _ contiguous: [Bool]) -> Double? {
        precondition(nn.count == contiguous.count, "nn and contiguous must be the same length")
        var nn50 = 0
        var pairs = 0
        var i = 1
        while i < nn.count {
            if contiguous[i] {
                if abs(nn[i] - nn[i - 1]) > 50.0 { nn50 += 1 }
                pairs += 1
            }
            i += 1
        }
        return pairs < 1 ? nil : Double(nn50) / Double(pairs) * 100.0
    }

    // MARK: - Windowed analysis

    /// Computes HRV (RMSSD/SDNN/meanNN/pNN50) over the intervals whose ts falls in [windowStart,
    /// windowEnd] (inclusive; nil bounds use all rows). Range filter, Malik rejection, then `minBeats`
    /// clean intervals are required, else an empty result.
    public static func analyze(_ rr: [RRInterval],
                               windowStart: Int? = nil,
                               windowEnd: Int? = nil) -> HRVResult {
        let inWindow = rr.filter { sample in
            if let s = windowStart, sample.ts < s { return false }
            if let e = windowEnd, sample.ts > e { return false }
            return true
        }
        let raw = inWindow.map { Double($0.rrMs) }
        return analyze(rawRR: raw)
    }

    /// Computes HRV from raw RR values (ms) with the full cleaning pipeline; empty when fewer than
    /// `minBeats` survive.
    ///
    /// - Parameter maxRejectedFraction: spot-only honesty gate (#585). When non-nil, the reading is also
    ///   refused if the fraction of input beats dropped by cleaning exceeds it. nil (the nightly
    ///   windowed path) skips the gate.
    public static func analyze(rawRR: [Double], maxRejectedFraction: Double? = nil) -> HRVResult {
        let nInput = rawRR.count
        let cleaned = cleanRRGapAware(rawRR)
        let clean = cleaned.nn
        guard clean.count >= minBeats else {
            return .empty(nInput: nInput)
        }
        // Spot-only: refuse when too large a fraction of beats was noise. A nInput == 0 guard is implicit
        // (clean >= minBeats > 0).
        if let maxRejectedFraction, nInput > 0 {
            let rejectedFraction = 1.0 - Double(clean.count) / Double(nInput)
            if rejectedFraction > maxRejectedFraction {
                return .empty(nInput: nInput)
            }
        }
        // RMSSD and pNN50 are gap-aware (#204/#195): a difference across a dropped beat is skipped.
        // SDNN and meanNN use every clean beat, so they are unchanged.
        let rmssd = rmssdGapAware(cleaned.nn, cleaned.contiguous)
        let sdnn = sdnnRaw(clean)
        let mean = clean.reduce(0, +) / Double(clean.count)
        let pnn50 = pnn50GapAware(cleaned.nn, cleaned.contiguous)

        return HRVResult(rmssd: rmssd, sdnn: sdnn, meanNN: mean, pnn50: pnn50,
                         nInput: nInput, nClean: clean.count)
    }

    /// SDNN index (Task Force 1996): the mean of SDNN over consecutive fixed-length segments (default
    /// 5 min), each cleaned like the nightly path. Whole-night SDNN is dominated by slow HR drift across
    /// sleep stages (2-3x higher); the index reflects short-term variability and can be honestly
    /// cross-checked against a wearable's short SDNN (e.g. Apple Watch `heartRateVariabilitySDNN`).
    /// Segments under `minBeats` clean intervals are skipped; nil when none qualify.
    public static func sdnnIndex(_ rr: [RRInterval], segmentSec: Int = 300) -> Double? {
        guard segmentSec > 0, let first = rr.map(\.ts).min(), let last = rr.map(\.ts).max(),
              last >= first else { return nil }
        var segStart = first
        var segmentSDNNs: [Double] = []
        while segStart <= last {
            if let sd = analyze(rr, windowStart: segStart, windowEnd: segStart + segmentSec - 1).sdnn {
                segmentSDNNs.append(sd)
            }
            segStart += segmentSec
        }
        guard !segmentSDNNs.isEmpty else { return nil }
        return segmentSDNNs.reduce(0, +) / Double(segmentSDNNs.count)
    }

    // MARK: - Rolling / windowed rMSSD timeline (#803)

    /// One windowed rMSSD point: the rMSSD (ms) over the trailing `windowSec` of R-R ending at `ts`
    /// (wall-clock unix seconds). The .hrv timeline plots a point per window so a report shows rMSSD
    /// moving across the session (#803).
    public struct RollingRmssdPoint: Equatable, Sendable {
        /// Wall-clock unix seconds of the last R-R interval in this window (its right edge).
        public let ts: Int
        public let rmssd: Double
        public init(ts: Int, rmssd: Double) { self.ts = ts; self.rmssd = rmssd }
    }

    /// Rolling rMSSD over an R-R series (#803): for each interval at `ts`, the window `(ts - windowSec, ts]`
    /// is cleaned with `cleanRR` and a point emitted only with at least `minBeatsPerWindow` survivors
    /// (default 8; a short window holds far fewer beats than `minBeats`). `stepSec` thins output to one
    /// point per that many seconds (0 = every interval). `rr` is sorted by `ts` internally.
    public static func rollingRmssd(rr: [RRInterval],
                                    windowSec: Int,
                                    stepSec: Int = 0,
                                    minBeatsPerWindow: Int = 8) -> [RollingRmssdPoint] {
        guard windowSec > 0, rr.count >= minBeatsPerWindow else { return [] }
        // Stable: preserves the store's emission order for same-second beats (#823), which RMSSD needs.
        let sorted = rr.sortedByTsStable()
        var out: [RollingRmssdPoint] = []
        var lastEmitTs: Int? = nil
        var left = 0   // index of the oldest interval still inside the trailing window
        for right in 0..<sorted.count {
            let edgeTs = sorted[right].ts
            // Advance the left edge so [left, right] covers exactly (edgeTs - windowSec, edgeTs].
            while left < right && edgeTs - sorted[left].ts >= windowSec { left += 1 }
            // Thinning stride: skip until `stepSec` has passed since the last emitted point.
            if stepSec > 0, let last = lastEmitTs, edgeTs - last < stepSec { continue }
            // Gap-aware like the nightly `analyze` (#1448): dropping a beat joins non-adjacent intervals whose
            // difference is a splice. A window with no adjacent survivor pair emits nothing.
            let windowRaw = sorted[left...right].map { Double($0.rrMs) }
            let cleaned = cleanRRGapAware(windowRaw)
            guard cleaned.nn.count >= minBeatsPerWindow,
                  let r = rmssdGapAware(cleaned.nn, cleaned.contiguous) else { continue }
            out.append(RollingRmssdPoint(ts: edgeTs, rmssd: r))
            lastEmitTs = edgeTs
        }
        return out
    }

    // MARK: - R-R integrity diagnostics (#257)

    /// What a night's R-R coverage pair says about the capture (#550). Read together, `rrCoverage`
    /// (above 1.0 is physically impossible) and `collapsedCoverage` (what a same-second de-dup would
    /// leave) say WHICH over-count there is.
    public enum RrCoverageVerdict: String, Equatable, Sendable {
        /// At or near 1.0: the beat-time fits the wall clock.
        case plausible
        /// Materially below 1.0: beat-time is missing, so the analysis window is not the window it appears
        /// to be. Not a clean night and not an over-count (#977).
        case underCovered
        /// Over-covered, but collapsing same-second duplicates brings it back in range.
        case sameSecondOverCount
        /// Still over-covered after the same-second collapse: duplicates straddle second boundaries.
        case crossSecondOverCount
        /// No usable coverage figure (`rrCoverage` returns 0 for < 2 beats or a zero span). Absence of
        /// evidence, not a clean night, so never reported as `plausible`.
        case unmeasurable
    }

    /// Whether a window's beat-spread statistics (SDNN and anything derived) can be trusted given its
    /// coverage verdict. A capture holding beats twice reports a spread no heart produced (a ring
    /// banking 1.25x its wall-clock read SDNN 197 ms). Only the two over-count verdicts gate:
    /// `underCovered` and `unmeasurable` duplicate no beat, and `unmeasurable` is what a live spot
    /// reading looks like. RMSSD / pNN50: `successiveDiffIsTrustworthy`; beat accuracy:
    /// `beatValuesAreTrustworthy`.
    public static func beatSpreadIsTrustworthy(_ verdict: RrCoverageVerdict) -> Bool {
        switch verdict {
        case .sameSecondOverCount, .crossSecondOverCount:
            return false
        case .plausible, .underCovered, .unmeasurable:
            return true
        }
    }

    /// Whether RMSSD / pNN50 can be trusted given the coverage verdict (#1118). The same two verdicts
    /// refuse as in `beatSpreadIsTrustworthy`, for a different reason: a beat the heart never produced
    /// sits beside its neighbour with a near-zero difference, so an over-counted night's RMSSD reads LOW
    /// (36 ms vs 41 ms collapsed, on a WHOOP 4.0 night banking 2.13x). The write-path fix (#823 / #1072)
    /// did not make the stream clean: post-fix captures still report `crossSecondOverCount`.
    ///
    /// Withhold, do not fabricate: a contaminated RMSSD would enter the personal baseline later nights
    /// are scored against. `Baselines.update` holds on a nil night without advancing `nValid`, so an
    /// install where every night gates (WHOOP 4.0-only) never reaches `Baselines.minNightsSeed`. That is
    /// deliberate; a mixed install's clean nights seed the baseline.
    public static func successiveDiffIsTrustworthy(_ verdict: RrCoverageVerdict) -> Bool {
        switch verdict {
        case .sameSecondOverCount, .crossSecondOverCount:
            return false
        case .plausible, .underCovered, .unmeasurable:
            return true
        }
    }

    /// Whether a live spot capture collected more beat time than the wall clock allows (it has no
    /// per-beat timestamps for `rrCoverage`, but knows how long it ran). Only over-count rejects;
    /// sparse windows stay with the `minBeats` gate. Pure.
    public static func spotCaptureOverCounted(beatTimeMs: Double, captureMs: Double) -> Bool {
        captureMs > 0 && beatTimeMs > captureMs * coveragePlausibleCeiling
    }

    /// The fraction of consecutive beats whose `ts` step is within `beatAccuracyToleranceS` of their
    /// interval. Pure. 1.0 for fewer than 2 beats (absence of evidence is not evidence of banking).
    ///
    /// A beat-accurate stream steps one interval per beat, so the fraction is ~1.0 (WHOOP R-R, live
    /// spot readings, fixtures). A banked stream stamps a whole record on one coarse timestamp, so
    /// nearly every gap is 0 s against a ~1 s value and the fraction collapses toward 0.
    public static func beatAccurateFraction(tsSec: [Int], rrMs: [Double]) -> Double {
        guard tsSec.count == rrMs.count, tsSec.count >= 2 else { return 1.0 }
        var accurate = 0
        for i in 1..<tsSec.count {
            let gapS = Double(tsSec[i] - tsSec[i - 1])
            if abs(gapS - rrMs[i] / 1000.0) <= beatAccuracyToleranceS { accurate += 1 }
        }
        return Double(accurate) / Double(tsSec.count - 1)
    }

    /// Tolerance (seconds) between a beat's wall-clock gap and its own R-R value before it counts as not
    /// time-accurate. Deliberately loose: whole-second `ts` against a sub-second interval still rounds.
    ///
    /// Shared with the RSA respiration gate (#882/#883), which calls `beatAccurateFraction` /
    /// `beatValuesAreTrustworthy` directly, so a threshold change moves respiration and SDNN together.
    public static let beatAccuracyToleranceS: Double = 0.5

    /// Fraction of beats that must be time-accurate before beat-value statistics are trusted.
    ///
    /// Not a tuned threshold: a beat-accurate stream measures ~100%, and every banked Oura overnight
    /// measured to date sits at 2.6-6.6% (five nights, 2026-07-29 to 08-06). The middle is a stream we
    /// have never seen and should not guess about.
    public static let beatAccuracyMinFraction: Double = 0.5

    /// Whether a window's beat-value statistics (SDNN above all) can be trusted given how time-accurate
    /// its beats are. A separate failure from `beatSpreadIsTrustworthy`'s (a beat held twice): is each
    /// stored interval a real beat-to-beat measurement? A banked stream can be perfectly covered (the
    /// 2026-08-06 Oura night: coverage 1.03) and still report SDNN 174 ms, because the ring decomposes
    /// each ~6.5 s record into 6 intervals whose sum is right to ~1% (so `meanNN` and resting HR stay
    /// correct) but whose values are not beat-to-beat accurate. Widening the ectopic window doesn't reach
    /// it (radius 2 to 20: 124 to 99 ms); the fault is in the decomposition, not outliers. RMSSD / pNN50
    /// are not gated here; see `successiveDiffIsTrustworthy`.
    public static func beatValuesAreTrustworthy(beatAccurateFraction: Double) -> Bool {
        // Negated `<` so a NaN input lands on `true`: NaN means "not measured" and must not be silently
        // refused. Matches the NaN convention in `classifyCoverage`.
        !(beatAccurateFraction < beatAccuracyMinFraction)
    }

    /// Tolerance below 1.0 treated as "fits", the mirror of `coveragePlausibleCeiling`. A rounding
    /// allowance, not a tuned threshold (whole-second timestamps under-report as easily as they over-report);
    /// the real boundary needs coverage figures from several wearers, which `IntelligenceEngine` logs in
    /// the `hrv diag` line (#977). Symmetric rather than fitted to one corpus.
    ///
    /// Derived (1 - (ceiling - 1)) so it can't drift if the ceiling moves; IEEE-754 makes it
    /// 0.8999999999999999, harmless and identical across platforms.
    public static let coveragePlausibleFloor: Double = 1.0 - (coveragePlausibleCeiling - 1.0)

    /// Tolerance above 1.0 treated as "fits". R-R timestamps are whole seconds while beats are not, so a
    /// clean night can round fractionally over. A rounding allowance, not a tuned threshold.
    public static let coveragePlausibleCeiling: Double = 1.10

    /// Classifies a night from its coverage pair. Pure. Uses the negated `>` form rather than `<=` so
    /// a non-finite input lands identically everywhere (every NaN comparison is false); NaN falls to `.unmeasurable`.
    public static func classifyCoverage(coverage: Double, collapsed: Double) -> RrCoverageVerdict {
        guard coverage > 0 else { return .unmeasurable }
        // The floor is tested before the ceiling so the negated-`>` NaN convention holds: a non-finite
        // coverage already left via `unmeasurable`.
        guard coverage >= coveragePlausibleFloor else { return .underCovered }
        guard coverage > coveragePlausibleCeiling else { return .plausible }
        return collapsed > coveragePlausibleCeiling ? .crossSecondOverCount : .sameSecondOverCount
    }

    /// Total beat-time (sum of NN, ms) over the wall-clock span of the R-R window (ms). Above ~1.0 is
    /// physically impossible and flags double-counted R-R (e.g. a live + historical merge storing one beat
    /// under two timestamps, which inflates HRV and drags resting HR down, #257). 0 for < 2 beats or a zero span.
    public static func rrCoverage(tsSec: [Int], rrMs: [Double]) -> Double {
        guard tsSec.count >= 2, !rrMs.isEmpty, let lo = tsSec.min(), let hi = tsSec.max() else { return 0 }
        let spanMs = Double(hi - lo) * 1000
        guard spanMs > 0 else { return 0 }
        return rrMs.reduce(0, +) / spanMs
    }

    /// How many R-R rows are exact duplicates of another (same ts, rrMs): `total - distinct(ts, rrMs)`.
    /// Points at the double-insert mechanism when `rrCoverage` > 1.
    public static func duplicateBeatCount(tsSec: [Int], rrMs: [Double]) -> Int {
        struct Key: Hashable { let ts: Int; let rr: Double }
        let n = min(tsSec.count, rrMs.count)
        var seen = Set<Key>()
        var dups = 0
        for i in 0..<n where !seen.insert(Key(ts: tsSec[i], rr: rrMs[i])).inserted { dups += 1 }
        return dups
    }

    /// Coverage after collapsing same-second near-duplicate beats (equal ts and |drr| <= `rrTolMs`) to
    /// one representative (#550): a preview for the always-on #257 diag only; it does not feed the
    /// nightly HRV. Same-second-only because ts are second-resolution and genuine consecutive beats are
    /// ~1 s apart. If coverage stays well above 1 the duplication is cross-second.
    ///
    /// Shadow de-dup of the WHOOP 4.0 over-count (#1008/#1118/#1331): a same-second beat within `rrTolMs`
    /// of one already kept (exact duplicates and the two-channel ~34 ms pairs, hence a wider default than
    /// `collapsedCoverage`'s 30 ms) is dropped. Returns `(tsSec, rrMs)` in ts-ascending order.
    /// Instrumentation only: the `hrv diag` line logs raw and deduped streams so it can be validated
    /// against WHOOP's own numbers and a Polar H10 (#1118) before it becomes the read path.
    /// `windowSec > 0` also collapses near-identical intervals within that many seconds; an aggressive
    /// upper bound that WILL over-merge real neighbours (steady HR), sizing the cross-second share (#1331).
    public static func collapseOverCount(tsSec: [Int], rrMs: [Double], rrTolMs: Double = 40, windowSec: Int = 0)
        -> (tsSec: [Int], rrMs: [Double]) {
        let n = min(tsSec.count, rrMs.count)
        guard n >= 2 else { return (tsSec, rrMs) }
        let order = (0..<n).sorted { a, b in (tsSec[a], rrMs[a], a) < (tsSec[b], rrMs[b], b) }
        var keptTs: [Int] = []
        var keptRr: [Double] = []
        for idx in order {
            let t = tsSec[idx]
            let r = rrMs[idx]
            var dup = false
            var j = keptTs.count - 1
            while j >= 0 && t - keptTs[j] <= windowSec {   // beats kept within `windowSec` (0 ⇒ same second)
                if abs(keptRr[j] - r) <= rrTolMs { dup = true; break }
                j -= 1
            }
            if !dup { keptTs.append(t); keptRr.append(r) }
        }
        return (keptTs, keptRr)
    }

    public static func collapsedCoverage(tsSec: [Int], rrMs: [Double], rrTolMs: Double = 30) -> Double {
        let n = min(tsSec.count, rrMs.count)
        guard n >= 2 else { return 0 }
        let order = (0..<n).sorted { a, b in
            (tsSec[a], rrMs[a], a) < (tsSec[b], rrMs[b], b)
        }
        var keptTs: [Int] = []
        var keptRr: [Double] = []
        for idx in order {
            let t = tsSec[idx]
            let r = rrMs[idx]
            var dup = false
            var j = keptTs.count - 1
            while j >= 0 && keptTs[j] == t {      // inspect only beats already kept in the SAME second
                if abs(keptRr[j] - r) <= rrTolMs { dup = true; break }
                j -= 1
            }
            if !dup { keptTs.append(t); keptRr.append(r) }
        }
        return rrCoverage(tsSec: keptTs, rrMs: keptRr)
    }

    /// One second's tallies for `deliveryHistogram`, in a single dictionary so each row costs one hash
    /// lookup. A class, not a struct: mutating through a reference avoids a read-modify-write-back.
    final class SecondTally {
        var knownRows = 0
        var ms = 0.0
        var deliveries = 0
    }

    /// How many separate deliveries wrote each stored second across a night (#1331/#1008). `ord`
    /// restarts at 0 per delivery, so two rows on one second both with `ord == 0` came from two offloads.
    /// Answers whether the over-count is mostly multi-delivery seconds or too many beats in one.
    ///
    /// `multiMs` is the share of attributable beat-time on those seconds (what inflates coverage);
    /// `multiRows` is a share of attributable rows (those with an `ord`) so a night that half-predates
    /// `ord` doesn't read benign. Nil-`ord` rows count in `ordUnknown` and are excluded. Percentages are
    /// integer half-up on both platforms (#1473).
    public static func deliveryHistogram(tsSec: [Int], rrMs: [Double], ords: [Int?]) -> String {
        let n = min(tsSec.count, rrMs.count)
        guard n > 0 else { return "" }
        // One dictionary keyed by second, not four parallel ones: this runs once per over-counted night,
        // ~21 times per `analyzeRecent` cycle, over ~70k rows a night.
        var bySec: [Int: SecondTally] = [:]
        var unknown = 0
        var known = 0
        var knownMs = 0.0
        for i in 0 ..< n {
            let tally: SecondTally
            if let existing = bySec[tsSec[i]] {
                tally = existing
            } else {
                tally = SecondTally()
                bySec[tsSec[i]] = tally
            }
            if i < ords.count, let o = ords[i] {
                known += 1
                knownMs += rrMs[i]
                tally.knownRows += 1
                tally.ms += rrMs[i]
                if o == 0 { tally.deliveries += 1 }
            } else {
                unknown += 1
            }
        }
        var hist = [0, 0, 0, 0]      // 1, 2, 3, 4+
        var multiSecs = 0
        var multiRows = 0
        var multiMs = 0.0
        var maxDeliv = 0
        var secs = 0
        for (_, tally) in bySec where tally.deliveries > 0 {
            secs += 1
            hist[min(tally.deliveries, 4) - 1] += 1
            if tally.deliveries > maxDeliv { maxDeliv = tally.deliveries }
            if tally.deliveries >= 2 {
                multiSecs += 1
                multiRows += tally.knownRows
                multiMs += tally.ms
            }
        }
        // Seconds carrying rows but no ord==0 row (the primary key can absorb a cross-batch duplicate that
        // was the delivery's first). Reported separately so `secs` staying below the night's second count is visible.
        let secsNoStart = bySec.count - secs
        return "rr deliveries secs[1/2/3/4+]=\(hist[0])/\(hist[1])/\(hist[2])/\(hist[3])"
            + " multiSec=\(pct(multiSecs, secs))% multiRows=\(pct(multiRows, known))%"
            + " multiMs=\(pct(msToInt(multiMs), msToInt(knownMs)))%"
            + " maxDeliv=\(maxDeliv) secsNoStart=\(secsNoStart) ordUnknown=\(unknown)"
    }

    /// Beat-time milliseconds to a whole number, half-up, without `rounded()`: Swift's is half-away-from-zero
    /// and Kotlin's `round` half-toward-positive-infinity, agreeing only because sums are positive.
    /// `x + 0.5` truncated is half-up on both by construction.
    /// One second's duplicate-pair bookkeeping: row count, the first two intervals, and whether every
    /// row claimed `ord == 0`. Only a second with exactly two rows, both `ord 0`, is an unambiguous
    /// two-delivery pair (see `duplicatePairRatios`).
    final class PairTally {
        var count = 0
        var first = 0
        var second = 0
        var allOrdZero = true
        var qualifies: Bool { count == 2 && allOrdZero }
        func add(ms: Int, ord: Int) {
            count += 1
            if count == 1 { first = ms } else if count == 2 { second = ms }
            if ord != 0 { allOrdZero = false }
        }
    }

    /// When two deliveries wrote the same second, how do their two intervals compare? (#1505) A WHOOP 5
    /// emits the beat train live over `0x2A37` (1/1024-second units, converted on the way in) and again
    /// in its v18 historical record (stored as read); the same beat in two units gives values 1024/1000
    /// apart. Restricted to seconds with exactly two rows, both `ord == 0`. One pair proves nothing; a
    /// population does (a tight cluster at 1.024 is a unit mismatch). Reports the distribution, takes no
    /// view; parts-per-thousand integer arithmetic so platforms can't round a tie differently.
    public static func duplicatePairRatios(tsSec: [Int], rrMs: [Double], ords: [Int?]) -> String {
        let n = min(tsSec.count, rrMs.count, ords.count)
        guard n > 0 else { return "" }
        // A tally per second rather than an array per second, as `SecondTally`: this runs over a whole
        // night's beats on the same path.
        var bySec: [Int: PairTally] = [:]
        for i in 0 ..< n {
            guard let o = ords[i] else { continue }
            let ms = msToInt(rrMs[i])
            guard ms > 0 else { continue }
            let tally: PairTally
            if let t = bySec[tsSec[i]] { tally = t } else { tally = PairTally(); bySec[tsSec[i]] = tally }
            tally.add(ms: ms, ord: o)
        }
        var ppts: [Int] = []
        for (_, t) in bySec where t.qualifies {
            let lo = min(t.first, t.second), hi = max(t.first, t.second)
            guard lo > 0 else { continue }
            // Int64 so the multiply can't overflow on a corrupt row (Kotlin's Int is 32-bit and would wrap).
            ppts.append(Int((Int64(hi) * 1_000 + Int64(lo) / 2) / Int64(lo)))   // half-up, parts per thousand
        }
        guard !ppts.isEmpty else { return "rr dupPairs n=0" }
        ppts.sort()
        // Identical (both deliveries stored the same number), the 1024/1000 signature, or neither.
        let same = ppts.filter { $0 <= 1_005 }.count
        let tick = ppts.filter { $0 >= 1_019 && $0 <= 1_029 }.count
        let med = ppts.count % 2 == 1
            ? ppts[ppts.count / 2]
            : (ppts[ppts.count / 2 - 1] + ppts[ppts.count / 2]) / 2
        return "rr dupPairs n=\(ppts.count) same=\(same) tick=\(tick)"
            + " other=\(ppts.count - same - tick) medPPT=\(med) spread=\(ppts[0])-\(ppts[ppts.count - 1])"
    }

    static func msToInt(_ ms: Double) -> Int { ms > 0 ? Int(ms + 0.5) : 0 }

    /// Whole-percent, integer half-up; 0 when `total` is 0.
    ///
    /// Widened to `Int64` because `deliveryHistogram` passes beat-time in milliseconds summed over a
    /// night. The numerator `part * 200 + total` exceeds 32 bits from `total >= 10,683,999` ms (2.97 h)
    /// and a real over-count night carries 3-4x that. `Int` is 32-bit on `arm64_32` and StrandAnalytics
    /// builds for watchOS, so the width is stated. The 32-bit wrap didn't always go negative: a 100%
    /// 8 h night (`pct(28_800_000, 28_800_000)`) returned 25, plausible and wrong.
    static func pct(_ part: Int, _ total: Int) -> Int {
        total > 0 ? Int((Int64(part) * 200 + Int64(total)) / (Int64(total) * 2)) : 0
    }

    /// A compact, deterministic raw-row sample of the beats around the densest second, for the
    /// always-on `hrv diag` log on over-count nights, so the mechanism of a `coverage>1` verdict can be
    /// read off the log (#1008). Integer-only formatting; "" for < 2 beats.
    ///   - near-equal `rrMs` in a second (e.g. `[1200,1199]`): the same beat stored twice;
    ///   - a full interval beside a partial one (`[1200,600]`): two distinct interval trains;
    ///   - a `@N` suffix: a non-null `srcChannel`; `src=none` means untagged (#1071 Oura channel
    ///     machinery doesn't apply).
    /// Statistics-free on purpose: at second resolution a real beat and a duplicate look alike (#550).
    ///
    /// - Parameters:
    ///   - tsSec / rrMs: per-beat timestamps (unix seconds) and intervals (ms).
    ///   - srcCodes: per-beat `srcChannel` code or nil, index-aligned.
    ///   - halfWindowSec: context seconds either side of the densest second.
    ///   - maxRowsPerSecond: cap on beats listed per second (truncated with `+K`).
    public static func densestSecondWindowSample(
        tsSec: [Int],
        rrMs: [Double],
        srcCodes: [Int?],
        ords: [Int?] = [],
        halfWindowSec: Int = 3,
        maxRowsPerSecond: Int = 24
    ) -> String {
        let n = min(tsSec.count, rrMs.count)
        guard n >= 2 else { return "" }
        // Per-second beat counts; the densest second (ties to earliest) anchors the window.
        var perSec: [Int: Int] = [:]
        for i in 0..<n { perSec[tsSec[i], default: 0] += 1 }
        let occ = perSec.count
        var maxInSec = 0
        var t0 = tsSec[0]
        // Deterministic argmax: highest count, earliest ts on a tie.
        for t in perSec.keys.sorted() where perSec[t]! > maxInSec { maxInSec = perSec[t]!; t0 = t }
        let beatsPerSec = occ > 0 ? Double(n) / Double(occ) : 0
        // src=none unless any beat carries a channel code; list the distinct codes.
        var codes = Set<Int>()
        for i in 0..<n where i < srcCodes.count { if let c = srcCodes[i] { codes.insert(c) } }
        let srcField = codes.isEmpty ? "none" : codes.sorted().map { String($0) }.joined(separator: "/")

        var out = ""
        // Two-decimal beats/sec on integers (no locale).
        let bpsX100 = Int(beatsPerSec * 100.0 + 0.5)
        out += "beatsPerSec=\(bpsX100 / 100)."
        let frac = bpsX100 % 100
        if frac < 10 { out += "0" }
        out += "\(frac)"
        out += " maxInSec=\(maxInSec) occSec=\(occ) totBeats=\(n) src=\(srcField) | t0=\(t0)"
        for offset in -halfWindowSec...halfWindowSec {
            let t = t0 + offset
            // Beats in this second, sorted by rrMs then original index.
            let rows = (0..<n).filter { tsSec[$0] == t }
                .sorted { a, b in (rrMs[a], a) < (rrMs[b], b) }
            if rows.isEmpty { continue }
            out += " " + (offset > 0 ? "+" : "") + "\(offset)s["
            let shown = min(rows.count, maxRowsPerSecond)
            for k in 0..<shown {
                if k > 0 { out += "," }
                let idx = rows[k]
                out += "\(Int(rrMs[idx] + 0.5))"
                if idx < srcCodes.count, let c = srcCodes[idx] { out += "@\(c)" }
                // `ord` is the per-timestamp occurrence counter, restarting at 0 per delivery: once-delivered
                // reads 0,1,2; two offloads read 0,1,2,0,1. The only field that answers this for a strap
                // (`srcChannel` is always nil on a WHOOP row).
                if idx < ords.count, let o = ords[idx] { out += "#\(o)" }
            }
            if rows.count > shown { out += ",+\(rows.count - shown)" }
            out += "]"
        }
        return out
    }

    // MARK: - Helpers

    /// Median of a non-empty array (the caller guarantees non-empty).
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
