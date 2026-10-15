import Foundation
import WhoopProtocol

// WakeMotionRefinement: motion-aware wake refinement (#364 "Proposal 2"; density-gate precedent #345).
//
// Problem: both stagers (`SleepStager` V1, `SleepStagerV2`) call wake from HR / HRV and consult neither
// locomotion nor posture, so a night with elevated resting HR (supplements, hot room, alcohol) misreads
// hot-but-asleep as wake. One anonymized 5.0 night scored 194 min wake over ~6.4 h in bed (efficiency
// 0.50); its largest wake blocks held no walking cadence, only single-minute turn-over bursts (20-36
// step-counter ticks, a posture-variance spike) between minutes of complete stillness (variance < 0.01,
// zero ticks). A genuine get-up is sustained multi-minute walking cadence.
//
// Fix: a POST-PASS over the already-staged `[StageSegment]` of either stager (their HR-led models are
// untouched). For each wake segment of at least `minWakeSegmentSeconds`, check per-minute step-counter
// cadence (wrap-aware, `activityClass` 1=walk/2=run only) and per-minute gravity posture variance. A
// segment with NO locomotion (`hasNoLocomotion`) and posture stable outside a minority of burst minutes
// (`isPostureStable`) has its non-burst minutes reclassified to `light`; burst minutes plus a
// +/-`burstPadMinutes` buffer stay wake. It only ever shrinks wake time.
//
// Density self-gate (#345): the WHOOP 4.0 gravity stream is often too sparse (a single sample has zero
// variance and would read as "stable"), and a 4.0 emits no `StepSample` at all (zero ticks would always
// read as no locomotion). Rather than branch on strap model, `isMotionDense` measures the OBSERVED
// stream: at least `minDenseMinuteCoverageFraction` of the night's minutes must carry
// `>= minGravitySamplesPerMinuteForVariance` gravity samples AND `>= minStepSamplesPerMinuteForDensity`
// step records. A 4.0 night fails on the data; a dense 5.0/MG night clears it.
//
// Safety: default-off `Experimental` toggle (`PuffinExperiment.motionAwareWakeEnabled`), opt-in until
// more than one reference night backs it. All thresholds are NAMED CONSTANTS fixed a priori from that
// night, not fit to labels. Pure, deterministic, no I/O.
public enum WakeMotionRefinement {

    // MARK: - Tunables

    /// Only wake segments at least this long are considered; a shorter blip says nothing reliable about per-minute locomotion/posture.
    public static let minWakeSegmentSeconds: Int = 5 * 60

    /// A minute with at least this many walk-class ticks, held for `sustainedWalkMinConsecutiveMinutes` in a
    /// row, is real ambulation, not a turn-over.
    public static let sustainedWalkTicksPerMinute: Int = 10
    public static let sustainedWalkMinConsecutiveMinutes: Int = 2

    /// A single minute this busy counts as locomotion on its own (a very busy minute with a quiet neighbour).
    public static let singleMinuteWalkTicks: Int = 40

    /// Per-minute posture variance (g^2, see `postureVariance`) below this reads as "stable": the reference
    /// night's still stretches measured < 0.01, its turn-over spikes far above 0.05.
    public static let stablePostureVarianceG2: Double = 0.05

    /// Minimum fraction of a segment's minutes that must be posture-stable before it is trusted as "hot-but-still".
    public static let minStableMinuteFraction: Double = 0.80

    /// Minutes kept as wake on each side of a burst minute, so a reclassified block keeps its real motion edge.
    public static let burstPadMinutes: Int = 1

    /// Minimum gravity samples in a minute for its posture variance to mean anything (one sample has zero variance).
    public static let minGravitySamplesPerMinuteForVariance: Int = 2

    /// Minimum step records for a minute's tick cadence to be a real (possibly zero) reading, not a stream gap.
    public static let minStepSamplesPerMinuteForDensity: Int = 1

    /// Density self-gate (#345): fraction of the window's minutes that must clear both density floors before
    /// ANY segment is touched. Gates on the observed stream, never strap model.
    public static let minDenseMinuteCoverageFraction: Double = 0.80

    /// `activityClass` codes (community finding #316) that count as locomotion. 0 = still and nil are
    /// excluded; unattributed ticks feed the posture-variance gate instead.
    private static let locomotionActivityClasses: Set<Int> = [1 /* walk */, 2 /* run */]

    // MARK: - Public entry points

    /// The core pass: reclassifies non-burst minutes of eligible wake segments to `light`. `segments` must
    /// tile one contiguous window in order. Byte-identical passthrough when `segments` is empty, the window
    /// is degenerate, or the density self-gate declines.
    public static func refine(_ segments: [StageSegment], grav: [GravitySample], steps: [StepSample]) -> [StageSegment] {
        guard let windowStart = segments.first?.start, let windowEnd = segments.last?.end, windowEnd > windowStart else {
            return segments
        }
        guard isMotionDense(start: windowStart, end: windowEnd, grav: grav, steps: steps) else { return segments }

        let gravByMinute = bucketByMinute(grav) { $0.ts }
        let ticksByMinute = walkClassTicksPerMinute(steps)

        var out: [StageSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            for piece in refineSegment(seg, gravByMinute: gravByMinute, ticksByMinute: ticksByMinute) {
                appendMerging(piece, into: &out)
            }
        }
        return out
    }

    /// Toggle-shaped convenience: `enabled = false` is a byte-identical passthrough, `true` runs `refine`.
    public static func apply(_ segments: [StageSegment], grav: [GravitySample], steps: [StepSample],
                             enabled: Bool) -> [StageSegment] {
        enabled ? refine(segments, grav: grav, steps: steps) : segments
    }

    /// Session-level `refine`: refines `session.stages` and recomputes `efficiency` (derived from wake
    /// time); other fields carry over. Returns `session` unchanged when the stages are unchanged.
    public static func refine(_ session: SleepSession, grav: [GravitySample], steps: [StepSample]) -> SleepSession {
        let newStages = refine(session.stages, grav: grav, steps: steps)
        guard newStages != session.stages else { return session }
        let newEfficiency = SleepStager.efficiency(start: session.start, end: session.end, stages: newStages)
        // `hrOnly` is carried explicitly: this rebuilds the struct field by field and would drop a new field by default.
        return SleepSession(start: session.start, end: session.end, efficiency: newEfficiency,
                            stages: newStages, restingHR: session.restingHR, avgHRV: session.avgHRV,
                            hrOnly: session.hrOnly)
    }

    /// Toggle-shaped convenience for the session-level overload.
    public static func apply(_ session: SleepSession, grav: [GravitySample], steps: [StepSample],
                             enabled: Bool) -> SleepSession {
        enabled ? refine(session, grav: grav, steps: steps) : session
    }

    // MARK: - Density self-gate (#345)

    /// True when the gravity and step streams are dense enough, over the OBSERVED data, to trust per-minute
    /// evidence across `[start, end)` (see the file header).
    static func isMotionDense(start: Int, end: Int, grav: [GravitySample], steps: [StepSample]) -> Bool {
        let gravDensity = denseMinuteFraction(grav, from: start, to: end,
                                              minPerMinute: minGravitySamplesPerMinuteForVariance, ts: { $0.ts })
        let stepDensity = denseMinuteFraction(steps, from: start, to: end,
                                              minPerMinute: minStepSamplesPerMinuteForDensity, ts: { $0.ts })
        return gravDensity >= minDenseMinuteCoverageFraction && stepDensity >= minDenseMinuteCoverageFraction
    }

    /// Fraction of the minutes tiling `[start, end)` carrying at least `minPerMinute` samples; 0 for a degenerate window.
    static func denseMinuteFraction<T>(_ samples: [T], from start: Int, to end: Int, minPerMinute: Int,
                                       ts: (T) -> Int) -> Double {
        guard end > start else { return 0 }
        let firstMinute = start / 60
        let lastMinute = (end - 1) / 60
        guard lastMinute >= firstMinute else { return 0 }
        var counts: [Int: Int] = [:]
        for s in samples {
            let m = ts(s) / 60
            if m >= firstMinute && m <= lastMinute { counts[m, default: 0] += 1 }
        }
        let totalMinutes = lastMinute - firstMinute + 1
        var denseMinutes = 0
        for m in firstMinute...lastMinute where (counts[m] ?? 0) >= minPerMinute { denseMinutes += 1 }
        return Double(denseMinutes) / Double(totalMinutes)
    }

    // MARK: - Per-segment refinement

    /// Refines one `StageSegment`. Non-wake segments, wake shorter than `minWakeSegmentSeconds`, and
    /// segments failing EITHER the locomotion or stability gate pass through unchanged; it only acts
    /// when BOTH read "hot-but-still".
    static func refineSegment(_ seg: StageSegment, gravByMinute: [Int: [GravitySample]],
                              ticksByMinute: [Int: Int]) -> [StageSegment] {
        guard SleepStageVocabulary.isWake(seg.stage), seg.end - seg.start >= minWakeSegmentSeconds else { return [seg] }
        let mins = minutes(from: seg.start, to: seg.end)
        guard !mins.isEmpty else { return [seg] }

        guard !hasLocomotion(mins, ticksByMinute: ticksByMinute) else { return [seg] }

        guard let burstMinutes = stableBurstMinutes(mins, gravByMinute: gravByMinute) else { return [seg] }

        // Keep burst minutes plus a +/-burstPadMinutes buffer as wake, clamped to this segment (never grows
        // wake past the stager's call); reclassify the rest.
        let firstMinute = mins[0], lastMinute = mins[mins.count - 1]
        var keepWake: Set<Int> = []
        for m in burstMinutes {
            let lo = max(firstMinute, m - burstPadMinutes)
            let hi = min(lastMinute, m + burstPadMinutes)
            if lo <= hi { for p in lo...hi { keepWake.insert(p) } }
        }

        var result: [StageSegment] = []
        for (idx, m) in mins.enumerated() {
            let stage = keepWake.contains(m) ? "wake" : "light"
            let minuteStart = idx == 0 ? seg.start : m * 60
            let minuteEnd = idx == mins.count - 1 ? seg.end : (m + 1) * 60
            appendMerging(StageSegment(start: minuteStart, end: minuteEnd, stage: stage), into: &result)
        }
        return result
    }

    /// The locomotion gate: true when `mins` has a single minute at/above `singleMinuteWalkTicks`, or
    /// `sustainedWalkMinConsecutiveMinutes` consecutive minutes at/above `sustainedWalkTicksPerMinute`.
    /// A minute with no step coverage reads as 0 ticks and breaks a streak.
    static func hasLocomotion(_ mins: [Int], ticksByMinute: [Int: Int]) -> Bool {
        var consecutive = 0
        for m in mins {
            let ticks = ticksByMinute[m] ?? 0
            if ticks >= singleMinuteWalkTicks { return true }
            if ticks >= sustainedWalkTicksPerMinute {
                consecutive += 1
                if consecutive >= sustainedWalkMinConsecutiveMinutes { return true }
            } else {
                consecutive = 0
            }
        }
        return false
    }

    /// The stability gate. Returns the "burst" (not posture-stable) minutes when at least
    /// `minStableMinuteFraction` of `mins` are stable, else nil (leave the segment untouched). A minute with
    /// too few gravity samples for a variance counts as a burst: silence is not proof of stillness.
    static func stableBurstMinutes(_ mins: [Int], gravByMinute: [Int: [GravitySample]]) -> Set<Int>? {
        var burstMinutes: Set<Int> = []
        var stableCount = 0
        for m in mins {
            if let variance = postureVariance(gravByMinute[m] ?? []), variance < stablePostureVarianceG2 {
                stableCount += 1
            } else {
                burstMinutes.insert(m)
            }
        }
        guard Double(stableCount) / Double(mins.count) >= minStableMinuteFraction else { return nil }
        return burstMinutes
    }

    // MARK: - Signal extraction

    /// Per-minute posture variance: the trace of the covariance of a minute's gravity samples. Near 0 when
    /// orientation barely moves; spikes on a turn-over. Nil below `minGravitySamplesPerMinuteForVariance`.
    static func postureVariance(_ samples: [GravitySample]) -> Double? {
        guard samples.count >= minGravitySamplesPerMinuteForVariance else { return nil }
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

    /// Per-minute walk-class tick cadence: the wrap-aware u16 counter delta between consecutive samples,
    /// attributed to the LATER sample's minute and kept only when its `activityClass` is walk or run. Still
    /// or unknown-class deltas are deliberately not locomotion (they show up in `postureVariance`). Minutes
    /// with no qualifying tick are absent (callers read `?? 0`).
    static func walkClassTicksPerMinute(_ steps: [StepSample]) -> [Int: Int] {
        let sorted = steps.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return [:] }
        var out: [Int: Int] = [:]
        for i in 1..<sorted.count {
            let cur = sorted[i]
            guard let cls = cur.activityClass, locomotionActivityClasses.contains(cls) else { continue }
            let delta = (cur.counter - sorted[i - 1].counter) & 0xFFFF   // wrap-aware u16 increment
            out[cur.ts / 60, default: 0] += delta
        }
        return out
    }

    // MARK: - Small shared helpers

    /// The minute indices (unix seconds / 60) tiling `[start, end)`; empty for a degenerate window.
    static func minutes(from start: Int, to end: Int) -> [Int] {
        guard end > start else { return [] }
        let first = start / 60
        let last = (end - 1) / 60
        guard last >= first else { return [] }
        return Array(first...last)
    }

    static func bucketByMinute<T>(_ samples: [T], ts: (T) -> Int) -> [Int: [T]] {
        var out: [Int: [T]] = [:]
        for s in samples { out[ts(s) / 60, default: []].append(s) }
        return out
    }

    /// Appends `piece`, merging into the previous element when the stage matches and the two are contiguous.
    static func appendMerging(_ piece: StageSegment, into out: inout [StageSegment]) {
        if let lastIdx = out.indices.last, out[lastIdx].stage == piece.stage, out[lastIdx].end == piece.start {
            out[lastIdx].end = piece.end
        } else {
            out.append(piece)
        }
    }
}
