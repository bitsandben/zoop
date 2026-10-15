import Foundation
import WhoopProtocol

// SleepStager.swift — sleep/wake detection + APPROXIMATE 4-class staging (the V1 percentile-band stager).
//
// Stages are APPROXIMATIONS, not PSG-validated, not medical advice. The EEG-free 4-class ceiling is
// ~65–73% epoch agreement (Walch 2019); light/deep separation is the weakest link.
//
// Pipeline (30 s epochs):
//   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke (te Lindert 30 s) is a
//            citable cross-check; HR confirms runs.
//   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window (mean HR, DoG-HR
//            variability, RMSSD/SDNN from RR, resp rate + RRV).
//   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
//   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in the first third).
//
// On-device there is no neurokit2/scipy, so frequency-domain features (HF, LF/HF) are omitted and the
// parasympathetic-tone signal is RMSSD only. Respiration rate + RRV come from the raw 1 Hz resp channel
// with a simple peak detector.

// MARK: - Public output shapes

/// A contiguous sleep-stage segment. Times are wall-clock unix seconds.
public struct StageSegment: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var stage: String  // "wake" | "light" | "deep" | "rem"
    public init(start: Int, end: Int, stage: String) {
        self.start = start; self.end = end; self.stage = stage
    }
}

/// A detected sleep session (in-bed span) with APPROXIMATE staging.
public struct SleepSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake).
    public let efficiency: Double
    public let stages: [StageSegment]
    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    public let restingHR: Int?
    /// Mean RMSSD over 5-min windows across the session (ms), or nil.
    public let avgHRV: Double?
    /// Staged WITHOUT a motion spine, from heart rate alone. Weaker by construction (a quiet evening at rest
    /// can sit in the sleep band), so it may describe itself (duration, stages, Rest) but must not reach
    /// anything it cannot be unwound from; hence `restingHR` and `avgHRV` are left nil rather than filtered
    /// downstream.
    public let hrOnly: Bool

    public init(start: Int, end: Int, efficiency: Double, stages: [StageSegment],
                restingHR: Int?, avgHRV: Double?, hrOnly: Bool = false) {
        self.start = start; self.end = end; self.efficiency = efficiency
        self.stages = stages; self.restingHR = restingHR; self.avgHRV = avgHRV
        self.hrOnly = hrOnly
    }
}

public enum SleepStager {

    // MARK: - RHR bin-gate thresholds (shared by sessionRestingHR and rhrBinGateLogLine)
    // One constant per threshold, read by both the gate and its conformance check, so they cannot drift.

    /// Minimum samples in a 5-min bin to be a candidate for the night's resting HR (a one-sample bin at the
    /// edge of a wear gap cannot become the floor).
    public static let rhrMinBinSamples: Int = 5
    /// Minimum plausible mean HR (bpm) for a bin to qualify (a dropout dip cannot become the floor).
    public static let rhrMinPlausibleBpm: Double = 25

    // MARK: - Stage 0 constants

    /// Per-sample gravity change (g) at/below which a sample is "still".
    public static let gravityStillThresholdG: Double = 0.01
    /// Rolling stillness window (minutes).
    public static let stillWindowMin: Int = 15
    /// Fraction of still samples to call the window-center "sleep".
    public static let stillFraction: Double = 0.70
    /// Data gap (minutes) that always breaks a run.
    public static let maxGapMin: Int = 20
    /// Runs shorter than this (minutes) are absorbed into neighbours.
    public static let mergeMin: Int = 15
    /// A sleep run must exceed this (minutes) to count as a session.
    public static let minSleepMin: Int = 60
    /// Assumed sample interval (seconds) when not inferable.
    public static let defaultIntervalS: Double = 60.0

    // MARK: - Daytime false-sleep guard

    // A long, still, sedentary daytime stretch (reading, a desk, a sofa) is gravity-indistinguishable from a
    // nap. Real naps stay legitimate, so a window whose CENTER falls in the local daytime band is held to a
    // stricter bar: long enough to be a real nap AND a genuine cardiac dip. Overnight windows are unchanged.

    /// Local hour (inclusive) at which the stricter daytime bar begins.
    ///
    /// Zoop: 08:00 rather than 11:00, so a still morning block (coffee, a commute, centre 09:00) faces the
    /// daytime bar and the morning-stillness guard sees the post-wake window it was written for. Late
    /// sleepers stay covered by the night-tail continuation (`nightContinuationGapMin`).
    public static let daytimeBandStartHour: Int = 8
    /// Local hour (exclusive) at which the stricter daytime bar ends. A window whose center is in
    /// [start, end) local hours is "daytime".
    ///
    /// Zoop: 21:00 rather than 20:00, so an evening on the sofa (19:00-22:00) faces the daytime bar.
    public static let daytimeBandEndHour: Int = 21
    /// A still sleep run resuming within this gap of an overnight sleep chain is the night's TAIL (a late
    /// wake or a brief morning stir then back to sleep), not an isolated nap, so it skips the daytime guard.
    /// Without it a sleep running past the daytime-band start had its tail rejected and its wake time
    /// truncated (late sleepers / shift workers).
    public static let nightContinuationGapMin: Int = 90
    /// A daytime window must run at least this long (minutes); short still daytime stretches are the
    /// dominant false positive.
    public static let daytimeMinSleepMin: Int = 90
    /// A daytime window's resting HR (lowest 5-min rolling mean) must be at or below baseline × this. Stricter
    /// than the overnight 1.05: a true nap dips below the waking-day median, sedentary stillness does not.
    public static let daytimeRestingHRMult: Double = 0.95

    // MARK: - Physiological in-bed span cap

    /// Maximum plausible in-bed span (seconds) for a SINGLE assembled main-sleep run. A 12 h+ "sleep" is a
    /// bad-clock artefact (stale/duplicated timestamps, or one frozen still stretch under a wrong clock)
    /// that would poison Rest, the debt ledger and the headline. 16 h is above any genuine night yet below
    /// the artefact range. An over-long run is DROPPED, not truncated, since truncating would fabricate a
    /// wake time.
    public static let maxMainSleepSpanS: Int = 16 * 60 * 60

    // MARK: - Morning-stillness nap suppression

    // After a real overnight wake the wrist is often still (coffee, scrolling in bed, a sofa) for a stretch the
    // gravity spine reads as a fresh "nap" (a 9 am phantom nap right after the night ended). It is not a
    // night-tail continuation and can clear the ordinary daytime guard, so a daytime block that BEGINS within
    // `morningStillnessWindowMin` of the detected overnight wake is held to a stronger bar: a sustained
    // re-onset that dips clearly below the day median.

    /// A daytime block starting within this many minutes AFTER an overnight chain's wake is suspected morning
    /// residual stillness and held to the stronger re-onset bar. ~3 h covers that window; a genuine afternoon
    /// nap is past it.
    public static let morningStillnessWindowMin: Int = 180

    /// The stronger resting-HR bar (× day baseline) a suspected-morning-stillness block must clear. Stricter
    /// than `daytimeRestingHRMult` (0.95): residual waking stillness keeps a near-waking HR.
    public static let morningReonsetRestingHRMult: Double = 0.90

    /// The persisted v18 BAND sleep_state value meaning "asleep" (`(sb>>4)&3`: 0 wake / 1 still / 2 asleep /
    /// 3 up): the strap's own scored state, consumed to confirm a borderline morning re-onset.
    public static let bandStateAsleep: Int = 2

    /// Fraction of a suspected-morning-stillness block's epochs whose band sleep_state must read "asleep" for
    /// the strap's own signal to confirm a genuine re-onset and keep the block despite a borderline HR dip.
    public static let morningReonsetBandAsleepFrac: Double = 0.6
    /// Seconds in a calendar day (for local-hour-of-day arithmetic).
    static let secondsPerDay: Int = 86_400
    /// Floor on the rolling-window size in samples.
    public static let minWindowSamples: Int = 3
    /// A run is HR-confirmed only if mean HR ≤ baseline × this.
    public static let hrSleepBaselineMult: Double = 1.05
    /// Skip HR refinement (trust gravity) when fewer than this many HR samples.
    public static let hrRefineMinSamples: Int = 30
    /// Consecutive sleep epochs required to declare onset.
    public static let onsetPersistEpochs: Int = 3

    // MARK: - Off-wrist backstop

    // A wrist-OFF stretch reads as still gravity, so the spine classifies it as sleep, and its zero/missing HR
    // lets it past the daytime guard. The backstop measures OFF-WRIST COVERAGE: a worn strap emits ~1 Hz HR, so
    // a long CONTIGUOUS HR gap in a candidate run is a strong proxy even without WRIST_OFF events (which sharpen
    // it). A run is dropped only when coverage reaches maxOffWristSleepFraction, so a real night with a SHORT
    // off-wrist tail survives. Independent of the daytime band; a night-tail continuation does not exempt it.
    /// A contiguous HR-sample gap of at least this many minutes counts toward a run's off-wrist coverage. Sized
    /// at maxGapMin so a worn night contributes ~no gap but a wrist-off stretch contributes its whole span.
    public static let offWristHRGapMin: Int = 20

    /// FRACTIONAL off-wrist rejection: a candidate run is dropped ONLY when its off-wrist coverage (the UNION
    /// of long HR-gap spans and WRIST_OFF→WRIST_ON intervals) is at least this fraction of its duration. 0.5
    /// keeps a real night with a short off-wrist morning tail or a stray WRIST_OFF blip, while still dropping
    /// an all-day desk strap (≈100% gap).
    public static let maxOffWristSleepFraction: Double = 0.5

    /// Minimum average HR-stream density for the off-wrist HR-gap proxy to be trusted. A >`offWristHRGapMin`
    /// hole reads as "off the wrist" only when HR is otherwise dense; a WHOOP 4.0's SYNCED night is rebuilt
    /// mostly from MOTION with sparse derived HR, whose natural gaps would wrongly drop a real night. If HR
    /// averages fewer than one sample per this many seconds, off-wrist is not asserted from gaps (WRIST_OFF
    /// events still apply). Measured over the whole stream, so a hole in an otherwise dense worn day is caught.
    static let hrDenseSpacingS: Int = 600   // one HR sample per 10 minutes, averaged over the stream

    // MARK: - Sparse-gravity robustness

    // On an un-unlocked WHOOP 5.0 the strap backfills mostly v18/v26 records where gravity is sparse/clumped
    // (~25% coverage), so the gravity-only spine fragments the night at every >maxGapMin gap and drops every
    // <minSleepMin fragment (a ~6 h night collapses to ~1 h). The in-bed spine is derived from a sustained
    // low-HR stretch with gravity stillness only REFINING it, GATED ENTIRELY behind a "gravity is sparse"
    // condition so dense WHOOP-4.0 nights stay BYTE-IDENTICAL.

    /// Gravity is "sparse" when its timespan covers less than this fraction of the HR-sample timespan (a dense
    /// 4.0 night is ≈1.0; a 5.0 backfill clumps gravity into a fraction of the night).
    public static let sparseGravitySpanFrac: Double = 0.5
    /// When sparse, an HR sample is "sleep-band" when bpm ≤ baseline × this (the overnight HR-confirmation
    /// multiplier, so the band is the one detectSleep already trusts).
    public static let hrSleepBandMult: Double = hrSleepBaselineMult
    /// When sparse, two adjacent sleep runs separated ONLY by a gravity gap up to this many minutes merge if
    /// the intervening HR stays in the sleep band. Sized at the daytime-nap floor.
    public static let sparseBridgeGapMin: Int = 90

    /// A single intervening ACTIVE run up to this long may be absorbed when bridging two sleep runs.
    ///
    /// 30 is a judgement: `classifyStill` smears the still/moving boundary by about its rolling window, so a
    /// 15-minute interruption yields a ~21-minute active run. Well under `minSleepMin` (a longer interruption
    /// is a genuine awakening). The cheap half of the guard; the real one is the HR band across the span.
    public static let sparseBridgeActiveMaxMin: Int = 30

    /// The same bound when HR across the whole span stays in the sleep band.
    ///
    /// Where the "active" verdict comes from sparse MOTION, HR is the better witness, so it must be able to
    /// override the cheap minute bound. 60 is `minSleepMin`. Applied as a MAXIMUM against
    /// `sparseBridgeActiveMaxMin`, so the in-band path is only ever more permissive.
    public static let sparseBridgeActiveMaxInBandMin: Int = 60

    // MARK: - Stage 1–3 constants

    public static let epochS: Double = 30.0
    public static let featureWindowS: Double = 5 * 60.0
    public static let ckCountDivisor: Double = 100.0
    public static let ckCountClip: Double = 300.0
    public static let moveDeltaThresholdG: Double = 0.01
    public static let hrDogSigma1S: Double = 120.0
    public static let hrDogSigma2S: Double = 600.0

    public static let stageHRLowPct: Double = 25.0
    public static let stageHRHighPct: Double = 70.0
    public static let stageHRVHighPct: Double = 70.0
    public static let stageHRVarHighPct: Double = 65.0
    public static let stageRRVHighPct: Double = 65.0
    public static let stageRRVLowPct: Double = 50.0
    public static let stageWakeMoveFrac: Double = 0.15
    public static let stageStillMoveFrac: Double = 0.10

    /// Fraction of sleep-period epochs with a MISSING per-epoch RMSSD (sparse R-R) for the session's cardiac
    /// signal to count as PPG-DERIVED / sparse-cardiac. On a WHOOP 5/MG that noisier HR-variance inflated
    /// `hrVar` on still, low-HR epochs and tripped the Stage-2 WAKE rule (`hrvarHigh`), so a whole night
    /// over-reported WAKE. At this share the HR-variance half of the WAKE rule is down-weighted; ~50% keeps a
    /// real worn 4.0 night (dense R-R) on the strict path.
    public static let cardiacSparseEpochFrac: Double = 0.5

    public static let smoothEpochs: Int = 5
    public static let noREMAfterOnsetMin: Double = 15.0
    public static let deepFirstFraction: Double = 1.0 / 3.0

    /// Fragment-merge threshold. The WHOOP 5/MG banks sparse motion, so the stager emits many sub-minute stage
    /// flecks. `mergeFragments` (a display/scoring smoothing applied AFTER staging, never to detection)
    /// absorbs runs shorter than this into neighbours. 3 min clears the fleck noise yet leaves a genuine
    /// transition (a real deep or REM block runs many minutes) untouched.
    public static let fragmentMergeMin: Double = 3.0
    /// `fragmentMergeMin` in 30 s epochs (6); a run with fewer epochs merges.
    public static let fragmentMergeEpochs: Int = Int((fragmentMergeMin * 60.0 / epochS).rounded())

    /// te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1.
    public static let ckWeights: [Double] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0]
    public static let ckScale: Double = 0.001
    public static let ckBack: Int = 4
    public static let ckFwd: Int = 2

    // MARK: - Gravity deltas

    /// Per-record movement proxy = L2 magnitude of the gravity change vs the previous record (first record 0).
    static func gravityDeltas(_ grav: [GravitySample]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(grav.count)
        var prev: GravitySample? = nil
        for (i, r) in grav.enumerated() {
            if i == 0 {
                deltas.append(0.0)
            } else if let p = prev {
                let dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z
                deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
            } else {
                deltas.append(0.0)
            }
            prev = r
        }
        return deltas
    }

    /// Median spacing between consecutive timestamps, restricted to (0, 300 s).
    static func medianIntervalS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return defaultIntervalS }
        var gaps: [Double] = []
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return defaultIntervalS }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }

    static func windowSize(_ times: [Int]) -> Int {
        let interval = medianIntervalS(times)
        return max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
    }

    // MARK: - Sparse-gravity gate

    /// Largest spacing between consecutive timestamps (seconds), no upper cap; 0 for <2 samples. For clumped
    /// gravity a few long dropouts keep the MEDIAN gap small yet still break runs, so the largest gap is the
    /// right signal.
    static func largestGapS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return 0 }
        var mx = 0.0
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > mx { mx = g }
        }
        return mx
    }

    /// True when gravity is too sparse for the gravity-only spine to be trusted across gaps: its timespan
    /// covers < sparseGravitySpanFrac of the HR timespan, OR its LARGEST inter-sample gap exceeds maxGapMin
    /// (catching CLUMPED motion, the typical WHOOP 4.0 backfill). Needs a real HR span to compare against;
    /// with no/degenerate HR the dense path is kept (false).
    static func isGravitySparse(_ grav: [GravitySample], hr: [HRSample]) -> Bool {
        if grav.count < 2 || hr.count < 2 { return false }
        let hrSpan = Double(hr[hr.count - 1].ts - hr[0].ts)
        if hrSpan <= 0 { return false }
        let gravSpan = Double(grav[grav.count - 1].ts - grav[0].ts)
        if gravSpan < sparseGravitySpanFrac * hrSpan { return true }
        // Clumped 4.0 motion keeps a small median gap yet contains >maxGapMin dropouts. Flagging sparse only
        // ENABLES buildRuns' HR-vouched bridge; a real wake (HR above the sleep band) still breaks.
        return largestGapS(grav.map { $0.ts }) > Double(maxGapMin * 60)
    }

    /// True when HR stays in the sleep band (≤ baseline × hrSleepBandMult) across (a, b], deciding whether a
    /// pure gravity gap is a real wake or a dropout. With no baseline or no HR in the interval: false.
    static func hrSleepBandAcross(_ a: Int, _ b: Int, hr: [HRSample], baseline: Double?) -> Bool {
        guard let baseline = baseline else { return false }
        let seg = hr.filter { $0.ts > a && $0.ts <= b }
        if seg.isEmpty { return false }
        // MEDIAN, not mean: brief arousal / wake HR spikes (to ~190 bpm) drag the mean above the band, and over
        // this shorter window one spike dominates it even harder. The median still rejects a SUSTAINED elevation.
        let medianHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        return medianHR <= baseline * hrSleepBandMult
    }

    /// Per-record sleep flags from a rolling fraction of "still" samples.
    static func classifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        if n < 2 { return [Bool](repeating: false, count: n) }
        let half = windowSize(grav.map { $0.ts }) / 2
        // stillPrefix[i] = # still samples among deltas[0..<i]: O(1) window counts, an O(n) scan instead of
        // O(n×window) (the nested loop froze Android's main thread after a few nights of 1 Hz history).
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            stillPrefix[i + 1] = stillPrefix[i] + (deltas[i] < gravityStillThresholdG ? 1 : 0)
        }
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let stillCount = stillPrefix[hi] - stillPrefix[lo]
            flags.append(Double(stillCount) / Double(hi - lo) >= stillFraction)
        }
        return flags
    }

    struct Period { var stage: String; var start: Int; var end: Int }

    /// Collapse per-record flags into contiguous runs, breaking on class change or a gap > maxGapMin minutes.
    ///
    /// When `sparse`, a PURE gravity data-gap (no contrary motion) does NOT close a SLEEP run while HR stays in
    /// the sleep band across it: the strap banked no motion there, which is not a wake. A class change always
    /// closes the run; the dense path is unchanged.
    static func buildRuns(_ grav: [GravitySample], _ flags: [Bool],
                          sparse: Bool = false, hr: [HRSample] = [], baseline: Double? = nil) -> [Period] {
        let n = grav.count
        if n == 0 { return [] }
        let times = grav.map { $0.ts }
        let maxGapS = maxGapMin * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...n {
            let atEnd = (i == n)
            let close: Bool
            if atEnd {
                close = true
            } else {
                let classChanged = flags[i] != flags[runStart]
                var gapExceeded = (times[i] - times[i - 1]) > maxGapS
                // Sparse override: a pure gravity gap does not break a sleep run when HR stays in band across it.
                if sparse && gapExceeded && !classChanged && flags[runStart]
                    && hrSleepBandAcross(times[i - 1], times[i], hr: hr, baseline: baseline) {
                    gapExceeded = false
                }
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Percentile of the window's bpm that anchors the HR-only sleep band.
    ///
    /// Not `hrBaseline`, the window MEDIAN: fine as a CONFIRMATION gate, but as a PRIMARY threshold a median
    /// splits the samples in half by definition, so `median * 1.05` admits over half of any window (14.4 h of
    /// sleep against a truth of 8 on a realistic 24 h). The 10th percentile sits in the night's trough.
    public static let hrOnlyAnchorPercentile: Double = 0.10

    /// Multiplier above `hrOnlyAnchorPercentile` that still counts as asleep.
    ///
    /// Equals `hrSleepBandMult` today but is a SEPARATE constant (a detector's tolerance, not a confirmation
    /// gate's). Chosen conservatively from an anchor x multiplier sweep against windows with known truth:
    /// over-detection shows a wrong Rest number while under-detection leaves "No data", the safe failure. p10 x
    /// 1.05 measured 8.1 h against a truth of 8 (pinned in `SleepStagerHrOnlyAnchorTests`).
    public static let hrOnlyBandMult: Double = 1.05

    /// The `hrOnlyAnchorPercentile` of `hr` by bpm, or nil when empty. Nearest-rank (no interpolation), so the
    /// value is one the wearer recorded and the platforms cannot disagree on rounding.
    static func hrOnlyBaseline(_ hr: [HRSample]) -> Double? {
        hrPercentile(hr, hrOnlyAnchorPercentile)
    }

    /// The `p` percentile of `hr` by bpm, nearest-rank; shared with `hrOnlyBaseline` so the trace's spread is
    /// measured by the same rule as the anchor.
    static func hrPercentile(_ hr: [HRSample], _ p: Double) -> Double? {
        percentileOfSorted(hr.map { Double($0.bpm) }.sorted(), p)
    }

    /// The `p` percentile of an ALREADY-SORTED bpm list, nearest-rank. Split out so the caller sorts once for
    /// three percentiles (~160k samples per scored day across a 21-day rescore).
    static func percentileOfSorted(_ sorted: [Double], _ p: Double) -> Double? {
        if sorted.isEmpty { return nil }
        let idx = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[idx]
    }

    /// How many distinct `hrOnlyEpochS` buckets `sortedByTs` spans. A single pass over the sorted input rather
    /// than a Set, which would build a full intermediate array and set per scored day; a diagnostic must not
    /// cost what it measures.
    static func distinctEpochs(_ sortedByTs: [HRSample]) -> Int {
        var count = 0
        var last = Int.min
        for s in sortedByTs {
            let key = s.ts / hrOnlyEpochS
            if key != last { count += 1; last = key }
        }
        return count
    }

    /// Epoch for the HR-only spine, in seconds.
    public static let hrOnlyEpochS: Int = 60

    /// Sleep/active runs built from HEART RATE ALONE, for a strap that streams HR but banks no motion.
    ///
    /// A WHOOP 5/MG that cannot bond never banks motion (`SET_CLOCK` rides a handshake it never completes), so
    /// `grav` is empty and there is no spine to confirm. This builds one from HR: per-epoch MEDIAN bpm against
    /// `baseline * hrSleepBandMult`, with run construction as in `buildRuns`. One branch is deliberately absent:
    /// `buildRuns` forgives a gap when HR vouches across it, but here the gap IS in the HR, so a long HR dropout
    /// breaks a run and the caller's minimum-duration gate drops a night fragmented that way.
    ///
    /// WEAKER THAN THE MOTION SPINE by construction: callers must treat these runs as lower-confidence and keep
    /// them out of any baseline they cannot be unwound from.
    static func hrOnlySleepRuns(_ hr: [HRSample], baseline: Double?,
                                epochS: Int = hrOnlyEpochS,
                                maxGapMinutes: Int = maxGapMin) -> [Period] {
        guard let baseline = baseline, baseline > 0 else { return [] }
        if hr.isEmpty || epochS <= 0 { return [] }
        var byEpoch: [Int: [Double]] = [:]
        var lastTs: [Int: Int] = [:]
        for s in hr {
            let k = s.ts / epochS
            byEpoch[k, default: []].append(Double(s.bpm))
            lastTs[k] = max(lastTs[k] ?? Int.min, s.ts)
        }
        let keys = byEpoch.keys.sorted()
        // Two axes, deliberately: a gap and a run's START use the epoch's own start, but a run's END is the last
        // SAMPLE observed in its final epoch (what `buildRuns` means by `end`); using the epoch start there would
        // understate every run by an epoch against the minimum-duration gate.
        let times = keys.map { $0 * epochS }
        let ends = keys.map { lastTs[$0]! }
        let flags = keys.map { HRVAnalyzer.median(byEpoch[$0]!) <= baseline * hrOnlyBandMult }
        let maxGapS = maxGapMinutes * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...keys.count {
            let atEnd = (i == keys.count)
            let close: Bool
            if atEnd {
                close = true
            } else {
                close = flags[i] != flags[runStart] || (times[i] - times[i - 1]) > maxGapS
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: ends[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Whole sleep SESSIONS from heart rate alone, for a strap that banks no motion.
    ///
    /// `hrOnlySleepRuns` supplies the spine; `SleepStagerV2` stages each surviving run from HR and R-R with an
    /// EMPTY gravity array (only its motion-quiescence terms go quiet). A night that fails to stage is omitted.
    /// The anchor is `hrOnlyBaseline`, NOT the `hrBaseline` median (see `hrOnlyAnchorPercentile`).
    ///
    /// `restingHR` and `avgHRV` are MEASURED and reported: only the session BOUNDS are inferred from HR (what
    /// `hrOnly` marks), each RMSSD is computed over its own 5-minute window, and withholding them left Charge
    /// with no input at all. The flag lets a consumer still weigh an HR-only night down.
    ///
    /// `public` because `Strand/Data/IntelligenceEngine.swift` calls it from outside this package.
    public static func hrOnlySessions(day: String, hr: [HRSample], rr: [RRInterval], resp: [RespSample],
                                      minMinutes: Int = minSleepMin,
                                      traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        let hrS = hr.sorted { $0.ts < $1.ts }
        // ONE sort of the bpm axis, reused for the anchor and the spread the trace reports.
        let sortedBpm = hrS.map { Double($0.bpm) }.sorted()
        guard let baseline = percentileOfSorted(sortedBpm, hrOnlyAnchorPercentile) else {
            traceSink?(GateTrace.hrOnlyLine(day: day, anchorBpm: nil, bandBpm: nil, hrP50: nil, hrP90: nil,
                                            epochs: 0, runs: 0,
                                            mergedRuns: 0, sleepRuns: 0, longestSleepMin: 0,
                                            staged: 0, kept: 0, minSleepMin: minMinutes))
            return []
        }
        let rrS = rr.sorted { $0.ts < $1.ts }
        var out: [SleepSession] = []
        // mergePeriods, as the motion path does: a sleeping heart rate oscillates across the band all night, so
        // without it the spine returns the night's minutes shredded into sub-mergeMin fragments that each fail
        // the minimum-duration gate below (8 h of detected sleep yielding zero sessions).
        let rawRuns = hrOnlySleepRuns(hrS, baseline: baseline)
        let merged = mergePeriods(rawRuns)
        var staged = 0
        var longestSleepS = 0
        for p in merged {
            if p.stage != "sleep" { continue }
            longestSleepS = max(longestSleepS, p.end - p.start)
            if (p.end - p.start) < minMinutes * 60 { continue }
            let stages = SleepStagerV2.stageSession(start: p.start, end: p.end, grav: [],
                                                    hr: hrS, rr: rrS, resp: resp)
            staged += 1
            if stages.isEmpty { continue }
            // MEASURED, not nilled: bounds are inferred from HR (hence `hrOnly`), but each RMSSD is computed over its
            // own 5-minute window tagged by the stage at its centre. `hrOnly` is a quality marker, not a delete.
            out.append(SleepSession(start: p.start, end: p.end,
                                    efficiency: efficiency(start: p.start, end: p.end, stages: stages),
                                    stages: stages,
                                    restingHR: sessionRestingHR(start: p.start, end: p.end, hr: hrS),
                                    avgHRV: sessionAvgHRV(start: p.start, end: p.end, rr: rrS, stages: stages),
                                    hrOnly: true))
        }
        traceSink?(GateTrace.hrOnlyLine(
            day: day,
            anchorBpm: baseline,
            bandBpm: baseline * hrOnlyBandMult,
            // The wearer's own spread: p10 of 60 means one thing when the median is 63 and another at 74.
            hrP50: percentileOfSorted(sortedBpm, 0.50),
            hrP90: percentileOfSorted(sortedBpm, 0.90),
            // The real epoch count (the spine buckets by `hrOnlyEpochS` first), the axis every other number uses.
            epochs: distinctEpochs(hrS),
            runs: rawRuns.count,
            mergedRuns: merged.count,
            sleepRuns: merged.filter { $0.stage == "sleep" }.count,
            longestSleepMin: longestSleepS / 60,
            staged: staged,
            kept: out.count,
            minSleepMin: minMinutes))
        return out
    }

    /// Absorb runs shorter than mergeMin minutes into their neighbours.
    static func mergePeriods(_ periods: [Period], mergeMinutes: Int = mergeMin) -> [Period] {
        if periods.isEmpty { return [] }
        var pending = periods
        let thresholdS = mergeMinutes * 60
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            let tooShort = (current.end - current.start) < thresholdS
            if !tooShort { merged.append(current); i += 1; continue }

            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            let bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if bridgesSame {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1] = Period(stage: pending[i + 1].stage,
                                        start: current.start, end: pending[i + 1].end)
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    /// Why `bridgeSparseSleep` did or did not merge one adjacent pair of runs. `runsBefore`/`runsAfter` alone
    /// cannot say why a bridge changed NOTHING (gap over tolerance, HR outside the sleep band, or not two
    /// adjacent sleep runs); this names it per pair.
    struct SparseBridgeAttempt: Equatable, Sendable {
        /// Gap between the two runs, in whole minutes (negative when they overlap).
        let gapMin: Int
        /// Minutes of intervening ACTIVE run, or 0 when the pair was only separated by a gap.
        let activeMin: Int
        /// The bound this pair was judged against: 30, or 60 when HR stayed in the sleep band.
        let activeCapMin: Int
        /// Whether the intervening HR stayed in the sleep band.
        let hrInSleepBand: Bool
        /// Whether this pair was merged.
        let bridged: Bool
        /// Stable token for the log: bridged / gapTooLong / hrOutOfBand / overlap / activeTooLong.
        let reason: String
    }

    /// True when this night's sleep runs will ALL be dropped by `minSleepMin` yet add up to a plausible night.
    /// "Today's answer is zero": if any single run clears the floor this is false, so a night that currently
    /// scores cannot change. Two runs minimum, and the SUM must clear the floor so brief stirs don't become a night.
    static func isFragmentedToNothing(_ sleepRunSpansS: [Int], minSleepS: Int) -> Bool {
        sleepRunSpansS.count >= 2
            && !sleepRunSpansS.contains { $0 >= minSleepS }
            && sleepRunSpansS.reduce(0, +) >= minSleepS
    }

    /// The sparse-gravity bridge plus what it considered, one attempt per adjacent pair of sleep runs. See
    /// `bridgeSparseSleep` for the merge rule. Merge and trace are a single pass so the trace cannot disagree
    /// with the behaviour. A pair separated by an active run is considered only via the single-active-run
    /// case below; no attempts reported means no pair was eligible.
    static func bridgeSparseSleepTraced(_ periods: [Period], sparse: Bool, hr: [HRSample],
                                        baseline: Double?) -> ([Period], [SparseBridgeAttempt]) {
        if !sparse || periods.isEmpty { return (periods, []) }
        let bridgeGapS = sparseBridgeGapMin * 60
        let activeMaxS = sparseBridgeActiveMaxMin * 60
        let activeMaxInBandS = sparseBridgeActiveMaxInBandMin * 60
        var out: [Period] = []
        var attempts: [SparseBridgeAttempt] = []

        /// Judge one candidate pair, record it, and merge when it passes. Check order fixes the reported reason:
        /// overlap and gap (properties of the pair), activeTooLong (what sits between), hrOutOfBand last (the only
        /// check needing HR). `activeMaxInBandS` is a PARAMETER so case 1 reports the same activeCapMin on both
        /// platforms.
        func consider(_ left: Period, _ right: Period, activeS: Int,
                      dropTrailing: Bool, activeMaxS: Int, activeMaxInBandS: Int = 0) -> Bool {
            let gap = right.start - left.end
            let inBand = hrSleepBandAcross(left.end, right.start, hr: hr, baseline: baseline)
            // The HR band is the real guard, so let it widen the minute bound rather than be vetoed by it. max, not a
            // swap: in-band is only ever MORE permissive, and case 1 (activeS = 0) is untouched.
            let activeCapS = inBand ? max(activeMaxS, activeMaxInBandS) : activeMaxS
            let reason: String
            if gap < 0 { reason = "overlap" }
            else if gap > bridgeGapS { reason = "gapTooLong" }
            else if activeS > activeCapS { reason = "activeTooLong" }
            else if !inBand { reason = "hrOutOfBand" }
            else { reason = "bridged" }
            let bridged = reason == "bridged"
            attempts.append(SparseBridgeAttempt(gapMin: gap / 60, activeMin: activeS / 60,
                                                activeCapMin: activeCapS / 60,
                                                hrInSleepBand: inBand, bridged: bridged, reason: reason))
            guard bridged else { return false }
            if dropTrailing { out.removeLast() }
            out[out.count - 1] = Period(stage: "sleep", start: left.start, end: right.end)
            return true
        }

        for p in periods {
            if p.stage == "sleep" {
                // Case 1: the previous run is sleep (adjacent-pair merge).
                if let last = out.last, last.stage == "sleep" {
                    if consider(last, p, activeS: 0, dropTrailing: false, activeMaxS: 0) { continue }
                }
                // Case 2: exactly one active run sits between two sleep runs; absorbed when short enough.
                if out.count >= 2, let last = out.last, last.stage == "active",
                   out[out.count - 2].stage == "sleep" {
                    let prev = out[out.count - 2]
                    if consider(prev, p, activeS: last.end - last.start,
                                dropTrailing: true, activeMaxS: activeMaxS,
                                activeMaxInBandS: activeMaxInBandS) { continue }
                }
            }
            out.append(p)
        }
        return (out, attempts)
    }

    /// Sparse-gravity bridge: merge two SLEEP runs when the intervening HR stays in the sleep band, re-stitching
    /// a night fragmented by gravity dropouts BEFORE the minSleepMin gate drops the pieces. A no-op when
    /// `sparse == false`. Between the runs may be a bare gap (up to `sparseBridgeGapMin`) or ONE active run
    /// (up to `sparseBridgeActiveMaxMin`); longer gaps, longer active runs and two consecutive active runs are
    /// left untouched.
    static func bridgeSparseSleep(_ periods: [Period], sparse: Bool,
                                  hr: [HRSample], baseline: Double?) -> [Period] {
        bridgeSparseSleepTraced(periods, sparse: sparse, hr: hr, baseline: baseline).0
    }

    // MARK: - HR refinement

    static func rowsBetween<T>(_ rows: [T], start: Int, end: Int, ts: (T) -> Int) -> [T] {
        rows.filter { ts($0) >= start && ts($0) <= end }
    }

    /// Day HR baseline = median bpm over all HR samples; nil if none.
    static func hrBaseline(_ hr: [HRSample]) -> Double? {
        let vals = hr.map { Double($0.bpm) }
        guard !vals.isEmpty else { return nil }
        return HRVAnalyzer.median(vals)
    }

    /// HR-confirmation with MOTION CORROBORATION. A run is sleep when its MEDIAN HR sits within the band
    /// relative to `baseline`: `hrSleepBaselineMult` (×1.05), widened to `quiescentHRSleepMult` on a DEEPLY
    /// MOTION-QUIESCENT run (`runIsDeeplyQuiescent`), since a raised but flat HR with a motionless wrist is a
    /// supplement / fever / hot-room / alcohol artefact, not wakefulness. The wider band keeps a floor: a
    /// genuinely awake high-HR run is rejected even when still. `sleepHRBaseline` overrides `baseline` with the
    /// wearer's personalised overnight band; empty `grav` means motion unprovable → strict band.
    static func confirmSleepWithHR(_ p: Period, hr: [HRSample], baseline: Double?,
                                   grav: [GravitySample] = [], sleepHRBaseline: Double? = nil) -> Bool {
        let effBaseline = sleepHRBaseline ?? baseline
        guard let effBaseline = effBaseline else { return true }
        let seg = rowsBetween(hr, start: p.start, end: p.end) { $0.ts }
        if seg.count < hrRefineMinSamples { return true }
        // Confirm on the run's MEDIAN, not its mean: brief arousal / wake HR spikes (to ~190 bpm) pull the mean
        // above baseline × mult and reject a real night ("no sleep recorded") while the median stays at the sleep
        // level. Baseline is a median too. Median ≤ mean for a real night's skewed HR, so this only RELAXES the
        // gate: every run the mean accepted still passes.
        let medHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        let mult = runIsDeeplyQuiescent(p, grav: grav) ? quiescentHRSleepMult : hrSleepBaselineMult
        return medHR <= effBaseline * mult
    }

    // MARK: - HR-confirmed sleep onset

    // A gravity-still run begins the moment the wrist goes quiet, which is also when someone sits down to read
    // or watch TV. The 15-minute / 70%-still window absorbs page turns, so a quiet evening became the start of
    // the night (shown as bedtime, fed into Rest). `confirmSleepWithHR` can't catch it: it judges the run's
    // MEDIAN HR and an hour of sofa time is a minority of an eight-hour run.
    //
    // The night starts at the first SUSTAINED stretch that is both still and at the SLEEPING heart rate; a
    // leading stretch at a clearly waking HR is cut. Conservative: only when the lead is long
    // (≥ `onsetTrimMinLeadMin`), clearly above the sleeping level (×`onsetTrimAwakeMult` and
    // +`onsetTrimAwakeMinDeltaBpm`) and HR coverage is dense. Approximate: not validated against PSG.

    /// Length (minutes) of the still, sleeping-HR stretch that marks sleep onset.
    public static let onsetTrimWindowMin: Int = 20
    /// Percentile (0–1) of the run's per-minute HR that defines its SLEEPING level.
    public static let onsetTrimSleepLevelPct: Double = 0.20
    /// The onset stretch's median HR must sit at/below `level × this` (or `level + onsetTrimSleepBandMinBpm`,
    /// whichever is higher): back at the sleeping level, not merely lower than the evening.
    public static let onsetTrimSleepBandMult: Double = 1.12
    /// Absolute floor (bpm) for the sleeping band above the level, so a very low sleeper's band isn't narrower
    /// than minute-to-minute HR noise.
    public static let onsetTrimSleepBandMinBpm: Double = 5
    /// The trimmed lead's median HR must be at/above `level × this` — clearly a waking HR.
    public static let onsetTrimAwakeMult: Double = 1.20
    /// ... and at least this many bpm above the sleeping level.
    public static let onsetTrimAwakeMinDeltaBpm: Double = 8
    /// The shortest lead (minutes) worth trimming; anything shorter is ordinary sleep latency.
    public static let onsetTrimMinLeadMin: Int = 10
    /// Fraction of the onset stretch's minutes that must be still (minutes without gravity count as still:
    /// the run was already built from still gravity).
    public static let onsetTrimStillFrac: Double = 0.80
    /// Minimum HR-covered minutes in the run before the rule judges anything.
    public static let onsetTrimMinHRMinutes: Int = 60

    /// The run's start moved forward to HR-confirmed sleep onset, or `p.start` unchanged when the evidence for
    /// a waking lead is not clear. Never leaves the run at/below `minSleepMin`.
    static func hrConfirmedOnset(_ p: Period, hr: [HRSample], grav: [GravitySample],
                                 thresholds: OnsetTrimThresholds = .standard) -> Int {
        onsetDecision(p, hr: hr, grav: grav, thresholds: thresholds).onsetTs
    }

    /// Per-minute HR medians across `[start, end]` (nil where a minute has no sample).
    static func minuteHRMedians(start: Int, end: Int, hr: [HRSample]) -> [Double?] {
        guard end > start else { return [] }
        let minutes = (end - start) / 60 + 1
        var buckets = [[Double]](repeating: [], count: minutes)
        for s in hr where s.ts >= start && s.ts <= end && s.bpm > 0 {
            buckets[(s.ts - start) / 60].append(Double(s.bpm))
        }
        return buckets.map { $0.isEmpty ? nil : HRVAnalyzer.median($0) }
    }

    /// Per-minute share of gravity deltas at/above the still threshold across `[start, end]`, or nil for
    /// a minute without gravity. `grav` must be sorted by ts.
    static func minuteMovingFraction(start: Int, end: Int, grav: [GravitySample]) -> [Double?] {
        guard end > start else { return [] }
        let minutes = (end - start) / 60 + 1
        var moveCount = [Int](repeating: 0, count: minutes)
        var gravCount = [Int](repeating: 0, count: minutes)
        var prev: GravitySample? = nil
        for g in grav {
            defer { prev = g }
            guard g.ts >= start && g.ts <= end, let q = prev else { continue }
            let dx = q.x - g.x, dy = q.y - g.y, dz = q.z - g.z
            let m = (g.ts - start) / 60
            gravCount[m] += 1
            if (dx * dx + dy * dy + dz * dz).squareRoot() >= gravityStillThresholdG { moveCount[m] += 1 }
        }
        return (0..<minutes).map { m in
            gravCount[m] == 0 ? nil : Double(moveCount[m]) / Double(gravCount[m])
        }
    }

    /// The whole onset rule, returning what it decided and the numbers behind it. `hrConfirmedOnset` reads
    /// `.onsetTs`; the "Why this sleep?" sheet reads the rest via `explainOnset`, so the explanation cannot
    /// drift from the rule.
    static func onsetDecision(_ p: Period, hr: [HRSample], grav: [GravitySample],
                              thresholds t: OnsetTrimThresholds) -> OnsetDecision {
        var out = OnsetDecision(onsetTs: p.start, outcome: .sparseHR)
        guard p.end - p.start > 0 else { return out }
        let minuteHR = minuteHRMedians(start: p.start, end: p.end, hr: hr)
        let minutes = minuteHR.count
        let covered = minuteHR.compactMap { $0 }
        guard covered.count >= t.minHRMinutes else { return out }
        guard let level = percentile(covered, t.sleepLevelPct * 100), level > 0 else { return out }
        let sleepBand = max(level * t.sleepBandMult, level + t.sleepBandMinBpm)
        let awakeBar = max(level * t.awakeMult, level + t.awakeMinDeltaBpm)
        out.sleepLevelBpm = level
        out.sleepBandBpm = sleepBand
        out.awakeBarBpm = awakeBar

        // A minute is MOVING when more than (1 − stillFraction) of its gravity deltas reach the still threshold.
        // No gravity → still (the run was built from still gravity; silence is a sparse stream, not movement).
        let moving = minuteMovingFraction(start: p.start, end: p.end, grav: grav)
        let still: [Bool] = moving.map { f in f.map { $0 <= (1.0 - stillFraction) } ?? true }

        let w = t.windowMin
        let lastStart = minutes - w
        out.outcome = .settledPromptly
        guard lastStart > t.minLeadMin else { return out }
        var onsetMin: Int? = nil
        for m in 0...lastStart {
            let winHR = minuteHR[m..<(m + w)].compactMap { $0 }
            guard winHR.count * 2 >= w else { continue }
            let stillFrac = Double(still[m..<(m + w)].filter { $0 }.count) / Double(w)
            guard stillFrac >= t.stillFrac, HRVAnalyzer.median(winHR) <= sleepBand else { continue }
            // The window's median is at the sleeping level; onset is its first minute that is itself in the band.
            onsetMin = (m..<(m + w)).first { minuteHR[$0].map { $0 <= sleepBand } ?? false } ?? m
            break
        }
        guard let onset = onsetMin else { out.outcome = .neverSettled; return out }
        out.settledTs = p.start + onset * 60
        guard onset >= t.minLeadMin else { return out }
        // The lead must look AWAKE: dense enough HR and a median clearly above the sleeping level.
        let leadHR = minuteHR[0..<onset].compactMap { $0 }
        if !leadHR.isEmpty { out.leadMedianBpm = HRVAnalyzer.median(leadHR) }
        guard leadHR.count * 2 >= onset, HRVAnalyzer.median(leadHR) >= awakeBar else {
            out.outcome = .leadAtSleepingLevel
            return out
        }
        let newStart = p.start + onset * 60
        guard p.end - newStart > minSleepMin * 60 else { out.outcome = .tooShortToTrim; return out }
        out.onsetTs = newStart
        out.outcome = .trimmed
        return out
    }

    /// What `onsetDecision` concluded, with the numbers behind it (bpm values nil when not reached).
    struct OnsetDecision: Equatable {
        var onsetTs: Int
        var outcome: SleepOnsetEvidence.Outcome
        var sleepLevelBpm: Double? = nil
        var sleepBandBpm: Double? = nil
        var awakeBarBpm: Double? = nil
        var leadMedianBpm: Double? = nil
        /// First minute that sat in the sleeping band inside a still, sleeping-HR window (nil if none).
        var settledTs: Int? = nil
    }

    /// The learned personal offset applied to a run's HR-confirmed onset: moved by `offsetMin`, never before
    /// the moment the wrist went still (`runStart`), never leaving the run at/below `minSleepMin`. Zero
    /// offset returns `onsetTs` unchanged.
    public static func applyingOnsetOffset(onsetTs: Int, runStart: Int, runEnd: Int, offsetMin: Int) -> Int {
        guard offsetMin != 0 else { return onsetTs }
        let latest = runEnd - minSleepMin * 60 - 60
        guard latest >= onsetTs else { return max(runStart, min(onsetTs, onsetTs + offsetMin * 60)) }
        return min(max(onsetTs + offsetMin * 60, runStart), latest)
    }

    // MARK: - Motion-corroborated wake (elevated-but-flat-HR nights)

    // Both stagers call "wake" mainly off HR / HR-variability, and `confirmSleepWithHR` rejects a still run
    // whose median HR is above the band. With elevated resting HR but no getting up (supplement, fever, hot
    // room, alcohol) that misreads motionless sleep as wake. Rule: elevated HR ALONE is insufficient; a
    // run/epoch at the night's quiescent MOTION floor with UNCHANGED posture can't be called wake on cardiac
    // evidence. The per-epoch half is `SleepStagerV2.motionQuiescent`; this is the session half.

    /// The relaxed sleep-band multiplier for `confirmSleepWithHR` on a DEEPLY motion-quiescent run. Wider than
    /// `hrSleepBaselineMult` (1.05) but bounded, so a genuinely awake still run above it is still dropped.
    public static let quiescentHRSleepMult: Double = 1.30

    /// Per-minute gravity posture variance (g²) at/below which a minute counts as posture-STABLE. A minute with
    /// too few gravity samples to compute a variance is NOT counted as stable (silence is not stillness).
    public static let quiescentPostureVarG2: Double = 0.05

    /// Fraction of a run's minutes that must be posture-STABLE to be DEEPLY motion-quiescent. Set well above
    /// `stillFraction` (0.70) so only a genuinely motionless run earns the widened HR band; real turn-overs
    /// across >10% of minutes fall back to the strict band.
    public static let quiescentStableFrac: Double = 0.90

    /// Minimum posture-stable minutes with COMPUTABLE variance before the deeply-quiescent verdict is trusted;
    /// a run with almost no dense-gravity minutes can't prove stillness and defers to the strict band.
    public static let quiescentMinStableMinutes: Int = 20

    /// True when `[p.start, p.end)` is DEEPLY motion-quiescent: at least `quiescentStableFrac` of the minutes
    /// with enough gravity to judge are posture-stable (variance < `quiescentPostureVarG2`), over at least
    /// `quiescentMinStableMinutes` such minutes. Empty/sparse gravity → false.
    static func runIsDeeplyQuiescent(_ p: Period, grav: [GravitySample]) -> Bool {
        if grav.isEmpty || p.end <= p.start { return false }
        var byMinute: [Int: [GravitySample]] = [:]
        for g in grav where g.ts >= p.start && g.ts < p.end { byMinute[g.ts / 60, default: []].append(g) }
        var judged = 0, stable = 0
        for (_, samples) in byMinute {
            guard let v = posturVarianceG2(samples) else { continue }   // too few samples this minute
            judged += 1
            if v < quiescentPostureVarG2 { stable += 1 }
        }
        guard judged >= quiescentMinStableMinutes else { return false }
        return Double(stable) / Double(judged) >= quiescentStableFrac
    }

    /// Trace of the covariance of a minute's gravity vectors (Σ over x/y/z of the mean squared deviation from the
    /// minute's mean vector): ~0 when orientation is fixed, spiking on a turn-over. nil below 2 samples (one
    /// sample has zero variance by construction and would read as a false "stable").
    static func posturVarianceG2(_ samples: [GravitySample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let n = Double(samples.count)
        var sx = 0.0, sy = 0.0, sz = 0.0
        for s in samples { sx += s.x; sy += s.y; sz += s.z }
        let mx = sx / n, my = sy / n, mz = sz / n
        var sumSq = 0.0
        for s in samples {
            let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        return sumSq / n
    }

    /// Floor (bpm) for the personalised overnight HR baseline (`adaptiveOvernightHRBaseline`, the median of
    /// recent nights' overnight median HRs, so the sleep band tracks the wearer's current era). The floor
    /// keeps the band from collapsing so a genuinely wakeful era isn't scored asleep.
    public static let adaptiveBaselineFloor: Double = 40.0
    public static func adaptiveOvernightHRBaseline(recentOvernightMedians: [Double]) -> Double? {
        let vals = recentOvernightMedians.filter { $0.isFinite && $0 > 0 }
        guard !vals.isEmpty else { return nil }
        return max(adaptiveBaselineFloor, HRVAnalyzer.median(vals))
    }

    /// True when the run's CENTER, shifted to LOCAL time by tzOffsetSeconds, lands in the daytime band
    /// [daytimeBandStartHour, daytimeBandEndHour). The center is used so a window straddling a band edge is
    /// classified once, by where it mostly is. The floored modulo keeps negative local times in range.
    static func isDaytimeCenter(_ p: Period, tzOffsetSeconds: Int) -> Bool {
        // Overflow-safe midpoint.
        let center = p.start + (p.end - p.start) / 2
        let local = center + tzOffsetSeconds
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return hour >= daytimeBandStartHour && hour < daytimeBandEndHour
    }

    /// True when a run's ONSET, in LOCAL time, falls OUTSIDE the daytime band. Anchors a continuous-sleep
    /// chain: only a chain that began overnight may carry its tail past the daytime-band start.
    static func isOvernightOnset(_ start: Int, tzOffsetSeconds: Int) -> Bool {
        let local = start + tzOffsetSeconds
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return !(hour >= daytimeBandStartHour && hour < daytimeBandEndHour)
    }

    /// Stricter bar for a daytime-centered window (true = keep). A real nap clears it; a long sedentary still
    /// stretch does not (too short, or no cardiac dip below the day median). `restingHR` is the window's lowest
    /// 5-min rolling-mean HR; `baseline` the day's median. With no usable HR evidence (nil either) the stretch
    /// is rejected: sedentary stillness is far likelier than an unmonitored nap.
    static func passesDaytimeGuard(_ p: Period, restingHR: Int?, baseline: Double?) -> Bool {
        let daytimeMinSleepS = daytimeMinSleepMin * 60
        if (p.end - p.start) < daytimeMinSleepS { return false }
        guard let baseline = baseline, let resting = restingHR else { return false }
        return Double(resting) <= baseline * daytimeRestingHRMult
    }

    /// Morning-stillness nap suppression: true = KEEP, for a daytime block `p` beginning shortly after a real
    /// overnight wake. `morningWakeEnd` is the end of the just-detected OVERNIGHT chain (nil if none). Within
    /// `morningStillnessWindowMin` of it the block must clear the ordinary daytime guard AND show a
    /// SUSTAINED re-onset: resting HR below `morningReonsetRestingHRMult × baseline`. Outside the window this
    /// is the plain daytime-guard result.
    static func passesMorningStillnessGuard(_ p: Period, restingHR: Int?, baseline: Double?,
                                            morningWakeEnd: Int?,
                                            bandSleepState: [(ts: Int, state: Int)] = []) -> Bool {
        // Only a daytime block beginning within the post-wake window of an overnight chain is suspected.
        guard let wakeEnd = morningWakeEnd, p.start >= wakeEnd,
              (p.start - wakeEnd) <= morningStillnessWindowMin * 60 else {
            return passesDaytimeGuard(p, restingHR: restingHR, baseline: baseline)
        }
        // Suspected morning stillness needs at least the ordinary daytime guard.
        if !passesDaytimeGuard(p, restingHR: restingHR, baseline: baseline) { return false }
        // The strap's OWN banked band sleep_state: if it scored this block predominantly "asleep", KEEP it even on a
        // borderline HR dip. This only RESCUES a block the strap says was real sleep.
        if bandStateConfirmsAsleep(p, bandSleepState: bandSleepState) { return true }
        // Otherwise require the clearly-deeper dip of a true second sleep.
        guard let baseline = baseline, let resting = restingHR else { return false }
        return Double(resting) <= baseline * morningReonsetRestingHRMult
    }

    /// True when the strap's OWN persisted v18 band sleep_state over `[p.start, p.end]` reads "asleep"
    /// (`bandStateAsleep`) for at least `morningReonsetBandAsleepFrac` of in-block samples. Empty/absent band
    /// state → false (fall back to the HR bar); an "asleep" reading is never invented.
    static func bandStateConfirmsAsleep(_ p: Period, bandSleepState: [(ts: Int, state: Int)]) -> Bool {
        let inBlock = bandSleepState.filter { $0.ts >= p.start && $0.ts <= p.end }
        guard !inBlock.isEmpty else { return false }
        let asleep = inBlock.reduce(0) { $0 + ($1.state == bandStateAsleep ? 1 : 0) }
        return Double(asleep) / Double(inBlock.count) >= morningReonsetBandAsleepFrac
    }

    // MARK: - Band sleep_state WAKE-veto

    // The cardiorespiratory stager OVER-CALLS wake: an EEG-free stager reads a still, low-HR, not-quite-asleep
    // epoch as wake more often than the wearer was awake. WHOOP's own per-second sleep-state band (persisted
    // v18 @81 high-nibble `(sb>>4)&3`: 0 wake/1 still/2 asleep/3 up; banked as `sleepStateJSON`, gridded by
    // `sessionEpochSleepState`) is an INDEPENDENT signal: on banded nights it scores "asleep" across ~two-thirds
    // of the epochs Zoop calls wake, the reverse an order of magnitude less. Letting its "asleep" verdict VETO
    // an INTERIOR wake call recovers most spurious wake at near-zero downside. It works per EPOCH on the final
    // hypnogram and only ever turns wake INTO sleep.

    /// Default-OFF gate for the band sleep_state WAKE-veto. The PSG harness says the opposite is needed: against
    /// the 31-subject sleep-accel truth set the shipped recipe UNDER-calls wake (wake% 4.15 vs ~9.1 true), so a
    /// wake→light veto moves the population result AWAY from truth even though it fixes strap-disputed false
    /// wakes on HR-inflated nights. Flip only with PSG evidence (`sleeppsg --section variants`). An absent band
    /// stream (WHOOP 4.0 / unbanded window) is a no-op regardless.
    public static let bandStateWakeVetoEnabled: Bool = false

    /// New-nights-only cutoff for the veto. When the veto is on, a NON-ZERO unix-second cutoff restricts the
    /// correction to sessions with `start >= cutoffTs`, so flipping the default can't re-score months of
    /// banked nights upward. `0` applies the veto to every banded night. Inert while the flag is off; set it
    /// to the flip date together with the flag.
    public static let bandStateWakeVetoCutoffTs: Int = 0

    /// The stage a band-vetoed false-wake epoch becomes. The band (sleep_state == 2) means only "asleep" with
    /// NO light/deep/REM resolution, so the veto maps to generic "light" rather than inventing deep/REM
    /// minutes (which feed the recovery gate).
    static let bandVetoRecoverStage: String = "light"

    /// TRACE-ONLY line reporting what the (dormant) band wake-veto WOULD recover on a banded night, so a
    /// validator can gather the distribution without any output change. Namespaced `bandVeto(shadow):` and
    /// free of a `day=` / `t=…s` token so `CaptureAccumulator` never counts it as a captured day.
    static func bandVetoShadowLine(startTs: Int, recoveredMin: Double, rawEff: Double, shadowEff: Double) -> String {
        "bandVeto(shadow): startTs=\(startTs) recoveredMin=\(Int(recoveredMin.rounded())) "
            + "eff \(Int((rawEff * 100).rounded()))%->\(Int((shadowEff * 100).rounded()))%"
    }

    /// Band sleep_state WAKE-veto. Given a staged hypnogram `stages` (tiling `[start, end]`) and the strap's own
    /// per-timestamp band sleep_state, reclassify INTERIOR wake epochs the strap scored "asleep"
    /// (`bandStateAsleep`) to `bandVetoRecoverStage`. Conservative: only state 2 vetoes (still/up/wake stay
    /// wake); the LEADING and TRAILING wake blocks are never touched, so onset can't move earlier nor final
    /// wake later; it only turns wake INTO sleep. The band is gridded to the same 30 s epochs as
    /// `stagesJSON`. Empty band, flag off, or no interior sleep → `stages` unchanged. Applies to either stager.
    static func applyBandStateWakeVeto(_ stages: [StageSegment], start: Int, end: Int,
                                       bandSleepState: [(ts: Int, state: Int)],
                                       enabled: Bool = bandStateWakeVetoEnabled,
                                       cutoffTs: Int = bandStateWakeVetoCutoffTs) -> [StageSegment] {
        guard enabled, !bandSleepState.isEmpty, !stages.isEmpty, end > start else {
            return stages
        }
        // New-nights-only gate: a non-zero cutoff spares nights that started before it; `0` applies to all.
        if cutoffTs > 0, start < cutoffTs { return stages }
        // Per-epoch band on the 30 s stagesJSON grid, identical to the persisted sleepStateJSON.
        let states = sessionEpochSleepState(start: start, end: end, sleepState: bandSleepState)
        if states.isEmpty { return stages }
        let n = states.count
        // Boundaries sit on 30 s edges, so expanding the tiling to per-epoch stages and re-collapsing is an exact
        // round-trip (a no-op when nothing changes).
        func epochStart(_ i: Int) -> Int { start + Int(Double(i) * epochS) }
        var labels = [String](repeating: "wake", count: n)
        for i in 0..<n {
            let t = epochStart(i)
            if let seg = stages.first(where: { $0.start <= t && t < $0.end })
                ?? stages.first(where: { $0.start <= t && t <= $0.end }) {
                labels[i] = seg.stage
            }
        }
        // Interior = [firstSleep, lastSleep]; leading/trailing wake blocks are excluded.
        guard let onset = labels.firstIndex(where: { $0 != "wake" }),
              let finalWake = labels.lastIndex(where: { $0 != "wake" }), onset <= finalWake else {
            return stages   // no sleep at all → nothing to recover
        }
        var changed = false
        for i in onset...finalWake where labels[i] == "wake" && states[i] == bandStateAsleep {
            labels[i] = bandVetoRecoverStage
            changed = true
        }
        if !changed { return stages }   // the band disputed nothing → byte-identical hypnogram
        // Re-collapse consecutive same-stage epochs into segments tiling [start, end].
        var out: [StageSegment] = []
        for i in 0..<n {
            let segStart = epochStart(i)
            let segEnd = (i == n - 1) ? end : epochStart(i + 1)
            if let last = out.last, last.stage == labels[i] {
                out[out.count - 1].end = segEnd
            } else {
                out.append(StageSegment(start: segStart, end: segEnd, stage: labels[i]))
            }
        }
        if !out.isEmpty { out[out.count - 1].end = end }
        return out
    }

    /// Off-wrist HR-gap spans: contiguous HR-coverage gaps of at least `offWristHRGapMin` minutes WITHIN
    /// [p.start, p.end], as `[start, end)` sub-intervals (a wrist-OFF proxy: a worn strap streams ~1 Hz HR).
    /// The leading and trailing edges count too, and a run with NO in-run HR is one full-period gap. With no
    /// HR stream at all this returns [] (can't assert off-wrist without HR). Unioned with WRIST_OFF
    /// intervals by `offWristFraction`.
    static func offWristHRGapSpans(_ p: Period, hr: [HRSample]) -> [(start: Int, end: Int)] {
        if hr.isEmpty || p.end <= p.start { return [] }
        // Density gate: trust the HR-gap proxy only when the HR STREAM is dense enough that a long gap is
        // anomalous (a WHOOP 4.0 synced night has sparse HR whose natural gaps must not read as off-wrist).
        // Judged over the whole stream so a hole inside an otherwise dense worn day is still caught.
        let sortedAll = hr.sorted { $0.ts < $1.ts }
        let streamSpan = sortedAll[sortedAll.count - 1].ts - sortedAll[0].ts
        if streamSpan >= hrDenseSpacingS && hr.count < streamSpan / hrDenseSpacingS { return [] }
        let gapS = offWristHRGapMin * 60
        let seg = hr.filter { $0.ts >= p.start && $0.ts <= p.end }.sorted { $0.ts < $1.ts }
        // No HR inside a run long enough to matter: the whole period is one gap.
        if seg.isEmpty { return (p.end - p.start) >= gapS ? [(start: p.start, end: p.end)] : [] }
        var spans: [(start: Int, end: Int)] = []
        // Leading edge: run start to first sample.
        if seg[0].ts - p.start >= gapS { spans.append((start: p.start, end: seg[0].ts)) }
        // Interior: gaps between consecutive in-run samples.
        for i in 1..<seg.count where seg[i].ts - seg[i - 1].ts >= gapS {
            spans.append((start: seg[i - 1].ts, end: seg[i].ts))
        }
        // Trailing edge: last sample to run end.
        if p.end - seg[seg.count - 1].ts >= gapS { spans.append((start: seg[seg.count - 1].ts, end: p.end)) }
        return spans
    }

    /// Fractional off-wrist coverage of a candidate run [p.start, p.end] in [0, 1]: the length of the UNION of
    /// the HR-gap spans (`offWristHRGapSpans`) and the supplied WRIST_OFF→WRIST_ON `wristOff` intervals,
    /// clipped to the run, over its duration. The caller drops the run only past `maxOffWristSleepFraction`;
    /// the union avoids double-counting overlapping gap and event time.
    static func offWristFraction(_ p: Period, hr: [HRSample], wristOff: [(start: Int, end: Int)]) -> Double {
        let dur = p.end - p.start
        if dur <= 0 { return 0 }
        // Every off-wrist span, clipped to the run: HR-gap proxy spans + explicit wrist-off events.
        var spans = offWristHRGapSpans(p, hr: hr)
        for w in wristOff {
            let s = max(w.start, p.start), e = min(w.end, p.end)
            if e > s { spans.append((start: s, end: e)) }
        }
        if spans.isEmpty { return 0 }
        // Union the spans so overlapping time is counted once, then sum the covered length.
        spans.sort { $0.start < $1.start }
        var covered = 0, curStart = spans[0].start, curEnd = spans[0].end
        for sp in spans.dropFirst() {
            if sp.start <= curEnd {
                curEnd = max(curEnd, sp.end)              // overlapping/adjacent → extend
            } else {
                covered += curEnd - curStart             // disjoint → bank the run
                curStart = sp.start; curEnd = sp.end
            }
        }
        covered += curEnd - curStart
        return Double(covered) / Double(dur)
    }

    // MARK: - detectSleep (public)

    /// Detect sleep sessions from biometric streams. Empty/absent gravity → []. Gravity-only input degrades
    /// gracefully (HR/RR/resp refinements skipped).
    ///
    /// - `tzOffsetSeconds`: UTC offset used ONLY to place each window's center on a local clock for the daytime
    ///   guard; 0 keeps the pure function and its tests UTC.
    /// - `wristOff`: off-wrist `[start, end)` intervals (via `AnalyticsEngine.offWristIntervals`) sharpening the
    ///   HR-gap backstop; a run is dropped at `maxOffWristSleepFraction` coverage. Default empty.
    /// - `bandSleepState`: the strap's own v18 band sleep_state per timestamp, used ONLY to confirm a borderline
    ///   morning re-onset; it can rescue a real-sleep block, never fabricate one.
    /// - `useSleepStagerV2`: which recipe stages an accepted night (detection is unchanged). The PARAMETER
    ///   defaults false so pure callers and frozen-golden tests stay byte-identical, but the SHIPPED app threads
    ///   `PuffinExperiment.experimentalSleepV2Enabled`, default ON, so normal nights are staged by V2.
    /// - `sleepHRBaseline`: the wearer's personalised overnight HR band, used by `confirmSleepWithHR` instead of
    ///   the day-median. Default nil keeps the day-median.
    public static func detectSleep(hr: [HRSample] = [],
                                   rr: [RRInterval] = [],
                                   resp: [RespSample] = [],
                                   gravity: [GravitySample],
                                   tzOffsetSeconds: Int = 0,
                                   wristOff: [(start: Int, end: Int)] = [],
                                   bandSleepState: [(ts: Int, state: Int)] = [],
                                   useSleepStagerV2: Bool = false,
                                   sleepHRBaseline: Double? = nil,
                                   onsetTuning: SleepOnsetTuning = .standard,
                                   traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        // With a trace sink we MUST run the live ladder, not a memoized result, so each gate verdict is emitted
        // for THIS night. The trace never changes the sessions; with no sink the path below is unchanged.
        if let traceSink {
            return detectSleepUncached(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                       tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                       bandSleepState: bandSleepState, useSleepStagerV2: useSleepStagerV2,
                                       sleepHRBaseline: sleepHRBaseline, onsetTuning: onsetTuning,
                                       traceSink: traceSink)
        }
        // Memoized: the heaviest analytics call (sorts the dense full-day gravity stream, builds the still spine,
        // stages every accepted run), called once PER DAY by the post-sync scoring loop. The key covers every input
        // that steers detection or staging (four streams, tz offset, off-wrist intervals, band state, V2 toggle).
        // Result-only and bounded. Mixes x/y/z IEEE-754 bits in order (never their lossy sum) to match Android.
        let key = DetectKey(
            grav: StreamFingerprint.of(gravity, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            }),
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            resp: StreamFingerprint.of(resp, ts: { $0.ts }, quant: { $0.raw }),
            tz: tzOffsetSeconds,
            wristOff: StreamFingerprint.of(wristOff, ts: { $0.start }, quant: { $0.end }),
            band: StreamFingerprint.of(bandSleepState, ts: { $0.ts }, quant: { $0.state }),
            v2: useSleepStagerV2,
            sleepHRBaseline: sleepHRBaseline,
            onsetTuning: onsetTuning)
        return detectSleepCache.value(key) {
            detectSleepUncached(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                bandSleepState: bandSleepState, useSleepStagerV2: useSleepStagerV2,
                                sleepHRBaseline: sleepHRBaseline, onsetTuning: onsetTuning,
                                traceSink: nil)
        }
    }

    private struct DetectKey: Hashable {
        let grav: StreamFingerprint; let hr: StreamFingerprint
        let rr: StreamFingerprint; let resp: StreamFingerprint
        let tz: Int
        let wristOff: StreamFingerprint; let band: StreamFingerprint
        let v2: Bool
        let sleepHRBaseline: Double?
        let onsetTuning: SleepOnsetTuning
    }
    /// About the number of distinct days in a scoring window; FIFO-evicted, holds only small session arrays.
    private static let detectSleepCache = AnalyticsMemoCache<DetectKey, [SleepSession]>(capacity: 40)

    /// The detection+staging pipeline behind the memoizing public entry.
    private static func detectSleepUncached(hr: [HRSample],
                                            rr: [RRInterval],
                                            resp: [RespSample],
                                            gravity: [GravitySample],
                                            tzOffsetSeconds: Int,
                                            wristOff: [(start: Int, end: Int)],
                                            bandSleepState: [(ts: Int, state: Int)],
                                            useSleepStagerV2: Bool,
                                            sleepHRBaseline: Double? = nil,
                                            onsetTuning: SleepOnsetTuning = .standard,
                                            traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        if grav.count < 2 { return [] }

        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sortedByTsStable()   // stable: keeps #823 emission order within a second
        let respS = resp.sorted { $0.ts < $1.ts }

        let baseline = hrBaseline(hrS)
        // Sparse-gravity gate: an un-unlocked WHOOP 5.0 backfills clumped gravity (~25% coverage). Only when
        // sparse do the robustness branches engage; a dense 4.0 night follows the original path.
        let sparse = isGravitySparse(grav, hr: hrS)

        let deltas = gravityDeltas(grav)
        let flags = classifyStill(grav, deltas)
        var runs = buildRuns(grav, flags, sparse: sparse, hr: hrS, baseline: baseline)
        runs = mergePeriods(runs)
        let minSleepS = minSleepMin * 60
        // A night whose sleep runs are ALL shorter than minSleepMin yields NO session however much they add up to (a
        // real capture: five runs, 298 minutes, each about a minute short). The bridge was off because it is gated
        // on a SPARSE night and this one was dense (99.9% gravity coverage).
        //
        // So the bridge also runs when the night is fragmented to nothing: "today's answer is zero", so a night that
        // currently scores can't change. Requiring the SUM to clear the floor keeps brief stirs from becoming a
        // night, and the bridge's own rules (gap, active run, HR band) still refuse underneath. Deliberately NOT
        // passed to buildRuns, whose `sparse` decides how runs are FORMED. Evaluated unconditionally so the trace
        // reports it on sparse nights too.
        let fragmentedToNothing = isFragmentedToNothing(
            runs.filter { $0.stage == "sleep" }.map { $0.end - $0.start }, minSleepS: minSleepS)
        let bridgeEnabled = sparse || fragmentedToNothing
        // Re-stitch sleep runs fragmented by gravity dropouts, before minSleepMin.
        let runsBeforeBridge = traceSink == nil ? 0 : runs.filter { $0.stage == "sleep" }.count
        // Capture per-pair reasons BEFORE the merge mutates `runs`, so a bridge that changed nothing still says why.
        let bridgeResult = bridgeSparseSleepTraced(runs, sparse: bridgeEnabled, hr: hrS, baseline: baseline)
        let bridgeAttempts = bridgeResult.1
        runs = bridgeResult.0
        // Trace the bridge result whenever it was ENABLED (sparse, or fragmented-to-nothing) and only when tracing.
        if let traceSink, bridgeEnabled {
            let runsAfterBridge = runs.filter { $0.stage == "sleep" }.count
            // BOTH gates are reported, always, as their own k=v keys, so the key set is identical on every night for
            // a reader diffing nights or any k=v parser.
            traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0,
                verdict: runsAfterBridge < runsBeforeBridge ? .kept : .dropped, gate: "sparseBridge",
                detail: "sparse=\(sparse) fragmentedToNothing=\(fragmentedToNothing) "
                    + "gapMin=\(sparseBridgeGapMin) runsBefore=\(runsBeforeBridge) runsAfter=\(runsAfterBridge)"))
            // One line per pair the bridge CONSIDERED. An empty list now means there was no candidate at all: one
            // sleep run, or fragments split by two or more consecutive active runs.
            if bridgeAttempts.isEmpty {
                traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0, verdict: .dropped,
                    gate: "sparseBridge",
                    detail: "no candidate pairs (one sleep run, or fragments split by consecutive active runs)"))
            }
            for (i, a) in bridgeAttempts.enumerated() {
                traceSink(GateTrace.runLine(index: -1, startTs: 0, endTs: 0,
                    verdict: a.bridged ? .kept : .dropped, gate: "sparseBridgePair",
                    detail: "pair=\(i) gapMin=\(a.gapMin) activeMin=\(a.activeMin) activeCapMin=\(a.activeCapMin) "
                        + "hrInSleepBand=\(a.hrInSleepBand) reason=\(a.reason)"))
            }
        }

        var sessions: [SleepSession] = []
        // Continuous-sleep chain tracking so an overnight sleep running PAST the daytime-band start (a late wake,
        // or a brief morning stir then back to sleep) isn't mistaken for an isolated nap and truncated. A daytime
        // run skips the nap guard ONLY when it directly continues (≤ nightContinuationGap) a chain that BEGAN
        // overnight; isolated daytime stillness still faces the full guard.
        let continuationGapS = nightContinuationGapMin * 60
        var chainPrevEnd: Int? = nil       // end of the last accepted sleep run
        var chainFromOvernight = false     // did the current contiguous chain begin overnight?
        // Sleep & Rest test mode: each candidate sleep run emits ONE verdict line naming the gate that kept or
        // dropped it; `traceSink?(...)` never alters `sessions`. `runIndex` counts only sleep-stage runs.
        var runIndex = -1
        // Trace-only counters for the detection summary line before `return`; a big detectedSpan with most runs
        // dropped by the 60-min gate is the fragmentation signature.
        var sleepRunsSeen = 0
        var minSleepDrops = 0
        var firstSleepStart = Int.max
        var lastSleepEnd = 0
        for p in runs {
            if p.stage != "sleep" { continue }
            runIndex += 1
            sleepRunsSeen += 1
            firstSleepStart = min(firstSleepStart, p.start)
            lastSleepEnd = max(lastSleepEnd, p.end)
            let spanMin = (p.end - p.start) / 60
            if (p.end - p.start) <= minSleepS {
                minSleepDrops += 1
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "minSleepMin",
                    detail: "spanMin=\(spanMin) minSleepMin=\(minSleepMin)"))
                continue
            }
            // Physiological in-bed span cap: a main-sleep run longer than ~16 h is a bad-clock artefact. Drop it
            // rather than report or truncate it (truncating would fabricate a wake time); checked before staging.
            if (p.end - p.start) > maxMainSleepSpanS {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "maxMainSleepSpanS",
                    detail: "spanMin=\(spanMin) maxMainSleepSpanMin=\(maxMainSleepSpanS / 60)"))
                continue
            }
            if !confirmSleepWithHR(p, hr: hrS, baseline: baseline, grav: grav, sleepHRBaseline: sleepHRBaseline) {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "hrConfirm",
                    detail: "hrSleepBaselineMult=\(hrSleepBaselineMult) baseline=\(baseline.map { Int($0) } ?? -1)"))
                continue
            }
            // Off-wrist backstop (fractional rule): a wrist-OFF stretch is still gravity with no HR and slips past the
            // spine and the daytime guard. Drop the run only when off-wrist COVERAGE (union of long HR-gap spans and
            // WRIST_OFF→WRIST_ON intervals) reaches maxOffWristSleepFraction, so a real night with a short off-wrist
            // tail or a stray blip survives. Checked BEFORE the night-tail exemption (off-wrist time is off-wrist
            // day or night) and does not re-anchor the chain.
            let offFrac = offWristFraction(p, hr: hrS, wristOff: wristOff)
            if offFrac >= maxOffWristSleepFraction {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: "offWrist",
                    detail: "offWristFrac=\(round2(offFrac)) max=\(maxOffWristSleepFraction)"))
                continue
            }
            // HR-confirmed onset: cut a leading stretch of quiet-but-awake time whose HR never came down to the
            // sleeping level. Zoop: thresholds follow the wearer's strictness setting, and a learned personal offset
            // moves an OVERNIGHT onset, never before the wrist went still. Both are no-ops at their defaults.
            let ruleOnset = hrConfirmedOnset(p, hr: hrS, grav: grav, thresholds: onsetTuning.thresholds)
            let onsetStart = isDaytimeCenter(p, tzOffsetSeconds: tzOffsetSeconds)
                ? ruleOnset
                : applyingOnsetOffset(onsetTs: ruleOnset, runStart: p.start, runEnd: p.end,
                                      offsetMin: onsetTuning.personalOffsetMin)
            if onsetStart != p.start {
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .kept, gate: "hrOnsetTrim",
                    detail: "trimmedMin=\((onsetStart - p.start) / 60) onsetTs=\(onsetStart)"
                        + (onsetTuning == .standard ? "" : " tuning=\(onsetTuning.signature) ruleOnsetTs=\(ruleOnset)")))
            }
            let p = Period(stage: p.stage, start: onsetStart, end: p.end)
            // Daytime false-sleep guard: a window centered in the daytime band must clear a stricter bar.
            // Overnight windows skip it. restingHR is computed here and reused below.
            let resting = sessionRestingHR(start: p.start, end: p.end, hr: hrS)
            let continuesChain = chainPrevEnd.map { p.start - $0 <= continuationGapS } ?? false
            let isNightTail = continuesChain && chainFromOvernight   // the night's tail, not a nap
            // When the prior accepted chain BEGAN overnight, its wake (`chainPrevEnd`) anchors the morning-stillness
            // window; a non-night-tail daytime block within it must clear the STRONGER re-onset bar.
            let morningWakeEnd = chainFromOvernight ? chainPrevEnd : nil
            let isDaytime = isDaytimeCenter(p, tzOffsetSeconds: tzOffsetSeconds)
            // Evaluate the morning-stillness guard ONLY for a daytime-centered run, preserving the short-circuit.
            let passesMorning = isDaytime
                ? passesMorningStillnessGuard(p, restingHR: resting, baseline: baseline,
                                              morningWakeEnd: morningWakeEnd,
                                              bandSleepState: bandSleepState)
                : true
            if isDaytime, !passesMorning, !isNightTail {
                let gateName = (morningWakeEnd != nil) ? "morningStillness" : "daytimeGuard"
                traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                    verdict: .dropped, gate: gateName,
                    detail: "daytime=true restingHR=\(resting ?? -1) baseline=\(baseline.map { Int($0) } ?? -1) nightTail=false"))
                continue
            }
            let rawStages = useSleepStagerV2
                ? SleepStagerV2.stageSession(start: p.start, end: p.end, grav: grav,
                                             hr: hrS, rr: rrS, resp: respS)
                : stageSession(start: p.start, end: p.end, grav: grav,
                               hr: hrS, rr: rrS, resp: respS)
            // Band sleep_state WAKE-veto: recover INTERIOR false-wake epochs the strap's own band scored "asleep". A
            // no-op without a band (WHOOP 4.0) or with the flag off; stager-agnostic. Efficiency below uses the
            // corrected stages.
            let stages = applyBandStateWakeVeto(rawStages, start: p.start, end: p.end,
                                                bandSleepState: bandSleepState)
            let eff = efficiency(start: p.start, end: p.end, stages: stages)
            let avgHrv = sessionAvgHRV(start: p.start, end: p.end, rr: rrS, stages: stages)
            sessions.append(SleepSession(start: p.start, end: p.end, efficiency: eff,
                                         stages: stages, restingHR: resting, avgHRV: avgHrv))
            traceSink?(GateTrace.runLine(index: runIndex, startTs: p.start, endTs: p.end,
                verdict: .kept, gate: "accepted",
                detail: "spanMin=\(spanMin) eff=\(round2(eff)) restingHR=\(resting ?? -1) daytime=\(isDaytime)"))
            // Shadow trace: the veto is dormant, but its recovered-vs-reverse ratio can only come from banded
            // nights. Compute what it WOULD recover and trace it. OUTPUT-NEUTRAL (`stages`/`eff` are the flag-gated
            // values; nothing reads `shadowStages`) and guarded on `traceSink`, so zero production cost. Retire once
            // the veto flips.
            if let traceSink, !bandStateWakeVetoEnabled, !bandSleepState.isEmpty {
                // `cutoffTs: 0` on purpose: the shadow measures the FULL veto potential across every banded night.
                let shadowStages = applyBandStateWakeVeto(rawStages, start: p.start, end: p.end,
                                                          bandSleepState: bandSleepState,
                                                          enabled: true, cutoffTs: 0)
                let shadowEff = efficiency(start: p.start, end: p.end, stages: shadowStages)
                let recoveredMin = (shadowEff - eff) * Double(p.end - p.start) / 60.0
                if recoveredMin >= 1.0 {
                    traceSink(bandVetoShadowLine(startTs: p.start, recoveredMin: recoveredMin,
                                                 rawEff: eff, shadowEff: shadowEff))
                }
            }
            // A run that does NOT continue the chain re-anchors it on this run's onset.
            if !continuesChain { chainFromOvernight = isOvernightOnset(p.start, tzOffsetSeconds: tzOffsetSeconds) }
            chainPrevEnd = p.end
        }
        sessions.sort { $0.start < $1.start }
        // One glanceable summary line of the whole detection pass: a large `detectedSpanMin` with most runs
        // `droppedMinSleep` and a small `survivingSpanMin` is the "slept ~8h, only ~1h confirmed" signature.
        if let traceSink {
            let detectedSpanMin = lastSleepEnd > firstSleepStart ? (lastSleepEnd - firstSleepStart) / 60 : 0
            let survivingSpanMin = sessions.reduce(0) { $0 + ($1.end - $1.start) } / 60
            traceSink("sleep-detect summary: sleepRuns=\(sleepRunsSeen) droppedMinSleep=\(minSleepDrops) "
                + "kept=\(sessions.count) detectedSpanMin=\(detectedSpanMin) survivingSpanMin=\(survivingSpanMin) "
                + "sparse=\(sparse) grav=\(grav.count) hr=\(hrS.count)")
        }
        return sessions
    }

    /// asleep / in-bed in [0, 1]; asleep = in-bed − wake.
    static func efficiency(start: Int, end: Int, stages: [StageSegment]) -> Double {
        let inBed = Double(end - start)
        if inBed <= 0 { return 0 }
        let wake = stages.filter { SleepStageVocabulary.isWake($0.stage) }.reduce(0.0) { $0 + Double($1.end - $1.start) }
        let asleep = max(0.0, inBed - wake)
        return min(1.0, asleep / inBed)
    }

    // MARK: - Stage 1–3: staging over a 30 s epoch grid

    /// First persistent-sleep epoch (onset) and last sleep epoch (final wake).
    static func onsetAndFinalWake(_ ckFlags: [Bool]) -> (Int, Int) {
        let n = ckFlags.count
        if n == 0 { return (0, 0) }
        var onset: Int? = nil
        var run = 0
        for (i, s) in ckFlags.enumerated() {
            run = s ? run + 1 : 0
            if run >= onsetPersistEpochs { onset = i - onsetPersistEpochs + 1; break }
        }
        var final: Int? = nil
        for i in stride(from: n - 1, through: 0, by: -1) where ckFlags[i] { final = i; break }
        let o = onset ?? 0
        var f = final ?? (n - 1)
        if f < o { f = n - 1 }
        return (o, f)
    }

    /// Stage a FORCED window from raw streams (no boundary detection) with the same per-epoch classifier as
    /// the detection path, over exactly `[start, end]` and returning StageSegments. The sleep-edit path uses
    /// this so extending a boundary recovers real stages from the sensor data rather than a fabricated
    /// "awake" block.
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // Stage each window at most once per (window, input-fingerprint): `detectSleep` and the sleep-edit restage
        // call this with byte-identical streams across passes. The key folds in the window and a strided
        // fingerprint of every stream V1 READS (grav/hr/rr/resp; resp IS consumed here, unlike V2).
        // Result-only and bounded.
        let key = V1StageKey(
            start: start, end: end,
            grav: StreamFingerprint.of(grav, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            }),
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            resp: StreamFingerprint.of(resp, ts: { $0.ts }, quant: { $0.raw }))
        return stageSessionCache.value(key) {
            stageSessionUncached(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        }
    }

    private struct V1StageKey: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint
        let rr: StreamFingerprint; let resp: StreamFingerprint
    }
    private static let stageSessionCache = AnalyticsMemoCache<V1StageKey, [StageSegment]>(capacity: 32)

    /// The V1 staging recipe behind the memoizing public entry.
    private static func stageSessionUncached(start: Int, end: Int, grav: [GravitySample],
                                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return [StageSegment(start: start, end: end, stage: "light")] }

        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }

        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return [StageSegment(start: start, end: end, stage: "light")] }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)

        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, features: feats,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)
        // Conservative fragment merge: absorb sub-3-min stage flecks (the WHOOP 5/MG sparse-motion artefact)
        // without erasing genuine multi-minute transitions. Display/scoring only; detection is unchanged.
        labels = mergeFragments(labels)

        // Pre-onset and post-final-wake epochs are not sleep → force wake.
        for i in 0..<labels.count where i < onsetIdx || i > finalWakeIdx { labels[i] = "wake" }

        // Merge consecutive same-stage epochs into segments tiling [start, end].
        var segments: [StageSegment] = []
        for (i, stage) in labels.enumerated() {
            let segStart = Int(grid.edges[i].rounded())
            let segEnd = Int(grid.edges[i + 1].rounded())
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        if !segments.isEmpty { segments[segments.count - 1].end = end }
        return segments
    }

    // MARK: - Per-epoch motion

    /// Per-epoch MOTION magnitudes for a session window on the SAME 30 s grid as `stageSession`'s `stagesJSON`
    /// (one entry per epoch). Each value is the epoch's summed |Δgravity| (the raw Cole–Kripke activity
    /// count), banked so later passes and the UI can read movement without the raw gravity stream. Returns
    /// `[]` when the window has too little gravity to grid, so the caller persists NULL rather than a
    /// fabricated zero series.
    public static func sessionEpochMotion(start: Int, end: Int, grav: [GravitySample]) -> [Double] {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return [] }
        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }
        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: [], rr: [], resp: [])
        return grid.counts
    }

    /// The strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up) gridded onto the SAME 30 s epoch grid as
    /// `stagesJSON` / `sessionEpochMotion`, for `WhoopStore.persistSessionSleepState` and the morning re-onset
    /// guard. EMPTY when the session has no band-state samples (WHOOP 4.0, unbanded window): absent stays
    /// absent. Each epoch takes the band's LAST state in its window, carrying the previous state forward (a step
    /// function); leading epochs take the first sample's. The band code is carried verbatim.
    public static func sessionEpochSleepState(start: Int, end: Int,
                                              sleepState: [(ts: Int, state: Int)]) -> [Int] {
        let seg = rowsBetween(sleepState, start: start, end: end) { $0.ts }.sorted { $0.ts < $1.ts }
        guard !seg.isEmpty, end > start else { return [] }
        let nEpochs = max(1, Int(ceil(Double(end - start) / epochS)))
        var out = [Int](repeating: seg[0].state, count: nEpochs)   // lead-in = first sample's state
        var last = seg[0].state
        var si = 0
        for i in 0..<nEpochs {
            let epochEnd = start + Int(Double(i + 1) * epochS)
            // Advance through every sample at-or-before this epoch's window; the LAST one wins.
            while si < seg.count && seg[si].ts < epochEnd {
                last = seg[si].state
                si += 1
            }
            out[i] = last   // carry-forward when the epoch had no sample of its own
        }
        return out
    }

    // MARK: - Epoch grid

    struct EpochGrid {
        let start: Double
        let end: Double
        let edges: [Double]
        let counts: [Double]      // per-epoch summed |Δgravity| (raw, pre-rescale)
        let moveFrac: [Double]    // scale-robust per-epoch moving-sample fraction
        let hr: [Double]          // per-epoch mean HR (bpm) or NaN
        let rr: [[Double]]        // per-epoch RR intervals (ms)
        let resp: [[Double]]      // per-epoch raw respiration samples
        var nEpochs: Int { counts.count }
        func epochMid(_ i: Int) -> Double { edges[i] + epochS / 2.0 }
    }

    static func buildEpochGrid(start: Double, end: Double,
                               gravTimes: [Int], gravDeltas: [Double],
                               hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> EpochGrid {
        if end <= start {
            return EpochGrid(start: start, end: end, edges: [start], counts: [],
                             moveFrac: [], hr: [], rr: [], resp: [])
        }
        let nEpochs = max(1, Int(ceil((end - start) / epochS)))
        var edges = (0...nEpochs).map { start + Double($0) * epochS }
        edges[nEpochs] = max(edges[nEpochs], end)

        var counts = [Double](repeating: 0, count: nEpochs)
        var moveN = [Int](repeating: 0, count: nEpochs)
        var gravN = [Int](repeating: 0, count: nEpochs)
        var hrSum = [Double](repeating: 0, count: nEpochs)
        var hrCnt = [Int](repeating: 0, count: nEpochs)
        var rrBuckets = [[Double]](repeating: [], count: nEpochs)
        var respBuckets = [[Double]](repeating: [], count: nEpochs)

        func idx(_ ts: Double) -> Int? {
            if ts < start || ts >= end {
                if ts == end { return nEpochs - 1 }
                return nil
            }
            let i = Int((ts - start) / epochS)
            return min(i, nEpochs - 1)
        }

        for (t, d) in zip(gravTimes, gravDeltas) {
            guard let i = idx(Double(t)) else { continue }
            counts[i] += d
            gravN[i] += 1
            if d >= moveDeltaThresholdG { moveN[i] += 1 }
        }
        for r in hr {
            guard let i = idx(Double(r.ts)) else { continue }
            hrSum[i] += Double(r.bpm); hrCnt[i] += 1
        }
        for r in rr {
            guard let i = idx(Double(r.ts)) else { continue }
            rrBuckets[i].append(Double(r.rrMs))
        }
        for r in resp {
            guard let i = idx(Double(r.ts)) else { continue }
            respBuckets[i].append(Double(r.raw))
        }

        let hrMean = (0..<nEpochs).map { hrCnt[$0] > 0 ? hrSum[$0] / Double(hrCnt[$0]) : Double.nan }
        // No gravity coverage → 1.0 (treat as moving; conservative).
        let moveFrac = (0..<nEpochs).map { gravN[$0] > 0 ? Double(moveN[$0]) / Double(gravN[$0]) : 1.0 }

        return EpochGrid(start: start, end: end, edges: edges, counts: counts,
                         moveFrac: moveFrac, hr: hrMean, rr: rrBuckets, resp: respBuckets)
    }

    // MARK: - Cole–Kripke

    static func rescaleCounts(_ counts: [Double]) -> [Double] {
        counts.map { min($0 / ckCountDivisor, ckCountClip) }
    }

    static func coleKripke(_ rescaled: [Double]) -> [Bool] {
        let n = rescaled.count
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            var si = 0.0
            for (k, w) in ckWeights.enumerated() {
                let j = i - ckBack + k
                let a = (j >= 0 && j < n) ? rescaled[j] : 0.0
                si += w * a
            }
            si *= ckScale
            flags.append(si < 1.0)
        }
        return flags
    }

    // MARK: - Walch difference-of-Gaussians HR variability

    static func gaussianKernel(sigmaS: Double, dtS: Double = epochS) -> [Double] {
        let sigma = max(sigmaS / dtS, 1e-6)  // σ in epochs
        let radius = max(1, Int(ceil(3 * sigma)))
        var k = [Double]()
        for x in -radius...radius { k.append(exp(-0.5 * pow(Double(x) / sigma, 2))) }
        let sum = k.reduce(0, +)
        return k.map { $0 / sum }
    }

    /// Same-length convolution with reflect padding (edge-stable).
    static func convolveReflect(_ x: [Double], _ kernel: [Double]) -> [Double] {
        let r = kernel.count / 2
        // A signal shorter than the kernel radius can't be reflect-padded; return it unchanged rather than index
        // out of bounds (defensive: the only caller is gated by the 60-min session floor).
        if r == 0 || x.count <= r { return x }
        // Reflect padding: numpy 'reflect' mirrors WITHOUT repeating the edge sample.
        var padded = [Double]()
        padded.reserveCapacity(x.count + 2 * r)
        for i in 0..<r { padded.append(x[r - i]) }            // x[r], x[r-1], ... x[1]
        padded.append(contentsOf: x)
        for i in 0..<r { padded.append(x[x.count - 2 - i]) }  // x[n-2], x[n-3], ...
        var out = [Double]()
        out.reserveCapacity(x.count)
        let m = kernel.count
        for i in 0...(padded.count - m) {
            var acc = 0.0
            for j in 0..<m { acc += padded[i + j] * kernel[m - 1 - j] }
            out.append(acc)
            if out.count == x.count { break }
        }
        return out
    }

    /// DoG-filtered HR (σ1=120 s minus σ2=600 s). NaNs are linearly interpolated first; all-NaN → zeros.
    static func dogHRVariability(_ hrPerEpoch: [Double]) -> [Double] {
        let n = hrPerEpoch.count
        if n == 0 { return [] }
        let maskIdx = (0..<n).filter { !hrPerEpoch[$0].isNaN }
        if maskIdx.isEmpty { return [Double](repeating: 0, count: n) }

        // Linear interpolation over the grid (numpy.interp semantics: clamp at edges).
        var filled = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if !hrPerEpoch[i].isNaN { filled[i] = hrPerEpoch[i]; continue }
            if i <= maskIdx.first! { filled[i] = hrPerEpoch[maskIdx.first!]; continue }
            if i >= maskIdx.last! { filled[i] = hrPerEpoch[maskIdx.last!]; continue }
            var lo = maskIdx.first!, hi = maskIdx.last!
            for m in maskIdx { if m <= i { lo = m } ; if m >= i { hi = m; break } }
            if hi == lo { filled[i] = hrPerEpoch[lo] }
            else {
                let frac = Double(i - lo) / Double(hi - lo)
                filled[i] = hrPerEpoch[lo] + frac * (hrPerEpoch[hi] - hrPerEpoch[lo])
            }
        }

        let k1 = gaussianKernel(sigmaS: hrDogSigma1S)
        let k2 = gaussianKernel(sigmaS: hrDogSigma2S)
        let g1 = convolveReflect(filled, k1)
        let g2 = convolveReflect(filled, k2)
        return (0..<n).map { g1[$0] - g2[$0] }
    }

    // MARK: - Respiration rate + RRV (raw 1 Hz)

    /// Estimate respiratory rate (breaths/min) and RRV (s) from a raw resp window: detrend, peak-pick (≥2 s
    /// apart), breath intervals (1.5–12 s), rate = 60/median interval, RRV = std of intervals. (nan, nan) when
    /// there are too few samples.
    static func respRateAndRRV(_ respRaw: [Double], dtS: Double = 1.0) -> (Double, Double) {
        let nan = Double.nan
        if respRaw.count < 8 { return (nan, nan) }
        let mean = respRaw.reduce(0, +) / Double(respRaw.count)
        let x = respRaw.map { $0 - mean }
        if x.allSatisfy({ abs($0) < 1e-12 }) { return (nan, nan) }

        let std = standardDeviation(x)
        if std <= 0 { return (nan, nan) }

        let minDistance = max(2, Int((2.0 / dtS).rounded()))
        let peaks = findPeaks(x, distance: minDistance, height: 0.0)
        if peaks.count < 3 { return (nan, nan) }

        var intervals: [Double] = []
        for i in 1..<peaks.count {
            let iv = Double(peaks[i] - peaks[i - 1]) * dtS
            if iv >= 1.5 && iv <= 12.0 { intervals.append(iv) }
        }
        if intervals.count < 2 { return (nan, nan) }
        let rate = 60.0 / HRVAnalyzer.median(intervals)
        let rrv = standardDeviation(intervals)  // population std (numpy default)
        return (rate, rrv)
    }

    /// Local-maxima peak finder mirroring scipy.find_peaks(distance, height): a sample is a peak if strictly
    /// greater than both neighbours and ≥ height; peaks closer than `distance` keep the taller.
    static func findPeaks(_ x: [Double], distance: Int, height: Double) -> [Int] {
        let n = x.count
        if n < 3 { return [] }
        var candidates: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i] > x[i - 1] && x[i] >= height {
                // Flat plateaus: find the right edge.
                var j = i
                while j + 1 < n && x[j + 1] == x[i] { j += 1 }
                if j + 1 < n && x[j + 1] < x[i] {
                    candidates.append((i + j) / 2)  // plateau midpoint
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        if distance <= 1 || candidates.isEmpty { return candidates }
        // Enforce minimum distance, greedily keeping the tallest. Ties break on the lower index so equal-height
        // peaks resolve deterministically (Swift's sorted(by:) is not guaranteed stable).
        let byHeight = candidates.sorted { x[$0] != x[$1] ? x[$0] > x[$1] : $0 < $1 }
        var keep = [Bool](repeating: true, count: candidates.count)
        let indexOf = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1, $0) })
        for p in byHeight {
            guard let pi = indexOf[p], keep[pi] else { continue }
            for (qi, q) in candidates.enumerated() where qi != pi && keep[qi] {
                if abs(q - p) < distance { keep[qi] = false }
            }
        }
        return candidates.enumerated().filter { keep[$0.offset] }.map { $0.element }.sorted()
    }

    // MARK: - Respiration rate from R-R (RSA) — WHOOP5 on-wire path

    /// RSA tachogram resample rate (Hz); 4 Hz is the standard HRV grid.
    static let rsaResampleHz = 4.0

    /// Moving-mean detrend window for the RSA tachogram (seconds).
    static let rsaDetrendWindowS = 8.0

    /// Minimum spacing between breath peaks on the tachogram (seconds) → ≤24 bpm.
    static let rsaMinPeakDistanceS = 2.5

    /// Per-window length for the per-window rate estimate (seconds).
    static let rsaWindowS = 300.0

    /// Wall-clock seconds a beat-to-beat step may exceed its own RR before the series is treated as SPLICED
    /// there. `ts` is whole seconds, so 1 s is quantisation, not a gap; the blocks that prompted this were
    /// 30-45 s. Provisional: wide enough that only an unambiguous dropout trips it, not tuned to a corpus.
    static let rsaGapToleranceS = 3.0

    /// Physiologic breath-interval band (seconds): 0.1–0.4 Hz = 6–24 breaths/min.
    static let rsaMinBreathIntervalS = 2.5   // 24 bpm
    static let rsaMaxBreathIntervalS = 10.0  // 6 bpm

    /// THE canonical plausible sleeping-respiratory-rate band (bpm). The RSA peak-pick can yield 6–8 bpm at its
    /// noise floor but every consumer (illness/readiness gates) only acts on 8–25, so `respRateFromRR` clamps
    /// to this band (NaN outside) and the stored value never disagrees with what is acted on.
    public static let respPlausibleRangeBpm: ClosedRange<Double> = 8.0...25.0

    /// APPROXIMATE respiratory rate (breaths/min) from the R-R stream via respiratory sinus arrhythmia (RSA),
    /// for when no raw resp ADC channel exists (WHOOP5 v18 is RR-only). An on-device estimate that tracks but
    /// does not equal a chest-band / capnography rate.
    ///
    /// Per in-bed session [start, end]: range-filter the RR rows (keeping `ts`); reconstruct beat times by
    /// cumulative RR sum, noting where the wall clock outran the beats (a dropout the sum cannot represent, so
    /// a splice); resample to ~4 Hz; detrend with a centered moving mean (rsaDetrendWindowS); per ~5-min window,
    /// SKIPPING any containing a splice, findPeaks (min distance rsaMinPeakDistanceS), keep intervals in the
    /// 6–24 bpm band, rate = 60 / median; take the median across windows.
    ///
    /// Known bound: the detrend mean spans ±rsaDetrendWindowS/2, so a splice just inside one window leaves ~4 s of
    /// contamination at the neighbour's edge. That window is KEPT: discarding five minutes to avoid four seconds
    /// costs more than it saves. Returns NaN when too few intervals survive.
    static func respRateFromRR(_ rr: [RRInterval], start: Int, end: Int) -> Double {
        let nan = Double.nan
        if end <= start { return nan }

        // 1. In-bed RR rows in chronological order, range-filtered, with a STABLE sort (beat times are a cumulative
        // sum, so the order of a second's beats shifts every later beat). The ROWS are kept because `ts` is the only
        // signal that a beat is missing (`cleanRRGapAware` takes only [Double]); the same predicate as
        // `HRVAnalyzer.rangeFilter` keeps the surviving values identical (pinned by RespRateGapAwareTests).
        let inBedRows = rr.filter { $0.ts >= start && $0.ts <= end }
            .sortedByTsStable()
            .filter { Double($0.rrMs) >= HRVAnalyzer.rrMinMs && Double($0.rrMs) <= HRVAnalyzer.rrMaxMs }

        // Beat-accuracy gate: RSA needs per-beat-accurate TIMING (each row's wall-clock gap ≈ its own R-R). A BANKED
        // stream (an Oura overnight IBI stamps a whole record of intervals on one coarse ring-time) fails it and the
        // estimate is not physiology; return NaN. Beat-accurate callers (WHOOP R-R, synthetic fixtures) pass
        // unchanged. Shares HRVAnalyzer's one definition of the judgement.
        //
        // Measured on two Oura nights (~31k beats each, fraction ≈ 0.024): the time AXIS is fine (sum(R-R) over wall
        // span 1.01–1.03) but the interval VALUES are not beat-to-beat (the ring splits each ~6.6 s record into ~6
        // intervals). The peak-picker returns its own floor, 13.33 bpm, and SHUFFLING or REVERSING the night's R-R
        // returns the same 13.3333: a plausible number with zero information, inside `respPlausibleRangeBpm`, so
        // the range clamp never sees it. Hence the gate is on banked-ness, not the output.
        //
        // Distinct from the splice skip below; both are needed since they catch opposite banking geometries: the
        // splice skip catches banking that TILES time (a ~7 s record boundary against a ~1.1 s interval), this
        // catches banking that COMPRESSES time (6 beats stamped in one second, so no gap exceeds
        // `rsaGapToleranceS`).
        if inBedRows.count >= 30 {
            let fraction = HRVAnalyzer.beatAccurateFraction(tsSec: inBedRows.map { $0.ts },
                                                            rrMs: inBedRows.map { Double($0.rrMs) })
            if !HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: fraction) { return nan }
        }

        let filtered = inBedRows.map { Double($0.rrMs) }
        if filtered.count < 30 { return nan }  // need enough beats for any RSA estimate

        // 2. Reconstruct beat times (seconds from session start) by cumulative sum. A dropout is where the WALL
        // CLOCK outran the beat (ts jumps 30-45 s while RR accounts for ~1 s); the sum would stitch the two sides into
        // a discontinuity the peak-picker reads as breathing. Record each splice's beat-time; step 5 drops windows
        // containing one. Beat times are NOT shifted by the gap. This also fires across a beat REJECTED by the range
        // test, so a night with heavy ectopic rejection loses windows it used to keep.
        var beatTimes = [Double](repeating: 0, count: filtered.count)
        var spliceAtS: [Double] = []
        var acc = 0.0
        for i in filtered.indices {
            if i > 0 {
                let wallStepS = Double(inBedRows[i].ts - inBedRows[i - 1].ts)
                if wallStepS - filtered[i] / 1000.0 > rsaGapToleranceS { spliceAtS.append(acc) }
            }
            acc += filtered[i] / 1000.0
            beatTimes[i] = acc
        }
        let totalSpanS = beatTimes[beatTimes.count - 1]
        if totalSpanS < rsaWindowS / 2.0 { return nan }  // < ~2.5 min of beats

        // 3. Resample onto a uniform grid by linear interpolation.
        let dt = 1.0 / rsaResampleHz
        let nGrid = Int(totalSpanS / dt) + 1
        if nGrid < 8 { return nan }
        var grid = [Double](repeating: 0, count: nGrid)
        var seg = 0
        for g in 0..<nGrid {
            let t = Double(g) * dt
            // Advance segment so beatTimes[seg] <= t <= beatTimes[seg+1].
            while seg < beatTimes.count - 2 && beatTimes[seg + 1] < t { seg += 1 }
            let t0 = beatTimes[seg]
            let t1 = beatTimes[seg + 1]
            let v0 = filtered[seg]
            let v1 = filtered[seg + 1]
            grid[g] = t1 <= t0 ? v0 : v0 + min(max((t - t0) / (t1 - t0), 0), 1) * (v1 - v0)
        }

        // 4. Detrend: subtract a centered moving mean (removes slow LF/baseline drift).
        let halfW = max(1, Int((rsaDetrendWindowS * rsaResampleHz / 2.0).rounded()))
        var detrended = [Double](repeating: 0, count: nGrid)
        for i in 0..<nGrid {
            let lo = max(0, i - halfW)
            let hi = min(nGrid - 1, i + halfW)
            var sum = 0.0
            for j in lo...hi { sum += grid[j] }
            detrended[i] = grid[i] - sum / Double(hi - lo + 1)
        }
        if standardDeviation(detrended) <= 1e-9 { return nan }  // flat → no RSA

        // 5. Per ~5-min window peak-pick → 60/median(breath interval); median across.
        let spliceGrid = spliceAtS.map { Int($0 / dt) }
        let minDistSamples = max(2, Int((rsaMinPeakDistanceS * rsaResampleHz).rounded()))
        let windowSamples = max(minDistSamples * 3, Int((rsaWindowS * rsaResampleHz).rounded()))
        var perWindowRates: [Double] = []
        var w = 0
        while w < nGrid {
            let wEnd = min(nGrid, w + windowSamples)
            // A window straddling a splice measures a discontinuity, not a breath. All windows spliced leaves
            // perWindowRates empty and the function returns NaN, the honest answer.
            let spliced = spliceGrid.contains { $0 >= w && $0 < wEnd }
            if !spliced && wEnd - w >= minDistSamples * 3 {
                let winSeg = Array(detrended[w..<wEnd])
                // height = 0.0 selects the positive RSA peaks (one per breath) on the zero-mean tachogram.
                let peaks = findPeaks(winSeg, distance: minDistSamples, height: 0.0)
                if peaks.count >= 3 {
                    var intervals: [Double] = []
                    for i in 1..<peaks.count {
                        let ivS = Double(peaks[i] - peaks[i - 1]) * dt
                        if ivS >= rsaMinBreathIntervalS && ivS <= rsaMaxBreathIntervalS {
                            intervals.append(ivS)
                        }
                    }
                    if intervals.count >= 2 {
                        let med = HRVAnalyzer.median(intervals)
                        if med > 0.0 { perWindowRates.append(60.0 / med) }
                    }
                }
            }
            w += windowSamples
        }
        if perWindowRates.isEmpty { return nan }
        // Reject estimates outside the canonical consumer band (NaN = no usable estimate) so the persisted value
        // never disagrees with the illness/readiness plausibility gate.
        let median = HRVAnalyzer.median(perWindowRates)
        return respPlausibleRangeBpm.contains(median) ? median : nan
    }

    // MARK: - Per-epoch features

    struct EpochFeatures {
        let index: Int
        let midTs: Double
        let count: Double      // rescaled Cole–Kripke activity count
        let moveFrac: Double
        let ckSleep: Bool
        let hr: Double         // mean HR over the feature window
        let hrVar: Double      // Walch DoG-HR windowed std
        let rmssd: Double      // ms
        let sdnn: Double       // ms
        let respRate: Double   // breaths/min
        let rrv: Double        // respiratory-rate variability (s)
        let clock: Double      // normalized time since onset, 0..1
    }

    static func extractFeatures(grid: EpochGrid, ckFlags: [Bool], dogHR: [Double],
                                onsetIdx: Int, finalWakeIdx: Int) -> [EpochFeatures] {
        let n = grid.nEpochs
        let rescaled = rescaleCounts(grid.counts)
        let halfW = Int((featureWindowS / epochS / 2).rounded())
        let span = Double(max(1, finalWakeIdx - onsetIdx))

        var feats: [EpochFeatures] = []
        feats.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)

            let winHR = (lo..<hi).map { grid.hr[$0] }.filter { !$0.isNaN }
            let hrMean = winHR.isEmpty ? Double.nan : winHR.reduce(0, +) / Double(winHR.count)

            let winDog = (lo..<hi).map { dogHR.isEmpty ? 0.0 : dogHR[$0] }
            let hrVar = winDog.count >= 2 ? standardDeviation(winDog) : Double.nan

            // RMSSD/SDNN over the pooled, range-filtered RR window.
            var winRR: [Double] = []
            for j in lo..<hi { winRR.append(contentsOf: grid.rr[j]) }
            let filteredRR = HRVAnalyzer.rangeFilter(winRR)
            let rmssd = filteredRR.count >= 5 ? (HRVAnalyzer.rmssdRaw(filteredRR) ?? Double.nan) : Double.nan
            let sdnn = filteredRR.count >= 5 ? (HRVAnalyzer.sdnnRaw(filteredRR) ?? Double.nan) : Double.nan

            var winResp: [Double] = []
            for j in lo..<hi { winResp.append(contentsOf: grid.resp[j]) }
            let (respRate, rrv) = respRateAndRRV(winResp)

            let clock = min(1.0, max(0.0, Double(i - onsetIdx) / span))

            feats.append(EpochFeatures(
                index: i, midTs: grid.epochMid(i), count: rescaled[i],
                moveFrac: grid.moveFrac[i],
                ckSleep: i < ckFlags.count ? ckFlags[i] : true,
                hr: hrMean, hrVar: hrVar, rmssd: rmssd, sdnn: sdnn,
                respRate: respRate, rrv: rrv, clock: clock))
        }
        return feats
    }

    // MARK: - Percentile helper

    /// numpy-style linear-interpolated percentile over finite values; nil if none.
    static func percentile(_ values: [Double], _ pct: Double) -> Double? {
        let vals = values.filter { $0.isFinite }.sorted()
        if vals.isEmpty { return nil }
        return StrainScorer.percentile(vals, pct)
    }

    // MARK: - Classifier seam (Stage 2)

    static func classifyEpochs(_ features: [EpochFeatures]) -> [String] {
        let n = features.count
        if n == 0 { return [] }

        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        let sleepFeats = features.contains { $0.ckSleep } ? features.filter { $0.ckSleep } : features
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        return features.map {
            classifyOne($0, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                        cardiacSparse: cardiacSparse)
        }
    }

    /// Session-level PPG-derived / sparse-cardiac tell: most sleep-period epochs carry NO finite per-epoch RMSSD.
    /// On those nights HR is PPG-derived and its windowed variance (`hrVar`) is noisier, so the percentile
    /// `hrvarHigh` bar fires on genuinely still, low-HR sleep, which the WAKE rule must not treat as cardiac
    /// activation. Aggregates the `!rmssd.isFinite` signal already trusted for the pro-deep RMSSD handling.
    static func isCardiacSparse(_ sleepFeats: [EpochFeatures]) -> Bool {
        if sleepFeats.isEmpty { return false }
        let sparse = sleepFeats.reduce(0) { $0 + (($1.rmssd.isFinite) ? 0 : 1) }
        return Double(sparse) >= cardiacSparseEpochFrac * Double(sleepFeats.count)
    }

    /// What this epoch's respiration says about depth, in FIVE states, because "we did not measure it" is not an
    /// observation and must not be spendable as one.
    ///
    /// The old pair of booleans read a MISSING RRV as positive evidence of regular breathing (pro-deep). On a
    /// WHOOP 5/MG that is the only code path (the v18 layout emits no `resp_rate_raw`, pinned by
    /// `Whoop5HistoricalTests`), so "regular" fired on 100% of epochs on no measurement, against ~50% with real
    /// data (the bar is the MEDIAN, `stageRRVLowPct` = 50). The five cases are the exact cross-product of the
    /// two replaced predicates (old `rrvIrregular` / `rrvRegular`):
    ///
    /// | old `rrvIrregular` | old `rrvRegular` | case |
    /// |---|---|---|
    /// | false | true (via `!isFinite`) | `unmeasured` |
    /// | false | true (via the low bar) | `regular` |
    /// | true | false | `irregular` |
    /// | false | false | `measuredMidBand` |
    /// | true | true | `barsDegenerate` |
    ///
    /// `unmeasured` and `measuredMidBand` stay DISTINCT: both fail both bars but mean opposite things, and the
    /// REM fallback fires only on a missing reading.
    enum RespEvidence {
        /// A finite RRV at or below the session's low bar: breathing measured as regular.
        case regular
        /// A finite RRV at or above the session's high bar: breathing measured as irregular.
        case irregular
        /// A finite RRV between the bars: measured, but neither notably regular nor irregular.
        case measuredMidBand
        /// No usable RRV for this epoch: the strap has no respiration channel (every 5/MG), or the window had too
        /// few / too flat samples (`respRateAndRRV` returns NaN below 8 samples, on a flat signal, under 3 peaks,
        /// or under 2 in-band breath intervals).
        case unmeasured
        /// A finite RRV that clears BOTH bars at once: at or above the high bar AND at or below the low bar. The
        /// session's two percentile bars have collapsed onto this reading, so the pair carries no information.
        ///
        /// Reachable for a structural reason: RRV is the std of breath intervals in WHOLE SECONDS, so it is quantised
        /// and ties are ordinary; `percentile` interpolates, so p50 and p65 coincide when the tie run spans them, and
        /// with only ONE finite-RRV sleep epoch `percentile` returns that value for both bars.
        ///
        /// Its own case because a four-state enum cannot represent it. Behaviour is preserved: waived for depth
        /// (`contradictsDepth`) and clearing the REM irregular bar (`meetsIrregularBar`). That resolves to DEEP only
        /// because the deep rule precedes the REM rule in `classifyOne`; re-deciding it is a scoring change on
        /// degenerate-distribution nights with no staged nights to validate against. Naming the case makes the
        /// decision a one-line edit with a test that fails loudly.
        case barsDegenerate

        /// Total mapping of the two replaced predicates, as an exhaustive switch on the pair rather than an ordered
        /// `if` chain (which is how `barsDegenerate` used to be decided by accident).
        static func of(_ rrv: Double, lowBar: Double?, highBar: Double?) -> RespEvidence {
            guard rrv.isFinite else { return .unmeasured }
            let atOrAboveHigh = highBar.map { rrv >= $0 } ?? false
            let atOrBelowLow = lowBar.map { rrv <= $0 } ?? false
            switch (atOrAboveHigh, atOrBelowLow) {
            case (true, true): return .barsDegenerate
            case (true, false): return .irregular
            case (false, true): return .regular
            case (false, false): return .measuredMidBand
            }
        }

        /// Whether respiration CONTRADICTS depth. The deep rule reads this rather than a "regular" flag, because
        /// `unmeasured` is the absence of evidence and the rule is "respiration must not rule depth out".
        ///
        /// `unmeasured` is WAIVED because blocking on it would decode 0 m of deep on every 5/MG night (as #127/#129
        /// fixed for missing RMSSD, whose rule carries the same "WHEN MEASURABLE" qualifier); `barsDegenerate` is
        /// waived too, preserving the old `rrvRegular`. Known limitation: on a 5/MG BOTH waivers can fire and the deep
        /// rule reduces to stillness + low HR, bounded because `hrLow` is a PERCENTILE bar (`stageHRLowPct` = 25).
        /// Narrowing it needs validation data this repo lacks; `SleepStagerRespEvidenceTests` pins and quantifies it.
        var contradictsDepth: Bool {
            switch self {
            case .regular, .unmeasured, .barsDegenerate: return false
            case .irregular, .measuredMidBand: return true
            }
        }

        /// Whether this epoch clears the session's IRREGULAR bar (the old `rrvIrregular`, read by the main REM
        /// rule). `barsDegenerate` clears it even though `contradictsDepth` also waives it; that pair of answers
        /// is the old both-true state, preserved deliberately.
        var meetsIrregularBar: Bool {
            switch self {
            case .irregular, .barsDegenerate: return true
            case .regular, .measuredMidBand, .unmeasured: return false
            }
        }
    }

    static func classifyOne(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                            rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                            cardiacSparse: Bool = false) -> String {
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!

        // HF is omitted (no neurokit2): parasympathetic tone = RMSSD only. A MISSING per-epoch RMSSD (sparse R-R,
        // common on offloaded and 5/MG nights) is treated as pro-deep rather than deep-blocking, like missing
        // respiration below, so those nights stop decoding 0 m of deep despite a real depth signature. An epoch
        // WITH a finite RMSSD must still clear the high-tone bar. (#127, #129)
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)

        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh

        // WAKE-specific cardiac vetting. On a PPG-derived / sparse-cardiac night hrVar is noisy and `hrvarHigh`
        // fires on still, low-HR sleep, so when sparse we down-weight hrVar for wake promotion and require a real
        // elevated HR (`hrHigh`). Dense 4.0 nights keep the full `hrHigh || hrvarHigh` signal. (#705)
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated

        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)

        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion).
        if moving && (cardiacActivatedForWake || !hasHR) { return "wake" }
        // DEEP: still + low HR + respiration that does not RULE OUT depth, with high parasympathetic tone when
        // measurable. `contradictsDepth` is where unmeasured respiration is waived.
        if still && parasympOK && hrLow && !resp.contradictsDepth { return "deep" }
        // REM: still body + activated cardiac + respiration clearing the irregular bar.
        if still && cardiacActivated && resp.meetsIrregularBar { return "rem" }
        // REM fallback when respiration was never MEASURED (not merely mid-band): require BOTH cardiac signals.
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return "rem" }
        return "light"
    }

    // MARK: - Post-processing (Stage 3)

    static func smoothLabels(_ labels: [String], window: Int = smoothEpochs) -> [String] {
        let n = labels.count
        if n == 0 || window <= 1 { return labels }
        var w = window
        if w % 2 == 0 { w += 1 }
        let half = w / 2
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for s in labels[lo..<hi] {
                if counts[s] == nil { order.append(s) }
                counts[s, default: 0] += 1
            }
            guard let best = counts.values.max() else { out.append(labels[i]); continue }
            let winners = order.filter { counts[$0] == best }  // insertion order preserved
            out.append(winners.contains(labels[i]) ? labels[i] : winners[0])
        }
        return out
    }

    static func reimposePhysiology(_ labels: [String], features: [EpochFeatures],
                                   onsetIdx: Int, finalWakeIdx: Int) -> [String] {
        var out = labels
        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        // "Deep is front-loaded" re-imposes scattered late "deep" to light, but only when there is deep in the
        // first third to anchor it. If the whole deep block lands later (individual variation, or HR/HRV-only
        // staging), zeroing it gives a wrong "0 m deep"; keep the best estimate. (#127)
        let hasEarlyDeep = zip(labels, features).contains { $0.0 == "deep" && $0.1.clock <= deepFirstFraction }
        for (i, f) in features.enumerated() {
            if i < onsetIdx || i > finalWakeIdx { continue }
            if out[i] == "rem" && (i - onsetIdx) < noREMEpochs { out[i] = "light" }
            if out[i] == "deep" && f.clock > deepFirstFraction && hasEarlyDeep { out[i] = "light" }
        }
        return out
    }

    // MARK: - REM-funnel diagnostic

    // 0% REM over a whole night is physiologically implausible (healthy adults ~20–25%), so it points at the
    // STAGER, not the sleeper. This pure, READ-ONLY diagnostic re-runs the REM funnel (still body + activated
    // cardiac + irregular respiration, with a no-resp fallback, then the no-REM-after-onset strip) and counts
    // where REM was lost, without changing a label or score. A triage surface logged by the caller.

    /// Why REM funneled toward zero for one staged window. Counts are over the SLEEP-PERIOD epochs
    /// (onset…finalWake); it shares the classifier seam with `stageSession`.
    public struct REMFunnelDiagnostic: Equatable, Sendable {
        /// Sleep-period epochs considered (onset…finalWake inclusive).
        public let sleepEpochs: Int
        /// Epochs the classifier labelled "rem" BEFORE smoothing / re-imposition.
        public let remAtClassify: Int
        /// "rem" epochs surviving the no-REM-after-onset re-imposition (the final hypnogram's REM).
        public let remAfterReimpose: Int
        /// Classified-REM epochs stripped specifically by the 15-min onset guard.
        public let remStrippedByOnsetGuard: Int
        /// Whether ANY epoch carried a finite respiration-variability feature. False means the whole night ran
        /// the no-resp REM fallback (the dominant 4.0 cause).
        public let respChannelPresent: Bool
        /// Among sleep-period epochs, how many were blocked from REM by each gate (counted at the FIRST gate that
        /// rejected it, in classifier precedence). These sum with `remAtClassify` (and any wake/deep wins) to the
        /// sleep-epoch total.
        public let blockedNotStill: Int          // body not still enough (moveFrac above the still bar)
        public let blockedNoCardiacActivation: Int  // neither HR-high nor HR-variability-high
        public let blockedRespRegular: Int       // resp present but NOT irregular (regular breathing)
        public let blockedNoRespFallbackBar: Int // resp absent and the stricter no-resp REM bar unmet
        /// Won a non-REM stage outright (wake/deep/light) before any REM gate.
        public let wonOtherStage: Int

        public init(sleepEpochs: Int, remAtClassify: Int, remAfterReimpose: Int,
                    remStrippedByOnsetGuard: Int, respChannelPresent: Bool,
                    blockedNotStill: Int, blockedNoCardiacActivation: Int,
                    blockedRespRegular: Int, blockedNoRespFallbackBar: Int, wonOtherStage: Int) {
            self.sleepEpochs = sleepEpochs; self.remAtClassify = remAtClassify
            self.remAfterReimpose = remAfterReimpose; self.remStrippedByOnsetGuard = remStrippedByOnsetGuard
            self.respChannelPresent = respChannelPresent
            self.blockedNotStill = blockedNotStill
            self.blockedNoCardiacActivation = blockedNoCardiacActivation
            self.blockedRespRegular = blockedRespRegular
            self.blockedNoRespFallbackBar = blockedNoRespFallbackBar
            self.wonOtherStage = wonOtherStage
        }

        /// True when the final hypnogram carries no REM at all (`remAfterReimpose == 0`).
        public var isZeroREM: Bool { remAfterReimpose == 0 }

        /// One human-readable line for the caller to LOG (no I/O here).
        public var summary: String {
            "REM-funnel: \(sleepEpochs) sleep-epochs, classify=\(remAtClassify) rem, "
            + "final=\(remAfterReimpose) rem (onset-guard stripped \(remStrippedByOnsetGuard)); "
            + "resp=\(respChannelPresent ? "present" : "ABSENT"); "
            + "blocked[notStill=\(blockedNotStill), noCardiac=\(blockedNoCardiacActivation), "
            + "respRegular=\(blockedRespRegular), noRespBar=\(blockedNoRespFallbackBar)], "
            + "otherStage=\(wonOtherStage)"
        }
    }

    /// Per-epoch reason REM was rejected, in classifier precedence order; `remEligible` means the epoch WOULD
    /// be labelled REM.
    enum REMRejectReason { case remEligible, wonOtherStage, notStill, noCardiacActivation, respRegular, noRespFallbackBar }

    /// Classify one epoch's REM-eligibility and, when not eligible, the FIRST reason it failed, using the exact
    /// predicates and precedence of `classifyOne` so the diagnostic cannot diverge from the classifier.
    static func remRejectReason(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                                rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                                cardiacSparse: Bool = false) -> REMRejectReason {
        // Mirror classifyOne's derived predicates exactly.
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)
        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated
        // Same respiration evidence and factory as the classifier, so the diagnostic cannot drift from the rule.
        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)
        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // classifyOne precedence: WAKE, DEEP, REM (then REM fallback), else LIGHT. Winning WAKE or DEEP means
        // the epoch was never a REM candidate.
        if moving && (cardiacActivatedForWake || !hasHR) { return .wonOtherStage }     // → wake
        if still && parasympOK && hrLow && !resp.contradictsDepth { return .wonOtherStage } // → deep
        // From here the epoch is either REM or falls through to LIGHT.
        if still && cardiacActivated && resp.meetsIrregularBar { return .remEligible }
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return .remEligible }
        // Not REM: attribute to the FIRST unmet REM precondition (in REM-rule order).
        if !still { return .notStill }
        if !cardiacActivated { return .noCardiacActivation }
        if resp != .unmeasured { return .respRegular }   // resp measured but not irregular
        return .noRespFallbackBar                          // resp never measured and the no-resp bar unmet
    }

    /// Read-only REM-funnel triage for ONE in-bed window [start, end]: re-runs this type's seam (epoch grid →
    /// Cole–Kripke → features → classify → smooth → re-impose) but COUNTS where REM was lost. Changes nothing.
    /// Returns nil when the window has too little gravity to grid.
    ///
    /// It explains V1's hypnogram only. The shipped one is staged by V2 by default and can differ widely: on a
    /// 5/MG V1's primary REM gate needs the raw respiratory channel the hardware never emits, while V2 recovers
    /// respiration from R-R (~46 min REM here against hours on screen, #2365). The caller's line names both.
    public static func remFunnelDiagnostic(start: Int, end: Int, grav: [GravitySample],
                                           hr: [HRSample], rr: [RRInterval],
                                           resp: [RespSample]) -> REMFunnelDiagnostic? {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return nil }
        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }
        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return nil }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)
        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        // The same session-relative reference percentiles classifyEpochs derives.
        let sleepFeats = feats.contains { $0.ckSleep } ? feats.filter { $0.ckSleep } : feats
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        // Classify + post-process exactly as stageSession does.
        let labels = classifyEpochs(feats)
        let smoothed = smoothLabels(labels)
        let reimposed = reimposePhysiology(smoothed, features: feats,
                                           onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        var sleepEpochs = 0, remAtClassify = 0, remAfterReimpose = 0, remStrippedByOnsetGuard = 0
        var blockedNotStill = 0, blockedNoCardiacActivation = 0, blockedRespRegular = 0
        var blockedNoRespFallbackBar = 0, wonOtherStage = 0
        var respChannelPresent = false

        for i in onsetIdx...max(onsetIdx, finalWakeIdx) where i < feats.count {
            let f = feats[i]
            sleepEpochs += 1
            if f.rrv.isFinite { respChannelPresent = true }
            // Per-epoch REM reason at the raw classifier seam (pre-smoothing).
            switch remRejectReason(f, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                                   hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                                   cardiacSparse: cardiacSparse) {
            case .remEligible:           remAtClassify += 1
            case .wonOtherStage:         wonOtherStage += 1
            case .notStill:              blockedNotStill += 1
            case .noCardiacActivation:   blockedNoCardiacActivation += 1
            case .respRegular:           blockedRespRegular += 1
            case .noRespFallbackBar:     blockedNoRespFallbackBar += 1
            }
            // Final-hypnogram REM (post smooth + re-impose) and the onset-guard strip.
            if reimposed[i] == "rem" { remAfterReimpose += 1 }
            // The re-imposition strips a SMOOTHED "rem" inside the onset guard to light; count it off the smoothed
            // labels reimpose actually sees.
            if smoothed[i] == "rem" && (i - onsetIdx) < noREMEpochs { remStrippedByOnsetGuard += 1 }
        }

        return REMFunnelDiagnostic(
            sleepEpochs: sleepEpochs, remAtClassify: remAtClassify, remAfterReimpose: remAfterReimpose,
            remStrippedByOnsetGuard: remStrippedByOnsetGuard, respChannelPresent: respChannelPresent,
            blockedNotStill: blockedNotStill, blockedNoCardiacActivation: blockedNoCardiacActivation,
            blockedRespRegular: blockedRespRegular, blockedNoRespFallbackBar: blockedNoRespFallbackBar,
            wonOtherStage: wonOtherStage)
    }

    /// Sleep-depth rank, lighter → deeper: wake 0, light 1, rem 2, deep 3. mergeFragments biases an ambiguous
    /// merge toward the LIGHTER stage so smoothing can never inflate deep/REM. Unknown labels rank 0.
    static func stageDepthRank(_ stage: String) -> Int {
        switch stage {
        case "light": return 1
        case "rem":   return 2
        case "deep":  return 3
        default:      return 0  // "wake" and any unexpected label
        }
    }

    /// Display/scoring smoothing of the staged label sequence (applied AFTER staging; never touches detection).
    /// A run shorter than fragmentMergeEpochs bridged by two SAME-stage neighbours is absorbed into them; between
    /// DIFFERENT stages it takes the longer neighbour, biased toward the LIGHTER one on a tie (or when the longer
    /// is deeper and the lighter comparable) so a fleck can never inflate deep/REM. Single left-to-right pass
    /// mirroring mergePeriods; a run ≥ threshold is a real transition and is preserved.
    static func mergeFragments(_ labels: [String], thresholdEpochs: Int = fragmentMergeEpochs) -> [String] {
        let n = labels.count
        if n == 0 || thresholdEpochs <= 1 { return labels }

        // Collapse the per-epoch labels into contiguous runs of (stage, length).
        var runs: [(stage: String, len: Int)] = []
        for s in labels {
            if let last = runs.last, last.stage == s { runs[runs.count - 1].len += 1 }
            else { runs.append((stage: s, len: 1)) }
        }
        if runs.count < 2 { return labels }

        var merged: [(stage: String, len: Int)] = []
        var i = 0
        while i < runs.count {
            let current = runs[i]
            if current.len >= thresholdEpochs { merged.append(current); i += 1; continue }

            let hasPrev = !merged.isEmpty
            let hasNext = i + 1 < runs.count

            if hasPrev && hasNext && merged[merged.count - 1].stage == runs[i + 1].stage {
                // Same-stage bridge: absorb the fleck and the next run into the previous one.
                merged[merged.count - 1].len += current.len + runs[i + 1].len
                i += 2
            } else if hasPrev && hasNext {
                // Between two DIFFERENT stages: relabel to the dominant neighbour, lighter on a length tie.
                let prev = merged[merged.count - 1]
                let next = runs[i + 1]
                let winner: String
                if prev.len > next.len { winner = prev.stage }
                else if next.len > prev.len { winner = next.stage }
                else {
                    // Tie → lighter (smaller depth rank) wins.
                    winner = stageDepthRank(prev.stage) <= stageDepthRank(next.stage) ? prev.stage : next.stage
                }
                // Fold the fleck into whichever neighbour it became; the OTHER stays its own run.
                if winner == prev.stage {
                    merged[merged.count - 1].len += current.len
                    i += 1
                } else {
                    // Becomes part of the NEXT run.
                    runs[i + 1] = (stage: next.stage, len: next.len + current.len)
                    i += 1
                }
            } else if hasNext {
                // Leading fleck: fold forward into the next run.
                runs[i + 1] = (stage: runs[i + 1].stage, len: runs[i + 1].len + current.len)
                i += 1
            } else if hasPrev {
                // Trailing fleck: fold back into the previous run.
                merged[merged.count - 1].len += current.len
                i += 1
            } else {
                // Single sub-threshold run with no neighbours: nothing to merge into.
                merged.append(current)
                i += 1
            }
        }

        // Re-expand the runs into a per-epoch label sequence of the same length.
        var out: [String] = []
        out.reserveCapacity(n)
        for r in merged { out.append(contentsOf: repeatElement(r.stage, count: r.len)) }
        return out
    }

    // MARK: - Per-session HR / HRV

    /// Conformance check for the artefact gate `sessionRestingHR` applies (bins are CLOSED at both ends:
    /// `[t, t + windowS)` except the final bin `[t, end]`). The shipped floor IS the gated floor, so comparing
    /// against it is silent by construction; this reports the UNGATED floor (min over every non-empty bin, the
    /// old rule) against it, firing only when the gate excluded the bin that would otherwise have won. Bins are
    /// built exactly as `sessionRestingHR` builds them. Counts and bpm only, no timestamps. Pure.
    public static func rhrBinGateLogLine(day: String, sessions: [(Int, Int)], hr: [HRSample],
                                         shippedFloor: Int, minBinSamples: Int = rhrMinBinSamples,
                                         minPlausibleBpm: Double = rhrMinPlausibleBpm) -> String? {
        let windowS = 5 * 60
        var bins = 0, thin = 0, implausible = 0, ungatedN = 0
        var ungated: Double?
        var gated: Double?
        for (start, end) in sessions {
            let seg = hr.filter { $0.ts >= start && $0.ts <= end }
            if seg.isEmpty { continue }
            var t = start
            repeat {
                let isFinal = t + windowS >= end
                let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + windowS) }
                if !win.isEmpty {
                    bins += 1
                    let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                    if win.count < minBinSamples { thin += 1 }
                    if mean < minPlausibleBpm { implausible += 1 }
                    if ungated == nil || mean < ungated! { ungated = mean; ungatedN = win.count }
                    if win.count >= minBinSamples, mean >= minPlausibleBpm,
                       gated == nil || mean < gated! { gated = mean }
                }
                t += windowS
            } while t < end
        }
        if bins == 0 { return nil }
        let ungatedFloor = ungated.map { Int($0.rounded()) }
        // Moved when the ungated floor differs from the shipped one, i.e. the gate excluded the bin that would
        // have won under the old rule.
        let moved = ungatedFloor != nil && ungatedFloor != shippedFloor
        if !moved { return nil }
        let gatedFloor = gated.map { Int($0.rounded()) }
        return "rhr bins day=\(day) bins=\(bins) thin=\(thin) implausible=\(implausible) "
            + "winnerN=\(ungatedN) ungated=\(ungatedFloor.map(String.init) ?? "nil") "
            + "gated=\(gatedFloor.map(String.init) ?? "nil") shipped=\(shippedFloor) gateMoved=\(moved)"
    }

    static func sessionRestingHR(start: Int, end: Int, hr: [HRSample]) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }
        let windowS = 5 * 60
        // A bin qualifies to WIN the floor only when well-populated (≥ rhrMinBinSamples) and physiologically
        // plausible (≥ rhrMinPlausibleBpm): a one-sample bin at a wear gap or a dropout dip must not become the
        // night's resting HR, which is stored on the daily row and feeds later nights' baseline. If no bin
        // qualifies, fall back to the lowest of ALL bin means, then the all-sample mean (never null on data).
        var gatedMeans: [Double] = []
        var allMeans: [Double] = []
        var t = start
        repeat {
            // The last bin (its half-open end reaches or passes `end`) closes on `end`, catching an endpoint sample the
            // prefilter admitted. `repeat` runs once for a zero-length window.
            let isFinal = t + windowS >= end
            let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + windowS) }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                allMeans.append(mean)
                if win.count >= rhrMinBinSamples && mean >= rhrMinPlausibleBpm { gatedMeans.append(mean) }
            }
            t += windowS
        } while t < end
        if let m = gatedMeans.min() { return Int(m.rounded()) }
        if let m = allMeans.min() { return Int(m.rounded()) }
        let all = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        return Int(all.rounded())
    }

    /// One 5-min HRV window: start ts, the sleep stage at its center, the clean-beat count, and the window RMSSD
    /// (nil when <2 clean beats). Drives `sessionAvgHRV` and the HRV test-mode trace.
    public struct HrvWindow: Sendable {
        public let startTs: Int
        public let stage: String
        public let cleanBeats: Int
        public let rmssd: Double?
    }

    /// Mean RMSSD over 5-min tumbling windows across the session (ms), or nil. A window counts only with
    /// `HRVAnalyzer.minBeats` clean intervals.
    ///
    /// Zoop: when `stages` is supplied, windows are weighted as WHOOP publicly describes its overnight HRV
    /// (see `weightedNightHRV`); without stages, or when no window carries weight, the plain mean is kept.
    static func sessionAvgHRV(start: Int, end: Int, rr: [RRInterval], stages: [StageSegment] = []) -> Double? {
        let windows = sessionHrvWindows(start: start, end: end, rr: rr, stages: stages)
        let vals = windows.compactMap { $0.rmssd }
        if vals.isEmpty { return nil }
        // Refuse the night outright when its own R-R banks more beat-time than the wall clock it spans. Gated HERE
        // because this is where RMSSD BECOMES the day's HRV: one seam covers the daily row, the session cache,
        // the Health card and the baseline, so none can disagree about whether the night was trustworthy. See
        // `HRVAnalyzer.successiveDiffIsTrustworthy`. Classified over the SAME beats and window as the value.
        guard !sessionHrvOverCounted(start: start, end: end, rr: rr) else { return nil }
        if !stages.isEmpty, let weighted = weightedNightHRV(windows, start: start, end: end) {
            return weighted
        }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Weight of a deep-stage (slow-wave) window relative to a light/REM window in `weightedNightHRV`.
    static let deepWindowWeight: Double = 2.0
    /// Extra weight a window gains across the night: 0 at session start, this much at its end.
    static let lateNightWeightGain: Double = 1.0

    /// Overnight RMSSD as a weighted mean of the 5-minute windows, after WHOOP's public description of its
    /// method: wake windows dropped, slow-wave and later windows weigh more. WHOOP does not publish its
    /// weights; `deepWindowWeight` and `lateNightWeightGain` are Zoop's choice. nil when no scored window
    /// carries weight.
    static func weightedNightHRV(_ windows: [HrvWindow], start: Int, end: Int) -> Double? {
        let span = Double(max(end - start, 1))
        var num = 0.0
        var den = 0.0
        for w in windows {
            guard let r = w.rmssd else { continue }
            let stageWeight: Double
            switch w.stage {
            case "wake", "awake": continue
            case "deep": stageWeight = deepWindowWeight
            default: stageWeight = 1.0
            }
            let center = Double(w.startTs - start) + 150.0
            let position = min(1.0, max(0.0, center / span))
            let weight = stageWeight * (1.0 + lateNightWeightGain * position)
            num += r * weight
            den += weight
        }
        return den > 0 ? num / den : nil
    }

    /// Whether the coverage gate refuses a session's HRV: its own R-R, windowed [start, end] as
    /// `sessionAvgHRV` windows it, banks more beat-time than the wall clock allows. The ONE definition of
    /// "refused": `sessionAvgHRV` gates on it and `AnalyticsEngine` asks it whether a night's missing HRV was
    /// refused rather than never measured.
    static func sessionHrvOverCounted(start: Int, end: Int, rr: [RRInterval]) -> Bool {
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        let segTs = seg.map { $0.ts }
        let segMs = seg.map { Double($0.rrMs) }
        let coverage = HRVAnalyzer.rrCoverage(tsSec: segTs, rrMs: segMs)
        // `collapsed` is deliberately the SAME figure as `coverage`: it only chooses BETWEEN the two over-count
        // verdicts, this gate refuses both, and `collapsedCoverage` opens with a full sort of ~50-70k beats. This
        // runs per session per day across ~21 days every 15 minutes, so that distinction is not worth the cost.
        let verdict = HRVAnalyzer.classifyCoverage(coverage: coverage, collapsed: coverage)
        return !HRVAnalyzer.successiveDiffIsTrustworthy(verdict)
    }

    /// Per-5-min-window RMSSD across a session, each tagged with the sleep stage at its CENTER (from `stages`;
    /// `[]` tags every window "?"): the single source `sessionAvgHRV` averages and the HRV trace reads. Windows
    /// follow `sessionRestingHR`'s closed-window rule (final window `[t, end]`, keeping its half-open center
    /// for stage tagging).
    static func sessionHrvWindows(start: Int, end: Int, rr: [RRInterval], stages: [StageSegment]) -> [HrvWindow] {
        // CONTRACT: `rr` MUST already be ts-sorted (RMSSD uses SUCCESSIVE differences). Not sorted here on
        // purpose: re-sorting could reorder same-second RR under Swift's unstable sort and shift the shipped avgHrv.
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return [] }
        let windowS = 5 * 60
        var out: [HrvWindow] = []
        var t = start
        // One advancing index instead of re-filtering `seg` per window: sorted input makes each window's beats a
        // CONTIGUOUS run. The rescan this replaced was O(windows x beats) (~96 windows, tens of thousands of R-R,
        // five times per session per day over three weeks). An oracle over 480 nights (dense, sparse, duplicate
        // timestamps, tail-loaded, boundary, empty) found the output identical.
        var i = seg.startIndex
        repeat {
            // Final window closes on `end` (same closed-window rule as sessionRestingHR); `repeat` runs once for a
            // zero-length window.
            let isFinal = t + windowS >= end
            // Defensive on the first window only; later windows resume exactly where the previous stopped.
            while i < seg.endIndex && seg[i].ts < t { i += 1 }
            var j = i
            if isFinal {
                // The final window takes every remaining beat.
                j = seg.endIndex
            } else {
                let upper = t + windowS
                while j < seg.endIndex && seg[j].ts < upper { j += 1 }
            }
            let bucket = seg[i..<j].map { Double($0.rrMs) }
            if !isFinal { i = j }
            // Full clean (range + Malik ectopic rejection), as analyze() does: the 0x2A37 RR on a WHOOP 5/MG is
            // PPG-derived and noisier, and rMSSD from SUCCESSIVE differences is inflated by un-rejected jitter. Gap-aware:
            // a difference straddling a dropped beat is skipped so neighbours aren't spliced into a spurious delta.
            let cleaned = HRVAnalyzer.cleanRRGapAware(bucket)
            // The same `minBeats` floor the spot reading and SDNN index apply, so a window left with a handful of
            // clean beats doesn't weigh as much as a full five minutes in the plain mean.
            let rmssd: Double? = (cleaned.nn.count >= HRVAnalyzer.minBeats)
                ? HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) : nil
            let center = t + windowS / 2
            let stage = stages.first { center >= $0.start && center < $0.end }?.stage ?? "?"
            out.append(HrvWindow(startTs: t, stage: stage, cleanBeats: cleaned.nn.count, rmssd: rmssd))
            t += windowS
        } while t < end
        return out
    }

    /// The LAST contiguous run of deep-stage windows in `windows` (the WHOOP-style "last slow-wave-sleep"
    /// comparator for the HRV nightly trace). Empty when no deep window is present.
    static func lastDeepRun(_ windows: [HrvWindow]) -> [HrvWindow] {
        var lastRun: [HrvWindow] = []
        var cur: [HrvWindow] = []
        for w in windows {
            if w.stage == "deep" { cur.append(w) } else if !cur.isEmpty { lastRun = cur; cur.removeAll() }
        }
        if !cur.isEmpty { lastRun = cur }
        return lastRun
    }

    // MARK: - AASM hypnogram metrics

    /// AASM-style metrics from a session's stage segments.
    public struct HypnogramMetrics: Equatable, Sendable {
        public let tibS: Double
        public let tstS: Double
        public let sptS: Double
        public let solS: Double
        public let remLatencyS: Double  // NaN if no REM
        public let wasoS: Double
        public let efficiency: Double
        public let disturbances: Int
        public let deepMin: Double
        public let remMin: Double
        public let lightMin: Double
        public let deepPct: Double
        public let remPct: Double
        public let lightPct: Double
    }

    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let tib = max(0.0, Double(session.end - session.start))

        func dur(_ s: StageSegment) -> Double { Double(s.end - s.start) }
        let sleepSegs = segs.filter { $0.stage == "light" || $0.stage == "deep" || $0.stage == "rem" }
        let tst = sleepSegs.reduce(0.0) { $0 + dur($1) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + dur($1) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + dur($1) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + dur($1) }

        let onset: Double, sptEnd: Double, sol: Double
        if let first = sleepSegs.first, let last = sleepSegs.last {
            onset = Double(first.start)
            sptEnd = Double(last.end)
            sol = max(0.0, onset - Double(session.start))
        } else {
            onset = Double(session.end)
            sptEnd = Double(session.end)
            sol = tib
        }

        let remSegs = segs.filter { $0.stage == "rem" }
        let remLatency = remSegs.first.map { Double($0.start) - onset } ?? Double.nan

        var waso = 0.0
        var disturbances = 0
        for s in segs where SleepStageVocabulary.isWake(s.stage) {
            let w0 = max(Double(s.start), onset)
            let w1 = min(Double(s.end), sptEnd)
            if w1 > w0 { waso += (w1 - w0); disturbances += 1 }
        }

        let se = tib > 0 ? tst / tib : 0.0
        func pct(_ x: Double) -> Double { tst > 0 ? x / tst * 100.0 : 0.0 }

        return HypnogramMetrics(
            tibS: tib, tstS: tst, sptS: max(0.0, sptEnd - onset), solS: sol,
            remLatencyS: remLatency, wasoS: waso, efficiency: min(1.0, se),
            disturbances: disturbances, deepMin: deepS / 60.0, remMin: remS / 60.0,
            lightMin: lightS / 60.0, deepPct: pct(deepS), remPct: pct(remS), lightPct: pct(lightS))
    }

    // MARK: - Small stats helpers

    /// Population standard deviation (numpy default, ddof=0).
    static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return (ss / Double(values.count)).squareRoot()
    }
}
