import Foundation

// Finds a user's personal resonance-frequency breathing pace by sweeping candidate paces and measuring which
// maximises respiratory sinus arrhythmia (RSA) amplitude. Pure and DB-free; the per-platform live controller
// paces each candidate via `BreathPacer` + the buzz path, feeds the clean R-R per pace back here and persists the lock.
//
// Theory (Lehrer/Gevirtz, approach only): a personal pace, usually 4.5-7 br/min, aligns the 0.1 Hz baroreflex
// and RSA so HR-oscillation amplitude peaks. HR speeds on inhale and slows on exhale; since WE paced each breath
// cycle we know its boundaries and measure the mean peak-to-trough swing of instantaneous HR (60000/RR) per
// cycle. That swing peaks at resonance; RMSSD (shared `HRVAnalyzer`) corroborates and breaks ties.
//
// Limits: WHOOP R-R is PPG-derived, not ECG, so RSA/HF-HRV are estimates, never clinical. A pace with too few
// clean beats is left unscored; fewer than `minScoredPaces` scored means "no lock" and the 5.5 br/min coherence
// fallback. The pace drifts, so the caller dates it.

public enum ResonanceEngine {

    // MARK: - Candidate paces

    /// Full sweep paces (br/min): the 4.5-7.0 resonance band in 0.5 steps.
    public static let fullSweepPaces: [Double] = [4.5, 5.0, 5.5, 6.0, 6.5, 7.0]
    /// Quick sweep (~7 min): the band's ends and centre.
    public static let quickSweepPaces: [Double] = [4.5, 5.5, 6.5]
    /// Coherence fallback pace when no resonance pace locks.
    public static let fallbackBpm: Double = 5.5

    // MARK: - Tunables

    /// Leading seconds of each pace dropped as a settling transient before scoring.
    public static let transientDropSeconds: Int = 30
    /// Minimum clean beats over a pace's steady window (mirrors `HRVAnalyzer.minBeats`).
    public static let minBeatsPerPace: Int = HRVAnalyzer.minBeats
    /// Minimum breath cycles with a measurable swing before a pace is scorable.
    public static let minCyclesPerPace: Int = 3
    /// Fewer scored paces than this: no confident lock, use `fallbackBpm`.
    public static let minScoredPaces: Int = 3

    // MARK: - Inputs / outputs

    /// One beat as a plain (ts, rrMs) pair (unix seconds, ms), decoupled from storage entities.
    public struct RrBeat: Equatable, Sendable {
        public let ts: Int
        public let rrMs: Int
        public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
    }

    /// The clean R-R one paced candidate produced; `startTs` / `endTs` bound the window and the transient drop is relative to `startTs`.
    public struct PaceSample: Equatable, Sendable {
        public let bpm: Double
        public let rr: [RrBeat]
        public let startTs: Int
        public let endTs: Int
        public init(bpm: Double, rr: [RrBeat], startTs: Int, endTs: Int) {
            self.bpm = bpm; self.rr = rr; self.startTs = startTs; self.endTs = endTs
        }
    }

    /// RSA / RMSSD response at one swept pace; `rsaAmplitude` is nil (unscored) when the steady window had too few clean beats or cycles.
    public struct PaceScore: Equatable, Sendable {
        /// Paced breaths/min.
        public let bpm: Double
        /// Mean peak-to-trough instantaneous-HR swing per breath cycle (bpm), or nil if unscored.
        public let rsaAmplitude: Double?
        /// RMSSD over the steady-window clean beats (ms), or nil.
        public let rmssd: Double?
        /// Clean beats used in the steady window.
        public let cleanBeats: Int
        /// Breath cycles that yielded a measurable swing.
        public let scoredCycles: Int
        /// Whether RSA is present.
        public var scored: Bool { rsaAmplitude != nil }

        public init(bpm: Double, rsaAmplitude: Double?, rmssd: Double?, cleanBeats: Int, scoredCycles: Int) {
            self.bpm = bpm; self.rsaAmplitude = rsaAmplitude; self.rmssd = rmssd
            self.cleanBeats = cleanBeats; self.scoredCycles = scoredCycles
        }
    }

    /// Every pace's score plus the locked pace. `lockedBpm` is always finite (the fallback when not locked); `didLock` tells the copy "your pace" vs "couldn't lock today".
    public struct SweepResult: Equatable, Sendable {
        /// Per-pace scores in sweep order.
        public let scores: [PaceScore]
        /// The RSA-max scored pace, or `fallbackBpm` when no confident lock.
        public let lockedBpm: Double
        /// True when a resonance pace was confidently locked; false when it fell back to coherence.
        public let didLock: Bool

        public init(scores: [PaceScore], lockedBpm: Double, didLock: Bool) {
            self.scores = scores; self.lockedBpm = lockedBpm; self.didLock = didLock
        }
    }

    // MARK: - Per-pace RSA scoring

    /// Scores one paced candidate: cleans its R-R, drops the leading transient, slices the steady window into
    /// paced breath cycles and measures the mean per-cycle HR swing. Too few beats/cycles gives `rsaAmplitude == nil`.
    public static func scorePace(_ sample: PaceSample) -> PaceScore {
        let cycleMs = 60_000.0 / max(sample.bpm, BreathPacer.minBpm)
        let cycleSec = cycleMs / 1000.0

        let windowStart = sample.startTs + transientDropSeconds
        // STABLE sort (#823): cleanRR feeds RMSSD, which is all successive differences, so same-second beat order
        // changes the score. Swift's sorted(by:) is not guaranteed stable, so decorate with the offset to make the
        // comparator total (Kotlin's sortedBy is stable). Spelled out rather than reusing WhoopProtocol's
        // `sortedByTsStable` to keep this file DB-free; keep the two in step.
        let steady = sample.rr
            .filter { $0.ts >= windowStart && $0.ts <= sample.endTs }
            .enumerated()
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
            .map(\.element)

        // Clean R-R (range + Malik) for both RMSSD and the swing, so ectopic beats can't fabricate an RSA swing.
        let cleanMs = HRVAnalyzer.cleanRR(steady.map { Double($0.rrMs) })
        guard cleanMs.count >= minBeatsPerPace else {
            return PaceScore(bpm: sample.bpm, rsaAmplitude: nil, rmssd: nil,
                             cleanBeats: cleanMs.count, scoredCycles: 0)
        }

        // Re-pair cleaned values to timestamps in order against `steady` (cleaning only drops beats).
        let cleanBeats = repairTimestamps(steady: steady, cleanMs: cleanMs)
        let rmssd = HRVAnalyzer.rmssdRaw(cleanMs)

        // Bucket clean beats into paced cycles relative to windowStart; per cycle take the peak-to-trough swing of 60000/RR.
        var swings: [Double] = []
        if cycleSec > 0, let firstTs = cleanBeats.first?.ts {
            var cycleIdx = 0
            var cycleHRs: [Double] = []
            func flush() {
                if cycleHRs.count >= 2 {
                    let hi = cycleHRs.max() ?? 0
                    let lo = cycleHRs.min() ?? 0
                    swings.append(hi - lo)
                }
                cycleHRs.removeAll(keepingCapacity: true)
            }
            for beat in cleanBeats {
                let idx = Int(Double(beat.ts - firstTs) / cycleSec)
                if idx != cycleIdx { flush(); cycleIdx = idx }
                cycleHRs.append(60_000.0 / beat.rrMs)
            }
            flush()
        }

        guard swings.count >= minCyclesPerPace else {
            return PaceScore(bpm: sample.bpm, rsaAmplitude: nil, rmssd: rmssd,
                             cleanBeats: cleanMs.count, scoredCycles: swings.count)
        }
        let rsa = swings.reduce(0, +) / Double(swings.count)
        return PaceScore(bpm: sample.bpm, rsaAmplitude: rsa, rmssd: rmssd,
                         cleanBeats: cleanMs.count, scoredCycles: swings.count)
    }

    // MARK: - The sweep -> locked pace

    /// Scores every candidate and locks the scored pace with the largest RSA amplitude (higher RMSSD breaks ties).
    /// Fewer than `minScoredPaces` scored: no lock, fall back to `fallbackBpm`.
    public static func sweep(_ samples: [PaceSample]) -> SweepResult {
        let scores = samples.map { scorePace($0) }
        let scored = scores.filter { $0.scored }

        guard scored.count >= minScoredPaces else {
            return SweepResult(scores: scores, lockedBpm: fallbackBpm, didLock: false)
        }
        // Max RSA; tie -> higher RMSSD; final tie -> slower pace (calmer).
        let best = scored.max { a, b in
            let ra = a.rsaAmplitude ?? 0, rb = b.rsaAmplitude ?? 0
            if ra != rb { return ra < rb }
            let ma = a.rmssd ?? 0, mb = b.rmssd ?? 0
            if ma != mb { return ma < mb }
            return a.bpm > b.bpm
        }
        return SweepResult(scores: scores, lockedBpm: best?.bpm ?? fallbackBpm, didLock: true)
    }

    // MARK: - Helpers

    /// One clean beat with its timestamp restored.
    struct CleanBeat: Equatable { let ts: Int; let rrMs: Double }

    /// Re-attaches timestamps to the cleaned series; cleaning preserves order and only drops beats, so walk `steady` consuming the next match.
    static func repairTimestamps(steady: [RrBeat], cleanMs: [Double]) -> [CleanBeat] {
        var out: [CleanBeat] = []
        out.reserveCapacity(cleanMs.count)
        var si = 0
        for v in cleanMs {
            while si < steady.count && Double(steady[si].rrMs) != v { si += 1 }
            if si < steady.count {
                out.append(CleanBeat(ts: steady[si].ts, rrMs: v))
                si += 1
            }
        }
        return out
    }
}
