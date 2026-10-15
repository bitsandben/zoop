import Foundation
import WhoopProtocol

// StrainScorer: cardiovascular load on a 0-100 logarithmic strain ("Effort") scale. An independent
// implementation of published exercise-physiology methods (not WHOOP's proprietary algorithm; not
// medical advice).
//
// The output was historically 0-21; the Effort rescale raises `maxStrain` to 100 only. D = 7201 is
// unchanged, so the curve and its saturation point (TRIMP 7200) are preserved. Metric key stays `strain`.
//
// Pipeline: Karvonen HRR = HRmax - RHR; per-sample %HRR clamped 0..100; TRIMP by Edwards 5-zone
// summation (default; weights 1..5 at 50/60/70/80/90 %HRR x duration) or Banister exponential
// (duration x x x 0.64 x e^(b*x)); then strain = 100 x ln(TRIMP + 1) / ln(D). D belongs to the METHOD
// (see `logMapDenominator(method:sex:)`); reusing one for the other silently rescales the axis (#1545).
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991 (exponential TRIMP,
// b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 - 0.7 x age).

public enum StrainScorer {

    // MARK: - Constants

    /// Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Sparse-stream acceptance (#482/#480): a low-cadence strap (the 5/MG sends live HR only ~every 30 s)
    /// would need ~5 h of wear to reach `minReadings`, so Effort sat un-scored. Also accept once the HR
    /// series SPANS `minSpanSeconds` with a small sample floor. TRIMP still integrates honestly, so this never
    /// fabricates load.
    public static let minSparseReadings: Int = 20
    /// Wall-clock coverage (seconds) that qualifies a sparse stream; matches the dense gate's ~10 min.
    public static let minSpanSeconds: Int = 600
    /// Top of the strain ("Effort") scale.
    public static let maxStrain: Double = 100.0

    /// Top of WHOOP's Day Strain axis, kept beside `maxStrain` so inherited 0-21 values map through one rule.
    public static let whoopMaxStrain: Double = 21.0

    /// Maps a value on WHOOP's 0-21 Day Strain axis onto Zoop's 0-`maxStrain` Effort axis. Multiplies by the
    /// pre-divided ratio to stay bit-identical to the importers' rescale (`value * maxStrain / whoopMaxStrain`
    /// differs by an ULP on about a quarter of inputs).
    public static func effortValue(fromWhoopStrain value: Double) -> Double {
        value * (maxStrain / whoopMaxStrain)
    }

    /// Log-map denominator D: the Edwards daily ceiling (zone weight 5 for 24 h = 7200) plus 1, so it maps
    /// to exactly `maxStrain`.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Banister's daily ceiling: 24 h at delta-HRR = 1.0. SEX-DEPENDENT (exponent `b`), so `strainDenominator`
    /// cannot be reused: the Edwards denominator would sit ~14% (men) / ~32% (women) too high. (#1545)
    static func banisterDailyCeiling(b: Double) -> Double {
        24.0 * 60.0 * 1.0 * banisterScale * exp(b)
    }

    /// The %HRR a waking, sedentary body sits at (the cost of being alive, not training load).
    ///
    /// Banister pays at every intensity, so a desk day would never score zero, while Edwards (first zone at
    /// 50% HRR) scores it exactly zero: a 24 h day at 5% HRR is 0 vs 45 on the shipped constants, i.e. two
    /// axes (#1624). This is the ONE tuned constant here, a judgement not a measurement: low enough to keep
    /// genuine light activity, high enough that ordinary sitting nets to nothing (resting HR is measured
    /// asleep, so a waking body sits above it).
    public static let banisterSedentaryHRR: Double = 0.10

    /// TRIMP per minute at `banisterSedentaryHRR`; the rate subtracted from every day.
    static func banisterBaselineRatePerMinute(b: Double) -> Double {
        banisterScale * banisterSedentaryHRR * exp(b * banisterSedentaryHRR)
    }

    /// Sedentary TRIMP over `minutes`, subtracted from a day's Banister TRIMP so the axis starts where
    /// Edwards' does. Also subtracted from the denominator so the top is unmoved.
    static func banisterBaseline(minutes: Double, b: Double) -> Double {
        banisterBaselineRatePerMinute(b: b) * minutes
    }


    /// The log-map denominator for a method (ceiling + 1 in both cases), so a maximum day maps to exactly `maxStrain`.
    public static func logMapDenominator(method: Method, sex: String) -> Double {
        switch method {
        case .edwards:
            return strainDenominator
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            // Ceiling minus a full day of sedentary baseline, matching what is subtracted from the day (#1624).
            return banisterDailyCeiling(b: b) - banisterBaseline(minutes: 24.0 * 60.0, b: b) + 1.0
        }
    }

    /// Fallback per-sample duration (minutes): 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister coefficients.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    /// TRIMP accumulation method.
    public enum Method: Sendable, Hashable { case edwards, banister }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 - age; last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0-5) from unclamped %HRR.
    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Longest span (minutes) a single reading may be credited with. Without a ceiling one zone-5 sample
    /// before a dropout would invent hours of effort. 2 min is 4x the sparsest real cadence (the 5/MG's ~30 s).
    public static let maxSampleGapMin: Double = 2.0

    /// The one Effort figure every read-out on Today must show (#1001): the MAX of `stored` (the daily row,
    /// rewritten only by the heavy daily pass) and `live` (today's in-progress recompute over the raw HR
    /// stream). Past days have no live value and use the row.
    ///
    /// MAX, not "prefer live": Effort accrues and must never visibly drop, and the live recompute can
    /// under-read when HR is sparse or a logged workout's load is not in the raw stream (#489/#506).
    /// Shared so the ring, Key Metrics tile and chart badge cannot drift apart.
    public static func effectiveEffort(live: Double?, stored: Double?) -> Double? {
        guard let live else { return stored }
        guard let stored else { return live }
        if live == 0.0 && stored == 0.0 { return 0.0 }
        return Swift.max(live, stored)
    }

    /// Infers per-sample duration (minutes) from the first two timestamps; 1 s when fewer than two samples or
    /// coincident timestamps. No production caller (TRIMP uses `sampleDurationsMinutes`, #950); kept only so the
    /// uniform-identity regression test can compare against the shipped formula.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    /// Per-sample durations (minutes): each reading covers the gap to the NEXT one, clamped to
    /// `maxSampleGapMin`; the last reuses the gap before it (#950). The HR stream is not uniformly spaced
    /// (live ~1 s, banked 5/MG ~30 s, dropouts), so one duration inferred from the first two timestamps
    /// made a workout window and its containing day score on different factors. A uniform series is unchanged.
    static func sampleDurationsMinutes(_ hr: [HRSample]) -> [Double] {
        if hr.isEmpty { return [] }
        if hr.count == 1 { return [fallbackSampleMin] }
        var out: [Double] = []
        out.reserveCapacity(hr.count)
        for i in 0..<(hr.count - 1) {
            let deltaS = abs(Double(hr[i + 1].ts - hr[i].ts))
            let minutes = deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
            out.append(min(minutes, maxSampleGapMin))
        }
        out.append(out[out.count - 1])   // the final reading has no successor; reuse the gap before it
        return out
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             durations: [Double]) -> Double {
        var acc = 0.0
        for i in hr.indices {
            acc += Double(zoneWeight(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve))
                * durations[i]
        }
        return acc
    }

    /// Minutes in each Edwards zone, indexed by zone weight: `[0]` is time BELOW zone 1, `[1...5]` zones 1-5.
    ///
    /// Sums to the CREDITED time TRIMP integrates over, not wall-clock wear: each reading is clamped to
    /// `maxSampleGapMin`, so a ten-minute dropout contributes two minutes. The caller must pass
    /// `hrReserve > 0` since `zoneWeight` divides by it (#2438).
    static func zoneMinutes(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                            durations: [Double]) -> [Double] {
        var out = [Double](repeating: 0.0, count: 6)
        for i in hr.indices {
            out[zoneWeight(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve)] += durations[i]
        }
        return out
    }

    /// - Parameter floorRatePerMinute: per-minute rate treated as "no effort", subtracted from EVERY sample
    ///   and floored at zero (#1624). Zero (default) is the unfloored Banister recipe. Applied per SAMPLE,
    ///   not off the total, so a quiet day's deficit cannot erase intermittent effort done on top.
    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              durations: [Double], b: Double,
                              floorRatePerMinute: Double = 0.0) -> Double {
        var acc = 0.0
        for i in hr.indices {
            let x = pctHRR(Double(hr[i].bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 {
                let rate = x * banisterScale * exp(b * x)
                acc += durations[i] * max(rate - floorRatePerMinute, 0.0)
            }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Maps accumulated TRIMP onto [0, 100] via 100 x ln(TRIMP+1) / ln(D), 2 dp. TRIMP <= 0, or D <= 1 / NaN
    /// (outside the map's domain), gives 0. The default D is Edwards': a Banister TRIMP needs its own
    /// denominator, so prefer `strain(...)` or `logMapDenominator(method:sex:)` (#1545).
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        // D <= 1 (and NaN) is outside the domain: ln(1) = 0 divides to infinity, ln(D) < 0 flips the sign.
        guard denominator > 1 else { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrates D from (TRIMP, reference_strain) pairs via the through-origin least-squares line
    /// ln(D) = maxStrain x sum(x^2) / sum(xy), x = ln(TRIMP+1). Throws with fewer than 2 usable pairs or if degenerate.
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain / "Effort" (0-100) from an HR series. APPROXIMATE. Nil when there is not yet
    /// enough data (fewer than `minReadings` samples AND less than `minSpanSeconds` of coverage, #482) or
    /// when maxHR <= restingHR.
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm); defaults to 220 - defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator.
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: "male"/"female"; selects the Banister coefficient.
    ///   - denominator: log-map D; nil resolves to the one that belongs to `method`.
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .edwards,
                              sex: String = "male",
                              denominator: Double? = nil,
                              // Optional diagnostic sink; the line is built only when supplied. Supplying one
                              // BYPASSES the memo (see the guard below), else a cache hit would never emit.
                              diag: ((String) -> Void)? = nil,
                              day: String = "") -> Double? {
        // Resolve BEFORE the memo key is built, or a Banister request would be cached under Edwards' denominator.
        let resolvedDenominator = denominator ?? logMapDenominator(method: method, sex: sex)
        // Memoized (#707): TRIMP is hit once per day by the scoring loop and again on every live-HR tick from
        // Today. Keyed on the HR fingerprint + every scalar steering the score.
        let key = StrainKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            maxHR: maxHR, restingHR: restingHR, method: method,
            sexF: sex.lowercased().hasPrefix("f"), denom: resolvedDenominator)
        // A diagnostic request bypasses the memo: Today's sinkless reads have already cached the answer, and
        // a cache hit never reaches the code that emits.
        guard diag == nil else {
            return strainUncached(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex,
                                  denominator: resolvedDenominator, diag: diag, day: day)
        }
        return strainCache.value(key) {
            strainUncached(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex,
                           denominator: resolvedDenominator, diag: nil, day: day)
        }
    }

    /// One line naming WHERE the day's HRmax came from and what the day's own heart rate reached (#2438 step 0).
    /// `hrmaxSource` is the branch the CALLER took ("provided" splits into manual override vs Tanaka); `strain`
    /// receives an HRmax with its provenance already discarded. Changes no score. No PII.
    public static func dayCalibrationLine(day: String, hrmax: Double?, hrmaxSource: String,
                                          tanaka: Double?, observedPeak: Double?,
                                          restingHR: Double) -> String {
        // Shares WorkoutDetector's formatters so a day line and a bout line round the same way.
        var out = "effort calib day=\(day) hrmax=\(WorkoutDetector.round0(hrmax))"
        out += " src=\(hrmaxSource) tanaka=\(WorkoutDetector.round0(tanaka))"
        out += " peak=\(WorkoutDetector.round0(observedPeak)) rhr=\(WorkoutDetector.round0(restingHR))"
        return out
    }

    /// The ` sustained=` field appended to `dayCalibrationLine`: the day's peak held across consecutive
    /// samples, so a run of lines shows how much of each `peak` was a single sample. nil renders as `nil`, not 0.
    public static func sustainedPeakField(_ sustainedPeak: Double?) -> String {
        " sustained=\(WorkoutDetector.round0(sustainedPeak))"
    }

    /// Consecutive samples a `sustained` peak must hold for, and the span they must fit in.
    public static let sustainedPeakSamples = 5
    public static let sustainedPeakWindowS = 60

    /// The highest bpm that `sustainedPeakSamples` consecutive samples all reached within `sustainedPeakWindowS`
    /// seconds, or nil when no run is that dense (#2438).
    ///
    /// On ring days the raw daily maximum is nearly always one isolated sample (above the age formula on 58 of
    /// 60 days, this value on none), so a rule read off the raw peak would raise HRmax from artefacts. Uses the
    /// minimum over each run, not the mean, so one spike among ordinary samples cannot lift it; nil rather than
    /// a fallback to the raw peak.
    public static func sustainedPeak(_ hr: [HRSample],
                                     samples: Int = sustainedPeakSamples,
                                     windowS: Int = sustainedPeakWindowS) -> Double? {
        guard samples > 0, hr.count >= samples else { return nil }
        // Ordered by (ts, bpm): Swift's sort is not stable, so ties at one second could form different runs.
        let sorted = hr.sorted { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
        var best: Int?
        for i in 0 ... (sorted.count - samples) {
            let last = i + samples - 1
            guard sorted[last].ts - sorted[i].ts <= windowS else { continue }
            let held = sorted[i ... last].lazy.map { $0.bpm }.min() ?? sorted[i].bpm
            best = max(best ?? held, held)
        }
        return best.map(Double.init)
    }

    /// The ` span=` field appended after `sustained=`: seconds covered by the run behind that value. nil renders as `nil`.
    public static func sustainedPeakSpanField(_ spanS: Int?) -> String {
        " span=\(spanS.map(String.init) ?? "nil")"
    }

    /// The seconds covered by the run that sets `sustainedPeak`, or nil when that is nil.
    ///
    /// `sustainedPeak` bounds a run's span from above only (4 s of dense HR vs 57 s of sparse HR gave the same
    /// value on one ring). Among runs reaching the same value, the longest span wins; ordering matches
    /// `sustainedPeak` so both fields describe the same run.
    public static func sustainedPeakSpan(_ hr: [HRSample],
                                         samples: Int = sustainedPeakSamples,
                                         windowS: Int = sustainedPeakWindowS) -> Int? {
        guard samples > 0, hr.count >= samples else { return nil }
        let sorted = hr.sorted { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
        var best: (held: Int, span: Int)?
        for i in 0 ... (sorted.count - samples) {
            let last = i + samples - 1
            let span = sorted[last].ts - sorted[i].ts
            guard span <= windowS else { continue }
            let held = sorted[i ... last].lazy.map { $0.bpm }.min() ?? sorted[i].bpm
            if let b = best, (b.held, b.span) >= (held, span) { continue }
            best = (held, span)
        }
        return best?.span
    }

    /// One line naming what an Effort score was computed FROM, or why it could not be. Without it a log could
    /// not distinguish "measured, calm day" from "could not measure" (`workout detect` is bout detection and
    /// answers a different question). `enough` is the `strain` gate: dense (>= minReadings) OR sparse-but-sustained;
    /// `trimp` and `strain` are absent when the gate refused.
    public static func scoreFunnelLine(day: String, hrSamples: Int, enough: Bool,
                                       maxHR: Double, maxHRProvided: Bool, restingHR: Double,
                                       method: Method, trimp: Double?, strain: Double?,
                                       zoneMinutes: [Double]? = nil) -> String {
        func r1(_ v: Double) -> String { String(format: "%.1f", v) }
        // Built by appending: one `+` chain of interpolations blew the type-checker budget (#1767).
        let src: String = maxHRProvided ? "provided" : "default"
        let trimpText: String = trimp.map(r1) ?? "n/a"
        let strainText: String = strain.map(r1) ?? "n/a"
        var out = "effort score day=\(day) hr=\(hrSamples) enough=\(enough)"
        out += " hrMax=\(r1(maxHR))(\(src))"
        out += " rhr=\(r1(restingHR)) reserve=\(r1(maxHR - restingHR))"
        // Interpolating the case yields "edwards"/"banister", matching Kotlin's `method.name.lowercase()`.
        out += " method=\(method)"
        out += " trimp=\(trimpText) strain=\(strainText)"
        // Per-zone minutes go last so earlier fields keep their position. Absent rather than zeroed when
        // the reserve is invalid: six zeros would read as a day spent entirely below zone 1.
        if let zones = zoneMinutes, zones.count == 6 {
            for i in 0..<6 { out += " z\(i)=\(r1(zones[i]))" }
        } else {
            out += " zones=n/a"
        }
        return out
    }

    /// Key folds `sex` to the single bit the recipe reads (`hasPrefix("f")`) so "female"/"f"/"F" all hit.
    private struct StrainKey: Hashable {
        let hr: StreamFingerprint
        let maxHR: Double?; let restingHR: Double; let method: Method
        let sexF: Bool; let denom: Double
    }
    private static let strainCache = AnalyticsMemoCache<StrainKey, Double?>(capacity: 48)

    private static func strainUncached(_ hr: [HRSample], maxHR: Double?, restingHR: Double,
                                       method: Method, sex: String, denominator: Double,
                                       diag: ((String) -> Void)? = nil, day: String = "") -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Dense stream (>= minReadings) OR sparse-but-sustained spanning >= minSpanSeconds (#482).
        let enoughData: Bool
        if hr.count >= minReadings {
            enoughData = true
        } else if hr.count >= minSparseReadings {
            let tss = hr.map { $0.ts }
            enoughData = ((tss.max() ?? 0) - (tss.min() ?? 0)) >= minSpanSeconds
        } else {
            enoughData = false
        }
        if !enoughData || effMax <= restingHR {
            // nil and 0.0 on a calm day look identical on the ring; only one is a measurement.
            diag?(scoreFunnelLine(day: day, hrSamples: hr.count, enough: enoughData, maxHR: effMax,
                                  maxHRProvided: maxHR != nil, restingHR: restingHR, method: method,
                                  trimp: nil, strain: nil))
            return nil
        }

        let durations = sampleDurationsMinutes(hr)
        let hrReserve = effMax - restingHR

        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            // Excess over the sedentary baseline for the same span, floored at zero; else a desk day scores ~45 (#1624).
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                  durations: durations, b: b,
                                  floorRatePerMinute: banisterBaselineRatePerMinute(b: b))
        case .edwards:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 durations: durations)
        }
        let scored = trimpToStrain(trimp, denominator: denominator)
        // Walked only when a sink is attached (a second O(n) pass). `hrReserve` is safe: the refusal path
        // already returned for `effMax <= restingHR`. Emitted under BOTH methods: zones describe what the
        // day was, not how it was scored (#2438).
        let zones: [Double]? = diag == nil ? nil
            : zoneMinutes(hr, restingHR: restingHR, hrReserve: hrReserve, durations: durations)
        diag?(scoreFunnelLine(day: day, hrSamples: hr.count, enough: enoughData, maxHR: effMax,
                              maxHRProvided: maxHR != nil, restingHR: restingHR, method: method,
                              trimp: trimp, strain: scored, zoneMinutes: zones))
        return scored
    }
}
