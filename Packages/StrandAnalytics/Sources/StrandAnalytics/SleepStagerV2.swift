import Foundation
import WhoopProtocol

// SleepStagerV2.swift — the DEFAULT sleep-staging recipe (the older percentile-band `SleepStager` V1
// stays available behind the PuffinExperiment flag). Chosen after a 44-subject leave-one-subject-out
// benchmark (AAUWSS + Walch sleep-accel): kappa 0.35 vs 0.03, deep recall 55% vs 1%.
//
// Re-stages only a window already decided to be sleep (session DETECTION still comes from V1), so it is a
// drop-in for `SleepStager.stageSession(start:end:grav:hr:rr:resp:)`: same signature, same `[StageSegment]`.
//
// Stages are APPROXIMATIONS, not PSG-validated, not medical advice. All coefficients are fixed a-priori
// from sleep physiology and population base rates, not fit to labels. Each 30 s epoch is staged from:
//   1. per-night z-scored cardiorespiratory emissions (HR / HR-variability / movement);
//   2. a per-night DEEP gate on the 11-min HR-flatness percentile (the strongest deep-vs-light separator);
//   3. a soft sleep-cycle prior (deep concentrated early; REM rising through the night, minus a
//      REM-latency guard decaying over the first 60 MINUTES after sleep onset);
//   4. a peak-motion (jerk) wake gate relative to the night's own quiescent jerk floor, so it
//      self-calibrates to the strap's gravity-decode scale and the wearer's fit;
//   5. an RR-RSA respiration-regularity term (regular breathing → deep, irregular → REM);
//   6. Viterbi/HMM transition smoothing with a sticky transition matrix.

public enum SleepStagerV2 {

    /// Build a 30 s hypnogram for `[start, end]` and return `StageSegment`s tiling the span. Drop-in for
    /// `SleepStager.stageSession`. `resp` is accepted for signature parity but not consumed: respiration
    /// regularity is recovered from the R-R stream (RSA), available on both WHOOP 4 and 5.
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        // Stage each night at most once per (window, input-fingerprint): the post-sync scoring loop and the
        // self-heal restage pass byte-identical streams, and each call would otherwise re-allocate large
        // per-second dictionaries. The key folds in start/end and a fingerprint of grav/hr/rr (resp is not
        // consumed, so it stays out of the key). Only the small `[StageSegment]` is cached, and the cache is
        // bounded.
        //
        // CLIP: callers pass the WHOLE multi-day stream to every per-night call, but `features()` never reads a
        // sample outside [start-padLo, end+padHi]. Cold passes (~21 nights, or up to 4000 on a full Effort
        // rescore) would otherwise blow the per-second dictionaries and sorts up to OOM. Establish timestamp
        // order, then slice each stream to the read window BEFORE fingerprinting and staging; output-identical
        // for sorted callers.
        let stableOrder: (Int, (Int) -> Int) -> [Int]? = { count, tsAt in
            if count < 2 { return nil }
            var hasInversion = false
            for i in 1..<count where tsAt(i - 1) > tsAt(i) {
                hasInversion = true
                break
            }
            if !hasInversion { return nil }
            return (0..<count).sorted { lhs, rhs in
                let lts = tsAt(lhs), rts = tsAt(rhs)
                return lts == rts ? lhs < rhs : lts < rts
            }
        }
        let gravO = stableOrder(grav.count, { grav[$0].ts }).map { $0.map { grav[$0] } } ?? grav
        let hrO = stableOrder(hr.count, { hr[$0].ts }).map { $0.map { hr[$0] } } ?? hr
        let rrO = stableOrder(rr.count, { rr[$0].ts }).map { $0.map { rr[$0] } } ?? rr
        let gravW = clipToWindow(gravO,
                                 lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let hrW = clipToWindow(hrO,
                               lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let rrW = clipToWindow(rrO,
                               lo: start - Self.padLo, hi: end + Self.padHi, ts: { $0.ts })
        let key = V2Key(
            start: start, end: end,
            grav: StreamFingerprint.of(gravW, ts: { $0.ts }, quant: {
                StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
            }),
            hr: StreamFingerprint.of(hrW, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rrW, ts: { $0.ts }, quant: { Int($0.rrMs) }))
        return stageCache.value(key) {
            stageSessionUncached(start: start, end: end, grav: gravW, hr: hrW, rr: rrW, resp: resp)
        }
    }

    /// Farthest seconds, relative to an epoch, that `features()` reads any input. The 11-min HR-flatness
    /// window dominates both directions (`[e-330, e+390)`); the 5-min window and the RSA beat window
    /// (`[e-90, e+120)`) lie inside it, so nothing reads before `start - padLo` or at/after `end + padHi`.
    static let padLo = 330   // backward reach: 11-min window's `e - 330`
    static let padHi = 390   // forward reach: 11-min window's `e + 30 + 360`

    /// Slice a ts-sorted stream to `[lo, hi)` (O(log n) bounds plus one copy). Loss-free for the recipe.
    private static func clipToWindow<T>(_ samples: [T], lo: Int, hi: Int, ts: (T) -> Int) -> [T] {
        if samples.isEmpty { return samples }
        // Already inside the window in full: avoid the copy.
        if ts(samples[0]) >= lo && ts(samples[samples.count - 1]) < hi { return samples }
        var l = 0, h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < lo { l = m + 1 } else { h = m } }
        let start = l
        l = start; h = samples.count
        while l < h { let m = (l + h) / 2; if ts(samples[m]) < hi { l = m + 1 } else { h = m } }
        if start == 0 && l == samples.count { return samples }
        return Array(samples[start..<l])
    }

    /// Cache key = locked window + fingerprints of the inputs the recipe reads.
    private struct V2Key: Hashable {
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint; let rr: StreamFingerprint
    }

    /// About two weeks of distinct nights (incl. re-staged edits); FIFO-evicted, result-only.
    private static let stageCache = AnalyticsMemoCache<V2Key, [StageSegment]>(capacity: 24)

    /// The staging recipe behind the memoizing public entry; a cache miss runs exactly this.
    private static func stageSessionUncached(start: Int, end: Int, grav: [GravitySample],
                                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        let feats = features(start: start, end: end, grav: grav, hr: hr, rr: rr)
        if feats.isEmpty { return [StageSegment(start: start, end: end, stage: "light")] }
        let labels = stageEpochs(feats)

        // Tile [start, end] with one segment per staged epoch: the first back-fills [start, firstEpoch), the last
        // extends to `end`, and an interior gap is carried by the preceding label. "awake" is renamed to the
        // canonical "wake".
        var segments: [StageSegment] = []
        for (i, f) in feats.enumerated() {
            let stage = labels[i] == "awake" ? "wake" : labels[i]
            let segStart = i == 0 ? start : f.start
            let segEnd = i == feats.count - 1 ? end : feats[i + 1].start
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        return segments
    }

    // MARK: - Recipe constants (fixed a-priori, not fit to labels)

    static let stageNames = ["deep", "rem", "light", "awake"]

    /// Population sleep-architecture base rates as log-priors (adult TST ≈ light 50 / rem 22 / waso 10 %,
    /// deep 15). Calibrates the boundary so light wins weak-evidence epochs.
    ///
    /// Deep is 0.15 (was 0.18, which over-called deep by +5.2 pp pooled against PSG: PhysioNet sleep-accel,
    /// n = 31, `Tools/SleepPSG`). 0.15 is #348's value, not a fit to this cohort; alone it raises
    /// per-subject kappa for 21 of 31 subjects and moves no wake or REM epoch. #348's awake 0.10 → 0.34 is
    /// deliberately not taken: it worsens mean per-subject wake error (the #437 shape).
    static let baseLogPrior: [String: Double] = [
        "light": log(0.50), "deep": log(0.15), "rem": log(0.22), "awake": log(0.10)]

    /// Deep is eligible only in the night's lowest ~25 % HR-flatness epochs (≈ deep base rate + margin),
    /// widened from 0.20 by the multi-subject LOSO deep-boundary tune.
    static let deepGateThresh = 0.25
    static let deepGateSlope = 5.0

    /// Motion thresholds are RELATIVE to each night's own quiescent jerk floor (median per-second
    /// gravity-jerk over the session), not an absolute g, so they self-calibrate to the strap's decode scale
    /// and the wearer's fit.
    static let jerkFloorMoveMult = 38.0  // a per-second jerk counts as "moving" above floor × this
    static let jerkFloorGateMult = 55.0  // wake-boost when an epoch's peak jerk exceeds floor × this
    static let motionGateBoost = 2.0

    /// An epoch is MOTION-QUIESCENT when it shows no observed movement (`moveFrac == 0`) AND its peak
    /// per-second jerk is at/below the night's quiescent floor × `jerkFloorGateMult`. On such epochs the
    /// AWAKE emission keeps wake-SUPPRESSING cardiac evidence (low, flat HR) but drops the wake-PROMOTING
    /// half: a raised HR with a motionless wrist is a supplement / fever / hot-room / alcohol artefact, not
    /// wakefulness. Genuinely still low-HR sleep is unchanged; epochs that actually moved still drive wake
    /// via `zmvv` and the jerk gate.
    static func motionQuiescent(_ f: Epoch) -> Bool {
        f.moveFrac <= 0.0 && f.jerkMax <= f.jerkScale * jerkFloorGateMult
    }

    /// Weight of the RSA respiration-regularity term (regular → deep, irregular → REM).
    static let respWeight = 0.6

    /// Transition matrix (rows = from, cols = to). Self-transitions dominate; deep↔rem rare; wake mostly
    /// to/from light. A priori, not fit.
    ///
    /// The AWAKE row encodes sleep-onset physiology: descent runs through N1/N2, so wake→deep and wake→rem
    /// are ZERO and the freed mass goes to the wake self-loop (a WASO episode spans several epochs instead
    /// of flickering back to sleep). This is the one part of PR #348's DREAMT re-tune that survived
    /// measurement on a de-contaminated reference; the rest was reverted by #437. Zero is a strong prior,
    /// not a prohibition: the viterbi floor turns it into ≈ -20.7 against wake→light's ≈ -2.3, which a
    /// strong enough emission can still cross, so a sleep-onset REM period stays representable.
    ///
    /// Measured against the strap's own band `sleep_state` (21 nights, 15 554 epochs, one wearer): sleep/wake
    /// kappa 0.105 → 0.118, wake sensitivity 16.0 % → 17.6 %, healthy-stratum wake fraction essentially
    /// unmoved. Against PSG (sleep-accel, 31 subjects, #991): 4-class kappa 0.356 → 0.363, REM F1
    /// 0.569 → 0.575. See `Tools/SleepBench`.
    static let transition: [String: [String: Double]] = [
        "deep":  ["deep": 0.86, "rem": 0.007, "light": 0.126, "awake": 0.007],
        "rem":   ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
        "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
        "awake": ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90]]

    /// One 30 s epoch's recipe features. Optionals are "no measurement"; z-score / percentile treat a missing
    /// value as the neutral centre so a sparse channel never blocks a stage.
    struct Epoch {
        let start: Int          // epoch start (unix seconds, multiple of 30)
        let hr: Double?         // epoch-mean HR (bpm)
        let hrVar: Double?      // std of per-second HR over a centred 5-min window
        let hrFlat11: Double?   // std of per-second HR over a centred 11-min window (deep/light separator)
        let moveFrac: Double    // fraction of in-epoch per-second jerks above the night-relative move threshold
        let jerkMax: Double     // peak in-epoch per-second jerk (g) — wake is bursty
        let respReg: Double?    // RSA spectral peakedness in the 0.15–0.40 Hz band (breathing regularity)
        let clock: Double       // time-of-night fraction in [0, 1]
        let jerkScale: Double   // night quiescent jerk floor (median per-second jerk over the session)
        /// Elapsed MINUTES from the session window start to this epoch's centre. `features()` cannot know where
        /// sleep began, so `stageEpochs` re-bases this onto the onset its first pass found (falling back to the
        /// window start when sleep is never sustained). Only the REM-latency guard reads it; the deep term and
        /// REM ramp stay fractions of the session (see `cyclePrior`).
        let minutesSinceOnset: Double
    }


    /// Build the per-epoch recipe features over a 30 s wall-clock-aligned grid covering [start, end]. Streams
    /// are already clipped by `stageSession` to `[start-padLo, end+padHi]`, a superset of every read window.
    static func features(start: Int, end: Int, grav: [GravitySample],
                         hr: [HRSample], rr: [RRInterval]) -> [Epoch] {
        if end <= start { return [] }
        let span = Double(max(1, end - start))

        // Per-second aggregation (mean when a second carries several samples).
        var hrSum = [Int: Double](), hrCnt = [Int: Int]()
        for s in hr { hrSum[s.ts, default: 0] += Double(s.bpm); hrCnt[s.ts, default: 0] += 1 }
        var secHR = [Int: Double](); secHR.reserveCapacity(hrSum.count)
        for (k, v) in hrSum { secHR[k] = v / Double(hrCnt[k]!) }

        var gxSum = [Int: Double](), gySum = [Int: Double](), gzSum = [Int: Double](), gCnt = [Int: Int]()
        for g in grav {
            gxSum[g.ts, default: 0] += g.x; gySum[g.ts, default: 0] += g.y
            gzSum[g.ts, default: 0] += g.z; gCnt[g.ts, default: 0] += 1
        }
        var secG = [Int: (Double, Double, Double)](); secG.reserveCapacity(gCnt.count)
        for (k, c) in gCnt { let d = Double(c); secG[k] = (gxSum[k]! / d, gySum[k]! / d, gzSum[k]! / d) }

        // R-R values bucketed by second (for the RSA respiration window).
        var rrBy = [Int: [Double]]()
        for r in rr { rrBy[r.ts, default: []].append(Double(r.rrMs)) }

        // Prefix sums over the per-second HR grid: every epoch evaluates a 5-min and an 11-min centred std
        // window, and rescanning ~660 entries per window per epoch dominated cold-stage allocation. Dense
        // prefix arrays of (count, Σv, Σv²) make each window an O(1) range query. The std stays population
        // (÷n) with `<2 present → nil`; the algebraic expansion differs from a direct sum only in the last
        // ULPs (verified label-identical on the golden nights). A window past the grid sees fewer present seconds.
        let gridLo = secHR.keys.min()
        let gridHi = secHR.keys.max()
        var pCnt = [Int](), pSum = [Double](), pSq = [Double]()
        if let g0 = gridLo, let g1 = gridHi {
            let n = g1 - g0 + 1
            pCnt = [Int](repeating: 0, count: n + 1)
            pSum = [Double](repeating: 0, count: n + 1)
            pSq = [Double](repeating: 0, count: n + 1)
            for i in 0..<n {
                let v = secHR[g0 + i]
                pCnt[i + 1] = pCnt[i] + (v == nil ? 0 : 1)
                pSum[i + 1] = pSum[i] + (v ?? 0)
                pSq[i + 1] = pSq[i] + (v.map { $0 * $0 } ?? 0)
            }
        }
        // Population std over the PRESENT per-second HR in `[lo, hi)`; nil when < 2 present samples.
        func stdOfSeconds(_ lo: Int, _ hi: Int) -> Double? {
            guard let g0 = gridLo, let g1 = gridHi else { return nil }
            let a = max(lo, g0) - g0
            let b = min(hi, g1 + 1) - g0
            if b <= a { return nil }
            let cnt = pCnt[b] - pCnt[a]
            if cnt < 2 { return nil }
            let n = Double(cnt)
            let sv = pSum[b] - pSum[a]
            let sq = pSq[b] - pSq[a]
            let m = sv / n
            let v = (sq - 2 * m * sv + n * m * m) / n
            return (v < 0 ? 0 : v).squareRoot()
        }

        // PASS 1: every per-epoch quantity EXCEPT the move fraction, pooling every per-second jerk so the night's
        // quiescent jerk floor (its median) can scale the motion thresholds. moveFrac needs that floor, so two passes.
        struct Raw {
            let start: Int; let hr: Double?; let hrVar: Double?; let hrFlat11: Double?
            let jerks: [Double]; let gapSec: Int; let jerkMax: Double; let respReg: Double?; let clock: Double
            let minutes: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        // The RSA transform's twiddle factors per grid length, for this night only (see `RespDFT`).
        var respDFT: [Int: RespDFT] = [:]
        let firstE = ((start + 29) / 30) * 30
        var e = firstE
        while e < end {
            var hrs: [Double] = []
            var gseq: [(Double, Double, Double)] = []
            for s in e..<(e + 30) {
                if let h = secHR[s] { hrs.append(h) }
                if let g = secG[s] { gseq.append(g) }
            }
            if hrs.isEmpty && gseq.isEmpty { e += 30; continue }   // no coverage → skip the epoch

            // Movement: consecutive per-second gravity jerks within the epoch.
            var jerks: [Double] = []
            for i in 1..<max(1, gseq.count) {
                let a = gseq[i - 1], b = gseq[i]
                let dx = a.0 - b.0, dy = a.1 - b.1, dz = a.2 - b.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
            allJerks.append(contentsOf: jerks)
            let jerkMax = jerks.max() ?? 0.0

            let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let hrVar = stdOfSeconds(e - 150, e + 30 + 150)     // 5-min centred window
            let hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360)  // 11-min centred window

            // RSA respiration over a wider beat window [e-90, e+120).
            var beats: [(Double, Double)] = []
            for s in (e - 90)..<(e + 120) {
                if let vs = rrBy[s] { for v in vs { beats.append((Double(s), min(max(v, 300), 2000))) } }
            }
            beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let respReg = respRegularity(beats, dft: &respDFT)

            raws.append(Raw(start: e, hr: hrMean, hrVar: hrVar, hrFlat11: hrFlat11,
                            jerks: jerks, gapSec: max(1, gseq.count - 1), jerkMax: jerkMax,
                            respReg: respReg, clock: Double(e + 15 - start) / span,
                            minutes: Double(e + 15 - start) / 60.0))
            e += 30
        }

        // Night quiescent jerk floor = median of all per-second jerks (most sleep seconds are still). Tiny
        // epsilon with no motion data so the move threshold collapses to ~0 rather than dividing by nothing.
        let jerkScale: Double = {
            if allJerks.isEmpty { return 1e-6 }
            let s = allJerks.sorted(); let n = s.count
            return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }()
        let moveThr = jerkScale * jerkFloorMoveMult

        // PASS 2: move fraction against the night-relative threshold; the floor rides on each epoch for the
        // wake gate in stageEpochs().
        var feats: [Epoch] = []
        feats.reserveCapacity(raws.count)
        for r in raws {
            let moves = r.jerks.reduce(0) { $0 + ($1 > moveThr ? 1 : 0) }
            feats.append(Epoch(
                start: r.start, hr: r.hr, hrVar: r.hrVar, hrFlat11: r.hrFlat11,
                moveFrac: Double(moves) / Double(r.gapSec), jerkMax: r.jerkMax, respReg: r.respReg,
                clock: r.clock, jerkScale: jerkScale, minutesSinceOnset: r.minutes))
        }
        return feats
    }

    /// The band-limited DFT's twiddle factors for one 4 Hz grid length `n`: `cos`/`sin` of `-2π·k/n · j` for
    /// every in-band bin `k` and sample `j`.
    ///
    /// `respRegularity` runs once per epoch and used to recompute these ~53 × ~836 pairs each time (13 % of
    /// a cold re-score's CPU). They depend on `n` alone and a night sees few distinct `n`; the table uses the
    /// transform's own expressions, so reading it back is bit-identical.
    struct RespDFT {
        let kLo: Int
        let cosines: [[Double]]
        let sines: [[Double]]

        init(n: Int, kLo: Int, kHi: Int) {
            self.kLo = kLo
            var cosines: [[Double]] = []
            var sines: [[Double]] = []
            for k in kLo...kHi {
                let w = -2.0 * Double.pi * Double(k) / Double(n)
                var c = [Double](repeating: 0, count: n)
                var s = [Double](repeating: 0, count: n)
                for j in 0..<n { let a = w * Double(j); c[j] = cos(a); s[j] = sin(a) }
                cosines.append(c)
                sines.append(s)
            }
            self.cosines = cosines
            self.sines = sines
        }
    }

    /// RSA respiration regularity: tachogram → 4 Hz resample → detrend → power spectrum → peak/sum of the
    /// 0.15–0.40 Hz (9–24 brpm) band. Returns spectral peakedness (higher = more regular breathing), or nil
    /// with too few beats. A direct band-limited DFT (~50 in-band bins); `dft` caches twiddle factors per
    /// grid length.
    static func respRegularity(_ beats: [(Double, Double)], dft: inout [Int: RespDFT]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))   // np.arange(t0, tN, 0.25) length
        if n < 16 { return nil }

        // Linear resample onto the uniform 4 Hz grid (clamped within [t0, tN]).
        var y = [Double](repeating: 0, count: n)
        var seg = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while seg < beats.count - 2 && beats[seg + 1].0 < t { seg += 1 }
            let ta = beats[seg].0, tb = beats[seg + 1].0
            let va = beats[seg].1, vb = beats[seg + 1].1
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        // Band bins: f[k] = k / (n·0.25); keep 0.15 ≤ f ≤ 0.40.
        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        if kHi < kLo || kLo < 0 { return nil }
        let table: RespDFT
        if let cached = dft[n] {
            table = cached
        } else {
            table = RespDFT(n: n, kLo: kLo, kHi: kHi)
            dft[n] = table
        }
        var maxP = 0.0, sumP = 0.0
        for k in kLo...kHi {
            var re = 0.0, im = 0.0
            let c = table.cosines[k - kLo], s = table.sines[k - kLo]
            for j in 0..<n { re += y[j] * c[j]; im += y[j] * s[j] }
            let p = re * re + im * im
            sumP += p
            if p > maxP { maxP = p }
        }
        if sumP == 0 { return nil }
        return maxP / sumP
    }

    // MARK: - Recipe staging


    /// Log-odds penalty on the REM emission AT sleep onset: e⁻³ ≈ 0.05, strong suppression that sufficient
    /// evidence still overcomes, never a veto. Kept at the incumbent magnitude because the sleep-accel grid
    /// (210 cells) tied on accuracy everywhere, so no measurement can justify retuning it.
    static let remLatencyPenalty = 3.0

    /// Minutes over which `remLatencyPenalty` decays linearly to zero, from sleep ONSET. Against PSG truth
    /// (sleep-accel, n = 31) a 45-min guard costs 0.36 % of real REM and a 90-min guard 6.85 %; 60 min sits
    /// between, and the graded decay is already ≤ 0.75 log-odds across 45–60 min, so a late sleep-onset REM
    /// period is held back rather than suppressed. 60 min also ends before the ~70–100 min population
    /// first-REM latency.
    static let remLatencyMinutes = 60.0

    /// The guard: `K` at (and before) sleep onset, decaying linearly to 0 at `M0` minutes after it. Clamped to
    /// `[0, K]` so a pre-onset epoch (negative elapsed time, unbounded when detection places the window
    /// start hours early, #271) is never penalised harder than the onset instant.
    static func remLatencyGuard(_ minutesSinceOnset: Double) -> Double {
        remLatencyPenalty * min(1.0, max(0.0, 1.0 - minutesSinceOnset / remLatencyMinutes))
    }

    /// Soft sleep-cycle prior added to the log-emission: deep concentrated early (decays, never hard-wiped);
    /// REM suppressed around sleep onset (REM latency) then rising toward morning.
    ///
    /// `1.2`, `0.55` and the `1.0` REM slope are hand-picked a priori, never fit to labels.
    ///
    /// Units differ per term. The deep term and the `1.0 * c` REM ramp take `c`, the fraction of the session
    /// (where in the night you are). The REM-latency guard takes `minutesSinceOnset` because first-REM
    /// latency is an absolute interval: on sleep-accel (n = 30) it is uncorrelated with session duration
    /// (Pearson r = −0.058) and more variable as a fraction (CV 0.617) than in minutes (0.537). The old
    /// `c < 0.12` step scaled a fixed interval by session length (7.4–84.5 min across one wearer's nights).
    static func cyclePrior(_ c: Double, _ minutesSinceOnset: Double) -> [String: Double] {
        ["deep": 1.2 * max(0.0, 1.0 - c / 0.55),
         "rem": 1.0 * c - remLatencyGuard(minutesSinceOnset),
         "light": 0.0, "awake": 0.0]
    }

    /// Sustained non-wake run, in 30 s epochs, that establishes sleep onset (10 epochs = 5 min). Against PSG
    /// onset on sleep-accel (n = 31): bias −3.8 min, MAE 7.4 min.
    static let onsetSustainedEpochs = 10

    /// Index of the first epoch that begins `onsetSustainedEpochs` consecutive non-"awake" labels, or nil when
    /// sleep is never sustained that long. Counted in epochs, not wall clock, so a coverage gap that drops
    /// an epoch can't satisfy the rule with less evidence.
    static func sustainedSleepOnset(_ labels: [String]) -> Int? {
        var run = 0
        for i in labels.indices {
            if labels[i] == "awake" { run = 0; continue }
            run += 1
            if run >= onsetSustainedEpochs { return i - onsetSustainedEpochs + 1 }
        }
        return nil
    }

    /// Viterbi most-likely path over the per-epoch log-emissions with the sticky transition matrix and a
    /// uniform start. Ties resolve to the earlier stage in `stageNames`.
    static func viterbi(_ emSeq: [[String: Double]]) -> [String] {
        if emSeq.isEmpty { return [] }
        // Floor before ln so a zeroed transition entry can't hit ln(0) = -Inf. LOAD-BEARING: the awake row has
        // wake→deep = wake→rem = 0.0, and floored a zero costs ln(1e-9) ≈ -20.7 against wake→light's ≈ -2.3.
        let logT = transition.mapValues { row in row.mapValues { log(max($0, 1e-9)) } }
        var V = emSeq[0]   // uniform start
        var back: [[String: String]] = []
        for t in 1..<emSeq.count {
            var newV = [String: Double](), bp = [String: String]()
            for s in stageNames {
                var bestPrev = stageNames[0]
                var bestVal = V[bestPrev]! + logT[bestPrev]![s]!
                for p in stageNames.dropFirst() {
                    let val = V[p]! + logT[p]![s]!
                    if val > bestVal { bestVal = val; bestPrev = p }
                }
                newV[s] = bestVal + emSeq[t][s]!
                bp[s] = bestPrev
            }
            V = newV; back.append(bp)
        }
        var last = stageNames[0], lastV = V[last]!
        for s in stageNames.dropFirst() where V[s]! > lastV { lastV = V[s]!; last = s }
        var path = [last]
        for bp in back.reversed() { last = bp[last]!; path.append(last) }
        return path.reversed()
    }

    /// Run the full recipe over a night's epochs and return one stage label per epoch (incl. "awake"). All
    /// normalisation (z-scores, the HR-flatness percentile) is WITHIN the night.
    ///
    /// Two passes: the REM-latency guard is measured from sleep ONSET, which is itself a staging output.
    /// Pass 1 stages with the guard disabled (`cyclePrior(c, .infinity)`) and reads the first sustained sleep
    /// run; pass 2 adds the guard re-based on that onset and re-runs Viterbi. Only the guard differs, so the
    /// extra cost is one Viterbi over a built lattice. With no sustained run the origin is the window start.
    static func stageEpochs(_ feats: [Epoch]) -> [String] {
        if feats.isEmpty { return [] }

        // Per-night z-score over present values (population std; 0 std → 1 so a flat channel is neutral).
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sd = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sd }
        }
        let zhr = zfun(feats.map { $0.hr })
        let zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let zrg = zfun(feats.map { $0.respReg })

        // HR-flatness percentile rank within the night (bisect_right / n), neutral 0.5 when missing.
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }

        var seq: [[String: Double]] = []
        seq.reserveCapacity(feats.count)
        for f in feats {
            let zhrv = zhr(f.hr), zhvv = zhv(f.hrVar), zmvv = zmv(f.moveFrac)
            let gate = deepGateSlope * max(0.0, fpct(f.hrFlat11) - deepGateThresh)
            // Cardiac contribution to the AWAKE emission. On a motion-quiescent epoch a raised HR / HR-variability
            // alone must not promote wake, so clamp the cardiac term to ≤ 0 (keep only the pro-sleep half).
            // Non-quiescent epochs use the restored post-#437 coefficients unchanged.
            let awakeCardiac0 = 0.8 * zhvv + 0.4 * zhrv
            let awakeCardiac = motionQuiescent(f) ? min(0.0, awakeCardiac0) : awakeCardiac0
            var em: [String: Double] = [
                "deep": -1.1 * zhvv - 0.5 * zmvv - gate + baseLogPrior["deep"]!,
                "rem": 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + baseLogPrior["rem"]!,
                "light": baseLogPrior["light"]!,
                "awake": 1.0 * zmvv + awakeCardiac + baseLogPrior["awake"]!,
            ]
            // Guard disabled here (`.infinity` ⇒ 0); pass 2 adds it once onset is known.
            let pr = cyclePrior(f.clock, .infinity)
            for s in stageNames { em[s]! += pr[s]! }
            if f.jerkMax > f.jerkScale * jerkFloorGateMult { em["awake"]! += motionGateBoost }
            if let rg = f.respReg { let z = zrg(rg); em["deep"]! += respWeight * z; em["rem"]! -= respWeight * z }
            seq.append(em)
        }

        // PASS 1: stage without the guard purely to locate sleep onset.
        let provisional = viterbi(seq)
        // Guard origin: centre of the first sustained-sleep epoch, in the window-relative minutes `features()`
        // stamped. No sustained run → 0.0 (the window start).
        let originMin = sustainedSleepOnset(provisional).map { feats[$0].minutesSinceOnset } ?? 0.0

        // PASS 2: apply the guard against minutes since that onset and re-run the lattice.
        for i in feats.indices {
            seq[i]["rem"]! -= remLatencyGuard(feats[i].minutesSinceOnset - originMin)
        }
        return viterbi(seq)
    }
}
