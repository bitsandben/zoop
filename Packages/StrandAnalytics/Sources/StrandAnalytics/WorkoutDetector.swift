import Foundation
import WhoopProtocol
import WhoopStore

// WorkoutDetector: retroactive workout detection from the 1 Hz store.
//
// A workout is a SUSTAINED window (>= minExerciseMin) of elevated HR (above resting + hrMarginBPM) AND
// sustained motion (gravity-derived intensity above motionThreshold); both gates must hold per sample.
// Per bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR, strain (StrainScorer), and calories
// (Keytel 2005 active + revised Harris-Benedict BMR resting). Outputs are APPROXIMATE, not medical advice.

// MARK: - Profile + result

/// User profile for calorie estimation.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double
    public var age: Double
    public var sex: String   // "male" | "female" | "nonbinary"
    /// Counter ticks per real step for the @57 motion counter (#139). The 5/MG counter overcounts at an
    /// unknown rate, so the daily-steps total divides by this. 1.0 = raw pass-through; the engine clamps >= 0.5.
    public var stepTicksPerStep: Double
    public init(weightKg: Double = 70.0, heightCm: Double = 170.0,
                age: Double = 30.0, sex: String = "nonbinary",
                stepTicksPerStep: Double = 1.0) {
        self.weightKg = weightKg; self.heightCm = heightCm
        self.age = age; self.sex = sex
        self.stepTicksPerStep = stepTicksPerStep
    }

    /// Every stored field, for a cache key that must change when the profile does (the per-cycle load cache).
    /// Named explicitly rather than via `String(describing:)` (not a contract, costs reflection); a new
    /// field belongs here too. Doubles by bit pattern, so the key is exact and locale-free.
    public var cacheKey: String {
        "w=\(weightKg.bitPattern),h=\(heightCm.bitPattern),a=\(age.bitPattern),s=\(sex),t=\(stepTicksPerStep.bitPattern)"
    }
}

/// A detected workout window. All intensity fields are APPROXIMATE.
public struct ExerciseSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let avgHR: Double
    public let peakHR: Int
    public let strain: Double?
    public let durationS: Double
    /// Edwards zone (0-5) time breakdown as % of HR samples; sums to 100.
    public let zoneTimePct: [Int: Double]
    /// Mean Karvonen %HRR over the bout, clamped [0, 100], or nil.
    public let avgHRRPct: Double?
    /// Effective HRmax used for zone math (bpm), or nil.
    public let hrmax: Double?
    /// "caller" | "observed" | "tanaka" | "unknown".
    public let hrmaxSource: String
    public let caloriesKcal: Double?
    public let caloriesKJ: Double?
    /// #1545: percentage of 60-second buckets in the bout that contain at least one HR reading; nil when
    /// not measured. A 4.0's optical sensor is weak under gripping (lifting), so a low Effort is either the
    /// metric not rating the work or the strap not seeing it, which deserve opposite advice.
    public let hrCoveragePct: Double?

    public init(start: Int, end: Int, avgHR: Double, peakHR: Int, strain: Double?,
                durationS: Double, zoneTimePct: [Int: Double], avgHRRPct: Double?,
                hrmax: Double?, hrmaxSource: String,
                caloriesKcal: Double?, caloriesKJ: Double?,
                hrCoveragePct: Double? = nil) {
        self.start = start; self.end = end; self.avgHR = avgHR; self.peakHR = peakHR
        self.strain = strain; self.durationS = durationS; self.zoneTimePct = zoneTimePct
        self.avgHRRPct = avgHRRPct; self.hrmax = hrmax; self.hrmaxSource = hrmaxSource
        self.caloriesKcal = caloriesKcal; self.caloriesKJ = caloriesKJ
        self.hrCoveragePct = hrCoveragePct
    }
}

public enum WorkoutDetector {

    // MARK: - Constants (exercise.py)

    public static let minExerciseMin: Double = 5.0
    public static let hrMarginBPM: Double = 15.0
    public static let motionThreshold: Double = 0.20
    public static let motionSmoothS: Double = 10.0
    public static let mergeGapS: Double = 150.0
    public static let minIntensityZ2Plus: Double = 0.50
    public static let alignToleranceS: Double = 5.0
    public static let restingPercentile: Double = 10.0
    /// Second-pass bridge window (#303): adjacent active runs separated by a below-motion-threshold gap no
    /// longer than this are stitched into one workout, BUT ONLY while HR stays elevated across the gap (see
    /// `bridgeRuns`). Endurance efforts dip below the motion gate for minutes (coasting, a junction, a sensor
    /// dropout) and `mergeGapS` is too tight, so the bout shattered into sub-bouts under `minExerciseMin`.
    /// A genuine rest between workouts is gated out by the HR check, not this window.
    public static let bridgeGapS: Double = 300.0

    // MARK: - Activity series

    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
    }

    /// Per-record motion-intensity series: L2 magnitude of the gravity change vs the previous record
    /// (first row 0, empty input empty).
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var series: [ActivityPoint] = []
        series.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0 { intensity = 0.0 }
            else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else { intensity = 0.0 }
            series.append(ActivityPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return series
    }

    // MARK: - Helpers

    /// Sorted (ts, bpm) pairs.
    static func cleanHR(_ hr: [HRSample]) -> [(ts: Int, bpm: Double)] {
        hr.map { (ts: $0.ts, bpm: Double($0.bpm)) }.sorted { $0.ts < $1.ts }
    }

    /// Day resting-HR baseline: nearest-rank `restingPercentile` of bpm values.
    static func deriveRestingHR(_ hrSeg: [(ts: Int, bpm: Double)]) -> Double {
        let bpms = hrSeg.map { $0.bpm }.sorted()
        precondition(!bpms.isEmpty, "deriveRestingHR called with empty segment")
        let rank = max(1, Int(ceil(restingPercentile / 100.0 * Double(bpms.count))))
        return bpms[rank - 1]
    }

    /// #1545: why a day produced no workout, counted at each gate the detector applies. The `effort bout`
    /// line explains a bout that exists; "no workouts at all" is harder (strap never registered motion, a
    /// 4.0 banks it coarsely #345/#28; HR never cleared resting + 15; or efforts under five minutes).
    /// Counted during the detector's OWN walk, never recomputed alongside it: a funnel free to disagree with
    /// the code it describes would be believed.
    public struct DetectionFunnel: Equatable, Sendable {
        /// Inputs the day actually had.
        public var hrSamples = 0
        public var motionSamples = 0
        /// The bar a sample had to clear, in bpm: resting + `hrMarginBPM`.
        public var restingHR: Double? = nil
        public var hrFloor: Double? = nil
        /// Motion samples whose smoothed intensity cleared `motionThreshold`.
        public var motionPassed = 0
        /// Of those, how many had NO HR sample within `alignToleranceS` (a sensor gap, not a quiet body).
        public var hrMissing = 0
        /// Of those, how many had HR at or below `hrFloor` (moving, but not working).
        public var hrTooLow = 0
        /// Samples that cleared BOTH gates.
        public var active = 0
        /// Contiguous runs after gap-merging, and after the #303 HR-gated bridge.
        public var runs = 0
        public var bridged = 0
        /// The LONGEST and MEAN bridged run in seconds, before any qualification gate drops anything. They
        /// say how substantial the best candidate was (a five-minute stroll vs an hour-long effort rejected
        /// on intensity), which the counts cannot (field log: 22 days of `kept=0`, 1271 runs under
        /// `minExerciseMin`, 390 that failed intensity). Read `longestRunS` against 290 s, not 300: the gate
        /// is `minDurS - motionSmoothS` because smoothing costs a run its first samples.
        public var longestRunS = 0
        public var meanRunS = 0
        /// Runs rejected by each qualification gate, and the survivors.
        public var droppedShort = 0
        public var droppedNoHR = 0
        public var droppedLowIntensity = 0
        public var kept = 0

        public init() {}
    }

    /// #1545: the always-on per-day line naming where the detector lost every candidate workout. No PII:
    /// a day key, counts and the two bpm thresholds.
    public static func detectionFunnelLine(day: String, funnel f: DetectionFunnel) -> String {
        "workout detect day=\(day) hr=\(f.hrSamples) motion=\(f.motionSamples) "
            + "restHR=\(round0(f.restingHR)) floor=\(round0(f.hrFloor)) "
            + "motionOK=\(f.motionPassed) hrMissing=\(f.hrMissing) hrTooLow=\(f.hrTooLow) "
            + "active=\(f.active) runs=\(f.runs) bridged=\(f.bridged) "
            + "longestRunS=\(f.longestRunS) meanRunS=\(f.meanRunS) "
            + "short=\(f.droppedShort) noHR=\(f.droppedNoHR) lowIntensity=\(f.droppedLowIntensity) "
            + "kept=\(f.kept)"
    }

    /// #1545: percentage of `bucketSeconds`-wide buckets in `[start, end]` holding at least one HR reading.
    /// Bucketed, not sample-counted: a 5/MG sends live HR ~every 30 s, so counting against a 1 Hz
    /// expectation would report ~3% for a perfectly captured bout.
    public static func hrCoveragePct(sampleTs: [Int], start: Int, end: Int,
                                     bucketSeconds: Int = 60) -> Double? {
        guard end > start, bucketSeconds > 0 else { return nil }
        // Integer ceil (no float rounding at a bucket boundary); a partial trailing bucket counts whole, so coverage never exceeds 100.
        let buckets = max(1, ((end - start) + bucketSeconds - 1) / bucketSeconds)
        var seen = Set<Int>()
        for ts in sampleTs where ts >= start && ts < end {
            seen.insert((ts - start) / bucketSeconds)
        }
        return Double(seen.count) / Double(buckets) * 100.0
    }

    /// #1545: the always-on per-bout line naming what this workout's Effort was scored against. HRmax sets
    /// every zone boundary (a few bpm can move real work across the 50% floor), and a user could not
    /// otherwise see which number was used or whether it was their setting or an age formula. No PII.
    public static func boutCalibrationLine(day: String, durMin: Int, hrmax: Double?, hrmaxSource: String,
                                           avgHRRPct: Double?, hrCoveragePct: Double?,
                                           strain: Double?) -> String {
        return "effort bout day=\(day) durMin=\(durMin) hrmax=\(round0(hrmax)) src=\(hrmaxSource) "
            + "avgHRR=\(round0(avgHRRPct)) cover=\(round0(hrCoveragePct)) effort=\(round1(strain))"
    }

    /// Magnitude bound for the formatters below, which use integer arithmetic over `abs(v)` rather than
    /// `%.0f` / `%.1f` so the line is identical between iOS and Android logs:
    /// - Ties: C `printf` rounds ties to even, Java up, so 52.5 would print 52 vs 53. Swift's `.rounded()`
    ///   is half-away and Java's `Math.round` half-up, so -4.5 differs; rounding `abs(v)` and re-applying
    ///   the sign makes both identical and keeps the minus sign (-0.4 would otherwise print `0.4`).
    /// - Overflow: Swift's `Int(Double)` CRASHES past `Int.max` while Kotlin saturates. Public API, so past
    ///   this bound both print `nil` (such a value is not a heart rate, percentage or Effort).
    static let printableMagnitudeLimit = 1e15

    static func round0(_ v: Double?) -> String {
        guard let v, v.isFinite, abs(v) < printableMagnitudeLimit else { return "nil" }
        return (v < 0 ? "-" : "") + String(Int(abs(v).rounded()))
    }

    static func round1(_ v: Double?) -> String {
        guard let v, v.isFinite, abs(v) < printableMagnitudeLimit else { return "nil" }
        let t = Int((abs(v) * 10).rounded())
        return "\(v < 0 ? "-" : "")\(t / 10).\(t % 10)"
    }

    /// Value whose ts is nearest to `ts` within `tol` seconds, else nil; ties go to the later timestamp.
    static func nearest(_ sortedTs: [Int], _ values: [Double], _ ts: Int, _ tol: Double) -> Double? {
        if sortedTs.isEmpty { return nil }
        // bisect_left
        var lo = 0, hi = sortedTs.count
        while lo < hi { let mid = (lo + hi) / 2; if sortedTs[mid] < ts { lo = mid + 1 } else { hi = mid } }
        let i = lo
        var bestV: Double? = nil
        var bestD = tol
        for j in [i - 1, i] where j >= 0 && j < sortedTs.count {
            let d = abs(Double(sortedTs[j] - ts))
            if d <= bestD { bestD = d; bestV = values[j] }
        }
        return bestV
    }

    /// Trailing rolling mean of intensities over `windowS`.
    static func smoothedIntensity(_ motion: [ActivityPoint], windowS: Double) -> [Double] {
        let ts = motion.map { $0.ts }
        let raw = motion.map { $0.intensity.isFinite ? $0.intensity : 0.0 }
        var out: [Double] = []
        out.reserveCapacity(motion.count)
        var lo = 0
        var running = 0.0
        for i in 0..<motion.count {
            running += raw[i]
            while Double(ts[i] - ts[lo]) > windowS { running -= raw[lo]; lo += 1 }
            out.append(running / Double(i - lo + 1))
        }
        return out
    }

    /// Per-bout Edwards zone breakdown (%) + mean %HRR. APPROXIMATE.
    static func boutIntensity(_ hrSeries: [(ts: Int, bpm: Double)],
                              restingHR: Double, maxHR: Double) -> ([Int: Double], Double?) {
        if hrSeries.isEmpty || maxHR <= restingHR { return ([:], nil) }
        let hrReserve = maxHR - restingHR
        var zoneCounts = [Int: Int]()
        for z in 0...5 { zoneCounts[z] = 0 }
        var hrrVals: [Double] = []
        for r in hrSeries {
            let z = StrainScorer.zoneWeight(r.bpm, restingHR: restingHR, hrReserve: hrReserve)
            zoneCounts[z, default: 0] += 1
            hrrVals.append(StrainScorer.pctHRR(r.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
        let n = Double(hrSeries.count)
        var zonePct = [Int: Double]()
        for (z, c) in zoneCounts { zonePct[z] = ((Double(c) / n * 100.0) * 10).rounded() / 10 }
        let avgHRR = ((hrrVals.reduce(0, +) / n) * 10).rounded() / 10
        return (zonePct, avgHRR)
    }

    /// Second-pass merge over raw active runs (#303): stitches run i+1 onto the current span when the gap is
    /// <= `bridgeGapS` AND mean HR strictly inside the gap is still above `hrFloor` (the athlete kept working
    /// through a motion lull). A gap with NO HR samples is a same-effort sensor dropout and is bridged; a
    /// real rest lands 1 Hz HR samples in the gap and fails the test. Runs must arrive sorted by start.
    static func bridgeRuns(_ runs: [(Int, Int)],
                           hrSeg: [(ts: Int, bpm: Double)],
                           hrFloor: Double) -> [(Int, Int)] {
        guard runs.count > 1 else { return runs }
        var merged: [(Int, Int)] = []
        var curStart = runs[0].0
        var curEnd = runs[0].1
        for next in runs.dropFirst() {
            let gap = Double(next.0 - curEnd)
            var bridge = false
            if gap <= bridgeGapS {
                // HR samples strictly between the two runs.
                let gapHR = hrSeg.filter { $0.ts > curEnd && $0.ts < next.0 }.map { $0.bpm }
                if gapHR.isEmpty {
                    bridge = true   // sensor dropout mid-effort → same workout
                } else {
                    let meanGapHR = gapHR.reduce(0, +) / Double(gapHR.count)
                    bridge = meanGapHR > hrFloor   // still working → same workout
                }
            }
            if bridge {
                curEnd = max(curEnd, next.1)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.0
                curEnd = next.1
            }
        }
        merged.append((curStart, curEnd))
        return merged
    }

    /// #148: back-dates a confirmed run's start over the warm-up. Motion leads HR at onset (cardiac warm-up
    /// takes minutes), so the HR-AND-motion gate clips the leading stretch. Once a run has qualified on its
    /// HR-elevated core, extend the start backward over contiguous above-`motionThreshold` samples, stopping
    /// at a motion gap > `mergeGapS` or the series start. `coreStart` is an active-sample ts; `smooth` is
    /// index-aligned with `motionTs`.
    static func backdatedStart(_ coreStart: Int, _ motionTs: [Int], _ smooth: [Double]) -> Int {
        var i = motionTs.firstIndex(where: { $0 >= coreStart }) ?? motionTs.count
        guard i < motionTs.count else { return coreStart }
        var start = coreStart
        var prevTs = motionTs[i]
        while i > 0 {
            i -= 1
            if smooth[i] <= motionThreshold { break }                    // motion dropped → warm-up start
            if Double(prevTs - motionTs[i]) > mergeGapS { break }        // real pause → stop
            start = motionTs[i]
            prevTs = motionTs[i]
        }
        return start
    }

    // MARK: - Public API

    /// Detects workouts from the 1 Hz HR + gravity store.
    ///
    /// - Parameters:
    ///   - hr: heart-rate stream (required; empty gives []).
    ///   - gravity: gravity stream (required; empty gives []).
    ///   - restingHR: day resting-HR baseline (bpm); nil derives the 10th percentile of the day's HR.
    ///   - maxHR: HRmax (bpm); nil estimates via StrainScorer.estimateHRmax.
    ///   - age: used only for the Tanaka fallback when maxHR is nil.
    ///   - profile: when provided, per-bout calories are estimated.
    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              restingHR: Double? = nil,
                              maxHR: Double? = nil,
                              age: Double? = nil,
                              profile: UserProfile? = nil,
                              // #1545: TRIMP recipe for each bout's Effort (default Edwards). The app threads the
                              // user's choice so a bout and its day are never scored by different recipes.
                              effortMethod: StrainScorer.Method = .edwards,
                              // #1545: receives the gate-by-gate counts for THIS call; nil computes nothing extra.
                              funnel: ((DetectionFunnel) -> Void)? = nil) -> [ExerciseSession] {
        // `defer` so the funnel is reported on EVERY exit; a day that bails at "no motion rows" matters most.
        var f = DetectionFunnel()
        defer { funnel?(f) }

        let hrSeg = cleanHR(hr)
        let motion = activitySeries(gravity)
        f.hrSamples = hrSeg.count
        f.motionSamples = motion.count
        if hrSeg.isEmpty || motion.isEmpty { return [] }

        let restHR = restingHR ?? deriveRestingHR(hrSeg)
        let hrFloor = restHR + hrMarginBPM
        f.restingHR = restHR
        f.hrFloor = hrFloor

        let effMaxHR: Double?
        let hrmaxSource: String
        if let m = maxHR {
            effMaxHR = m; hrmaxSource = "caller"
        } else {
            let (est, src) = StrainScorer.estimateHRmax(hrSeg.map { $0.bpm }, age: age)
            effMaxHR = est == 0.0 ? nil : est
            hrmaxSource = src
        }

        let hrTs = hrSeg.map { $0.ts }
        let hrBpm = hrSeg.map { $0.bpm }
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)
        let motionTs = motion.map { $0.ts }

        // Walk the gravity timeline; flag samples where BOTH gates hold.
        var activeTs: [Int] = []
        for (p, inten) in zip(motion, smooth) {
            if inten <= motionThreshold { continue }
            f.motionPassed += 1
            // Split the HR rejection: no sample within tolerance is a SENSOR GAP; a sample at/below the floor is a body not working.
            guard let bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS) else { f.hrMissing += 1; continue }
            guard bpm > hrFloor else { f.hrTooLow += 1; continue }
            activeTs.append(p.ts)
        }
        f.active = activeTs.count
        if activeTs.isEmpty { return [] }

        // Group contiguous active samples into runs, merging gaps <= mergeGapS.
        var runs: [(Int, Int)] = []
        var runStart = activeTs[0]
        var prev = activeTs[0]
        for ts in activeTs.dropFirst() {
            if Double(ts - prev) > mergeGapS { runs.append((runStart, prev)); runStart = ts }
            prev = ts
        }
        runs.append((runStart, prev))
        f.runs = runs.count

        // Second pass (#303): bridge runs across a brief, still-elevated-HR lull; a genuine rest is not bridged.
        runs = bridgeRuns(runs, hrSeg: hrSeg, hrFloor: hrFloor)
        f.bridged = runs.count
        // Measured on the BRIDGED runs, before any qualification gate: what a `kept=0` day must be judged against.
        if !runs.isEmpty {
            let durs = runs.map { max(0, $0.1 - $0.0) }
            f.longestRunS = durs.max() ?? 0
            f.meanRunS = durs.reduce(0, +) / durs.count
        }

        let minDurS = minExerciseMin * 60.0
        var sessions: [ExerciseSession] = []
        for (idx, run) in runs.enumerated() {
            let (start, end) = run
            // Onset latency tolerance equal to the smoothing window.
            if Double(end - start) < minDurS - motionSmoothS { f.droppedShort += 1; continue }
            // Qualify on the HR-elevated CORE so the warm-up's low intensity cannot dilute a real workout (#148).
            let core = hrSeg.filter { $0.ts >= start && $0.ts <= end }
            if core.isEmpty { f.droppedNoHR += 1; continue }

            var zonePct: [Int: Double] = [:]
            var avgHRR: Double? = nil
            if let m = effMaxHR, m > restHR {
                (zonePct, avgHRR) = boutIntensity(core, restingHR: restHR, maxHR: m)
            }

            // Intensity qualification: at least minIntensityZ2Plus in zone 2+.
            if !zonePct.isEmpty {
                let z2plus = (2...5).reduce(0.0) { $0 + (zonePct[$1] ?? 0.0) } / 100.0
                if z2plus < minIntensityZ2Plus { f.droppedLowIntensity += 1; continue }
            }

            // Qualified: back-date over the warm-up (#148), never past the previous run's end, so two efforts
            // kept separate by a resting-HR dip cannot overlap.
            let floor = idx > 0 ? runs[idx - 1].1 + 1 : Int.min
            let effStart = max(Self.backdatedStart(start, motionTs, smooth), floor)
            let window = hrSeg.filter { $0.ts >= effStart && $0.ts <= end }
            if window.isEmpty { f.droppedNoHR += 1; continue }
            let bpms = window.map { $0.bpm }
            let hrSamples = window.map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

            var kcal: Double? = nil
            var kj: Double? = nil
            if let profile = profile {
                let (k, j) = Calories.estimateBoutCalories(hrSamples, profile: profile,
                                                           hrmax: effMaxHR, restingHR: restHR)
                kcal = k; kj = j
            }

            guard !bpms.isEmpty else { f.droppedNoHR += 1; continue }   // degenerate bout, no HR samples
            let avg = bpms.reduce(0, +) / Double(bpms.count)
            let peak = Int(bpms.max()!.rounded())
            let strain = StrainScorer.strain(hrSamples, maxHR: effMaxHR, restingHR: restHR,
                                             method: effortMethod, sex: profile?.sex ?? "male")

            sessions.append(ExerciseSession(
                start: effStart, end: end, avgHR: avg, peakHR: peak, strain: strain,
                durationS: Double(end - effStart), zoneTimePct: zonePct, avgHRRPct: avgHRR,
                hrmax: effMaxHR, hrmaxSource: hrmaxSource, caloriesKcal: kcal, caloriesKJ: kj,
                hrCoveragePct: hrCoveragePct(sampleTs: hrSamples.map { $0.ts },
                                             start: effStart, end: end)))
        }
        f.kept = sessions.count
        return sessions
    }

    /// #510: backfills ONLY the avgHr/maxHr/energyKcal/strain fields `real` lacks from a detected bout's
    /// values, never touching a field already present (typed, imported or earlier-filled). `real` unchanged
    /// (`==`) means nothing was filled, so the caller can tell whether a write is needed.
    public static func backfillWorkout(_ real: WorkoutRow, avgBpm: Int, peakHR: Int, caloriesKcal: Double?, strain: Double?) -> WorkoutRow {
        WorkoutRow(
            startTs: real.startTs, endTs: real.endTs, sport: real.sport, source: real.source,
            durationS: real.durationS,
            energyKcal: real.energyKcal ?? caloriesKcal,
            avgHr: real.avgHr ?? avgBpm,
            maxHr: real.maxHr ?? peakHR,
            strain: real.strain ?? strain,
            distanceM: real.distanceM, zonesJSON: real.zonesJSON, notes: real.notes,
            steps: real.steps)
    }
}

// MARK: - Calories

/// HR-based calorie estimation (Keytel 2005 active + revised Harris-Benedict BMR). APPROXIMATE, not medical advice.
public enum Calories {

    /// Whole-day energy split: `restingKcal` is BMR over supported sample intervals, `activeKcal` is energy
    /// above that floor during supported high-HR intervals, `totalKcal` the value persisted in `DailyMetric.activeKcalEst`.
    public struct DayEnergyEstimate: Equatable, Sendable {
        public let restingKcal: Double
        public let activeKcal: Double
        public let observedSeconds: Double

        public var totalKcal: Double { restingKcal + activeKcal }
    }

    struct Coeffs {
        let restingAlpha: Double
        let restingWeight: Double
        let restingHeight: Double  // applied to height in METRES
        let restingAge: Double
        // Keytel 2005 base (fitness-blind) active model: EE(kJ/min) = alpha + hr*HR + wt*W + age*A.
        let workoutHR: Double
        let workoutWeight: Double
        let workoutAge: Double
        let workoutAlpha: Double
        // Keytel 2005 fitness-ADJUSTED model (reads VO2max; the authors' more accurate form): EE(kJ/min) =
        // fitAlpha + fitHR*HR + fitVO2*VO2max + fitWeight*W + fitAge*A. Used only when a resting HR is known
        // (so a Uth VO2max can be derived); otherwise the base model applies. (J. Sports Sci. 23(3), 2005.)
        let fitHR: Double
        let fitVO2: Double
        let fitWeight: Double
        let fitAge: Double
        let fitAlpha: Double
    }

    static let male = Coeffs(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9,
                             restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988,
                             workoutAge: 0.2017, workoutAlpha: -55.0969,
                             fitHR: 0.634, fitVO2: 0.404, fitWeight: 0.394, fitAge: 0.271,
                             fitAlpha: -95.7735)
    static let female = Coeffs(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8,
                               restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263,
                               workoutAge: 0.0740, workoutAlpha: -20.4022,
                               fitHR: 0.450, fitVO2: 0.380, fitWeight: 0.103, fitAge: 0.274,
                               fitAlpha: -59.3954)
    // Nonbinary = the male/female midpoint, as for the base workout* coeffs.
    static let nonbinary = Coeffs(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85,
                                  restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625,
                                  workoutAge: 0.13785, workoutAlpha: -37.74955,
                                  fitHR: 0.542, fitVO2: 0.392, fitWeight: 0.2485, fitAge: 0.2725,
                                  fitAlpha: -77.58445)

    static let activeHRRFraction = 0.30
    /// Whole-day active gate (`estimateDayCalories` only). Keytel 2005 is validated for genuine EXERCISE HR;
    /// applying it to low-intensity daytime HR (~95-110 bpm) across the whole day over-counts by ~1000+
    /// kcal. The bout path keeps the 0.30 detector fraction; the day path gates at 50% HRR.
    static let dayActiveHRRFraction = 0.50
    /// Longest gap over which one daily HR reading may carry RESTING energy: metabolism continues across a
    /// dropout, but a disconnected evening must not bank a night of unobserved resting kcal. ACTIVE energy
    /// is capped much tighter, at the inferred cadence (see `estimateDayEnergy`): a gap is a missing sensor,
    /// never exercise.
    static let dayMaxObservedGapS: Double = 60.0
    static let dayMaxObservedSpanS: Double = 86_400.0
    static let workoutDivisor = 251.04  // 60 s/min × 4.184 kJ/kcal

    static func resolveCoeffs(_ sex: String) -> Coeffs {
        switch sex.lowercased() {
        case "male": return male
        case "female": return female
        case "nonbinary": return nonbinary
        default: return nonbinary
        }
    }

    static func restingKcalPerS(_ c: Coeffs, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let heightM = heightCm / 100.0
        let bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * heightM - c.restingAge * age
        return max(0.0, bmr) / 86_400.0
    }

    /// Uth-Sorensen VO2max estimate (ml/kg/min) = 15.3 * HRmax / HRrest (Uth et al. 2004, Eur. J. Appl.
    /// Physiol. 91). Nil without a usable resting HR, so the base Keytel model applies. Depends only on
    /// HRmax + resting HR, keeping day derivation deterministic.
    // `public`: IntelligenceEngine reads this for the waist-free VO2max fallback (#1391) across the module boundary.
    public static func vo2maxFor(hrmax: Double, restingHR: Double?) -> Double? {
        guard let rhr = restingHR, rhr > 0, hrmax > 0 else { return nil }
        return 15.3 * hrmax / rhr
    }

    /// Active energy rate (kcal/s): the Keytel 2005 fitness-ADJUSTED equation with `vo2max`, else the base
    /// fitness-blind model. HR is capped at HRmax in both.
    static func activeKcalPerS(_ c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double,
                               vo2max: Double? = nil) -> Double {
        let eeKjMin: Double
        if let vo2 = vo2max {
            eeKjMin = c.fitHR * min(hr, hrmax) + c.fitVO2 * vo2 + c.fitWeight * weightKg
                + c.fitAge * age + c.fitAlpha
        } else {
            eeKjMin = c.workoutHR * min(hr, hrmax) + c.workoutWeight * weightKg
                + c.workoutAge * age + c.workoutAlpha
        }
        return max(0.0, eeKjMin) / workoutDivisor
    }

    /// Estimates (kcal, kJ) for a workout bout. Each sample is weighted by the ELAPSED time to the next
    /// (capped at `WorkoutDetector.mergeGapS`), so a sparse stream is counted over real seconds. Valid
    /// ONLY for bouts, whose gaps are motion-gated and <= mergeGapS; the whole-day estimator does not use
    /// it, since its non-gap-filled HR union would credit up to 150 s of active burn to one isolated sample.
    public static func estimateBoutCalories(_ hrSamples: [HRSample],
                                            profile: UserProfile,
                                            hrmax: Double?,
                                            restingHR: Double?) -> (Double, Double) {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)

        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)

        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)
        // Fitness anchor (Uth VO2max) when a resting HR is known; computed once per bout.
        let vo2max = vo2maxFor(hrmax: effHRmax, restingHR: restingHR)

        // Weight each sample by the ACTUAL elapsed time to the next, not a flat 1 s: the rates are per
        // SECOND, so a sparse 5/MG bout undercounted energy (calories collapsing toward ~1 kcal, #137).
        // Each interval is capped at mergeGapS so a wear gap cannot inflate one reading.
        let ordered = hrSamples.sorted { $0.ts < $1.ts }
        var totalKcal = 0.0
        for i in ordered.indices {
            let bpm = Double(ordered[i].bpm)
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, WorkoutDetector.mergeGapS) : 1.0
            } else {
                dur = 1.0   // last sample carries one representative second
            }
            if bpm < activeThreshold {
                totalKcal += restingRate * dur
            } else {
                totalKcal += activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age, vo2max: vo2max) * dur
            }
        }
        return (totalKcal, totalKcal * 4.184)
    }

    /// APPROXIMATE whole-day resting + active energy from the day's HR samples. Resting BMR is integrated
    /// once over capped, supported intervals independent of HR cadence; high-HR intervals add only the
    /// Keytel energy ABOVE that floor, gated at `dayActiveHRRFraction` (50% HRR, not the bout's 30%, which
    /// falls to ~94 bpm and over-counted by ~1000+ kcal).
    ///
    /// Cadence is the median positive timestamp gap, capped at `dayMaxObservedGapS`; each sample carries
    /// energy to the next for at most that cap, so a 30 s sparse stream and a 1 Hz stream covering the
    /// same activity give comparable energy, but a whole disconnect is never credited. Heart rate alone:
    /// not laboratory calorimetry, cloud parity or medical advice.
    public static func estimateDayEnergy(_ hrSamples: [HRSample],
                                         profile: UserProfile,
                                         hrmax: Double?,
                                         restingHR: Double?) -> DayEnergyEstimate {
        if hrSamples.isEmpty {
            return DayEnergyEstimate(restingKcal: 0, activeKcal: 0, observedSeconds: 0)
        }

        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)

        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        // Day-path gate is higher than the bout detector's (see `dayActiveHRRFraction`).
        let activeThreshold = effResting + dayActiveHRRFraction * (effHRmax - effResting)

        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)
        // Fitness anchor (Uth VO2max) when a resting HR is known; constant across the day.
        let vo2max = vo2maxFor(hrmax: effHRmax, restingHR: restingHR)

        // Ties are reachable (hrSample is keyed (deviceId, ts) and the day feed unions devices): only the
        // last of a tied run gets the interval, so order ties by DESCENDING bpm to hand it to the lower
        // reading (conservative), not to the sort's stability, which Swift does not guarantee.
        let ordered = hrSamples.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.bpm > $1.bpm }
        let positiveGaps = zip(ordered, ordered.dropFirst())
            .map { pair in Double(pair.1.ts - pair.0.ts) }
            .filter { $0 > 0 }
            .sorted()
        let nominalSampleS: Double = {
            guard !positiveGaps.isEmpty else { return 1.0 }
            let mid = positiveGaps.count / 2
            let median = positiveGaps.count.isMultiple(of: 2)
                ? (positiveGaps[mid - 1] + positiveGaps[mid]) / 2.0
                : positiveGaps[mid]
            return min(median, dayMaxObservedGapS)
        }()
        let observedSeconds = min(dayMaxObservedSpanS, positiveGaps.reduce(nominalSampleS) {
            $0 + min($1, dayMaxObservedGapS)
        })
        let restingKcal = restingRate * observedSeconds

        var activeKcal = 0.0
        for i in ordered.indices {
            let durationS: Double
            // Active carry is capped at the inferred CADENCE, not the wider resting cap: a 30 s stream
            // carries its full 30 s, a 1 Hz day carries 1 s, and a dropout never credits a minute of exercise.
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                durationS = gap > 0 ? min(gap, nominalSampleS) : 0.0
            } else {
                durationS = nominalSampleS
            }
            let bpm = Double(ordered[i].bpm)
            guard bpm >= activeThreshold else { continue }
            let grossRate = activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax,
                                           weightKg: weightKg, age: age, vo2max: vo2max)
            activeKcal += max(0.0, grossRate - restingRate) * durationS
        }
        return DayEnergyEstimate(restingKcal: restingKcal, activeKcal: activeKcal,
                                 observedSeconds: observedSeconds)
    }

    /// Backward-compatible total-kcal facade for the stored daily metric.
    public static func estimateDayCalories(_ hrSamples: [HRSample],
                                           profile: UserProfile,
                                           hrmax: Double?,
                                           restingHR: Double?) -> Double {
        estimateDayEnergy(hrSamples, profile: profile, hrmax: hrmax,
                          restingHR: restingHR).totalKcal
    }
}
