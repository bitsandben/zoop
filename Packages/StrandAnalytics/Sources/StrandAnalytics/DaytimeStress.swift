import Foundation
import WhoopProtocol

// DaytimeStress.swift - an intraday (hour-by-hour) read of the same autonomic stress proxy the
// daily Stress monitor shows, computed from the day's banked HR and R-R.
//
// For each waking hour: mean HR (up = stress) and RMSSD over clean R-R (down = stress), z-scored
// against a reference (see `ScoringMode`), then squashed onto 0-3 with stress = 3/(1+e^-raw),
// the same bands as the daily score.
//
// "Sustained high stress" is conservative: the most recent `sustainedHours` covered hours must all
// sit in the HIGH band. It drives a passive Breathe suggestion, never a notification.
// Approximate and non-clinical: an hour with too little data is `.noData`, never invented.

public enum DaytimeStress {

    // MARK: - Tunables

    /// Minimum HR samples in an hour before its mean HR is trusted (~5 min at 1 Hz).
    public static let minHourHRSamples: Int = 300
    /// Bucket width in seconds (one hour).
    public static let bucketSeconds: Int = 3_600
    /// How far the display timeline slides its window between points.
    ///
    /// The scored unit stays a full `bucketSeconds` hour; this only sets how often it is re-read, so a
    /// half-step gives two points an hour, each still an hour of data. Shrinking `bucketSeconds` would
    /// change scoring (the calm reference is a quartile across buckets, the post-exercise shadow looks
    /// back one bucket, `sustainedHours` counts them). Half keeps every on-the-hour point where the
    /// hourly pass put it while doubling resolution.
    public static let timelineStepSeconds: Int = 1_800
    /// Smallest across-hour HR spread (bpm) the day-relative mode divides by.
    public static let dayRelativeMinSDHR: Double = 5.0
    /// Smallest across-hour RMSSD spread (ms) the day-relative mode divides by.
    public static let dayRelativeMinSDRMSSD: Double = 8.0

    /// Band floor for "high" on the shared 0-3 scale (matches StressBand .high).
    public static let highBandFloor: Double = 2.0
    /// Consecutive most-recent covered hours that must all be HIGH to flag sustained stress.
    public static let sustainedHours: Int = 3
    /// First/last local hour-of-day treated as "waking" (06:00-22:00).
    public static let wakingStartHour: Int = 6
    public static let wakingEndHour: Int = 22

    // MARK: - Motion gate
    //
    // HR and HRV alone cannot separate stress from exertion. When the caller supplies gravity
    // (wrist accelerometer), a substantially ambulatory hour is masked (`level == nil`,
    // `maskedForActivity == true`) and excluded from the calm reference and coverage totals. No
    // gravity means no masking. Orthogonal to `ScoringMode`: masking decides which hours score, the
    // mode decides what they score against.

    /// An hour is exertion, not stress, when at least this fraction of its records is ambulatory
    /// (activity above `WorkoutDetector.motionThreshold`, 0.20 L2-g: desk ~0.05-0.10 g, walking
    /// ~0.2-0.4 g). Range (0, 1].
    public static let activityMaskFraction: Double = 0.30
    /// Post-exercise shadow: HR stays elevated after exertion, so the one hour following an ambulatory
    /// hour is also masked while its mean HR is still this many bpm above the calm reference. One hour
    /// deep (not chained through prior shadows) so a tense afternoon after a workout is not masked away.
    public static let postActivityShadowBPM: Double = 8.0

    /// Validated (26-day Oura-reference correlation, HR-only): a daytime-HR elevation of ~15 bpm over a
    /// pooled rolling baseline (10th-percentile daytime HR, ~65 bpm in the reference set) is where
    /// elevated HR starts reading as Oura-comparable "high" stress (r~0.6). A per-day baseline scored
    /// worse (r 0.43-0.53) because an all-day elevated day lifts its own floor, hence `.baselineRelative`
    /// uses `Baselines`' cross-day EWMA. Tuning seam: HR+HRV is expected to beat r~0.6, so re-validate
    /// then. See `marginToSigma`.
    public static let baselineRelativeHighMarginBPM: Double = 15.0

    /// Whether the personal daytime-RMSSD baseline feeds the live 0-3 score. `false`: `.baselineRelative`
    /// scores HR-only, the channel the r~0.6 margin was validated on. The RMSSD pipeline
    /// (`dayDaytimeAggregate`, `foldDaytimeBaselines`, `daytime_rmssd`, `rawScore`'s HRV term) is built
    /// and tested but stays out of the live score until validated.
    ///
    /// Why off (real WHOOP data, 2026-07): wrist daytime RMSSD is artifact-dominated (hourly values
    /// swing ~40-430 ms with posture, motion and talking), and `rawScore` weights its z equally with HR,
    /// so one artifact hour can swing the score by +/-3. Flip only once HR+RMSSD is shown to beat
    /// HR-only against an Oura-style stress reference.
    public static let daytimeRMSSDScoringEnabled: Bool = false

    // MARK: - Scoring mode

    /// Where each hour's calm reference and spread come from. Everything else (bucketing, waking
    /// filter, squash, sustained-high, high-stress minutes) is identical between modes.
    ///
    /// Related lenses: the daily level (`DaytimeStress.daily`) compares last night's resting HR / HRV to
    /// a trailing 30-day mean/SD; the Test Centre HRV card (`StressIndex`, `HRVFreqDomain`) is
    /// today-only with no baseline. `.baselineRelative` is an hourly breakdown of today from daytime HR
    /// and RMSSD against a personal cross-day baseline. Daytime HR runs warmer than nocturnal resting
    /// HR, so it needs its own baseline (`daytime_hr` / `daytime_rmssd`); reusing the nightly ones would
    /// over-read stress.
    public enum ScoringMode: Equatable, Sendable {
        /// Default. Each hour is z-scored against this day's own typical-hour reference (`typicalReference`),
        /// with no personal history needed.
        case dayRelative

        /// Oura-style: each hour is z-scored against the personal rolling baseline for daytime HR (and,
        /// when available, daytime RMSSD), built by the caller via `Baselines.update` / `foldHistory` with
        /// `Baselines.daytimeHRCfg` / `daytimeRMSSDCfg` from each past day's 10th-percentile daytime HR.
        ///
        /// The HR reference is `hr.baseline`, but the HIGH threshold is a roughly fixed bpm margin over it
        /// (`baselineRelativeHighMarginBPM`), not scaled by `hr.spread`.
        ///
        /// `rmssd` is nil when no personal RMSSD baseline exists (e.g. an imported day with no R-R); the
        /// read then falls back to HR-only and flags `Result.hrOnlyFallback`. A present RMSSD term still
        /// scales by `rmssd.spread` via `Baselines.sigma`.
        case baselineRelative(hr: BaselineState, rmssd: BaselineState?)
    }

    // MARK: - Output

    /// One hour of the daytime timeline. `level` is the shared 0-3 stress proxy, or nil when the hour
    /// had too little signal to score.
    public struct HourPoint: Equatable, Sendable {
        /// Hour-of-day on the local clock (0-23).
        public let hour: Int
        public let startTs: Int
        public let level: Double?
        public let meanHR: Double?
        public let rmssd: Double?
        /// True when the hour was left unscored because it was ambulatory (exertion), so `level == nil`
        /// here means "masked as activity", not "no data".
        public let maskedForActivity: Bool

        public var hasData: Bool { level != nil }

        public init(hour: Int, startTs: Int, level: Double?, meanHR: Double?, rmssd: Double?,
                    maskedForActivity: Bool = false) {
            self.hour = hour
            self.startTs = startTs
            self.level = level
            self.meanHR = meanHR
            self.rmssd = rmssd
            self.maskedForActivity = maskedForActivity
        }
    }

    /// The full daytime read: the hourly timeline plus the sustained-high summary.
    public struct Result: Equatable, Sendable {
        /// Waking-hour timeline, earliest to latest; hours with no signal carry `level == nil`.
        public let hours: [HourPoint]
        /// True when the most recent `sustainedHours` scored hours all sit in the HIGH band.
        public let sustainedHigh: Bool
        public let sustainedRun: Int
        public let dayMean: Double?
        public let peak: HourPoint?
        /// Waking hours left unscored because they were ambulatory (motion gate); 0 without gravity.
        public let activityMaskedHours: Int
        /// Minutes across scored waking hours at or above `highBandFloor`: the Oura-comparable "time in
        /// high stress". Hourly grain vs Oura's ~5 minutes, so a coarse approximation. 0 for `.empty`.
        public let highStressMinutes: Int
        /// True when `.baselineRelative` was requested but no personal RMSSD baseline existed, so the read
        /// fell back to HR-only. Always false in `.dayRelative` and for `.empty`.
        public let hrOnlyFallback: Bool

        /// Display-only sliding read of the same day: `hours` plus a point every `timelineStepSeconds`,
        /// each an hour window scored against the same reference. Defaults to `hours`.
        ///
        /// Not the input to anything that counts hours (`sustainedHigh`, `highStressMinutes`, `dayMean`,
        /// `peak` stay on the non-overlapping `hours`), since overlap would count a minute twice.
        public let timeline: [HourPoint]

        public init(hours: [HourPoint], sustainedHigh: Bool, sustainedRun: Int,
                    dayMean: Double?, peak: HourPoint?, activityMaskedHours: Int = 0,
                    highStressMinutes: Int = 0, hrOnlyFallback: Bool = false,
                    timeline: [HourPoint]? = nil) {
            self.hours = hours
            self.timeline = timeline ?? hours
            self.sustainedHigh = sustainedHigh
            self.sustainedRun = sustainedRun
            self.dayMean = dayMean
            self.peak = peak
            self.activityMaskedHours = activityMaskedHours
            self.highStressMinutes = highStressMinutes
            self.hrOnlyFallback = hrOnlyFallback
        }

        public var scored: [HourPoint] { hours.filter { $0.level != nil } }

        public static let empty = Result(hours: [], sustainedHigh: false, sustainedRun: 0,
                                         dayMean: nil, peak: nil, activityMaskedHours: 0,
                                         highStressMinutes: 0, hrOnlyFallback: false)
    }

    // MARK: - Shared stress math (the hourly curve and the daily level both use these)

    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score; HR up and HRV down both push it positive, as in the daily score.
    static func rawScore(hr: Double?, meanHR: Double?, sdHR: Double,
                         rmssd: Double?, meanRMSSD: Double?, sdRMSSD: Double) -> Double {
        var sum = 0.0
        if let h = hr, let m = meanHR, sdHR > 0.0001 {
            sum += (h - m) / sdHR              // HR up = stress
        }
        if let r = rmssd, let m = meanRMSSD, sdRMSSD > 0.0001 {
            sum += (m - r) / sdRMSSD           // HRV (RMSSD) down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0-3 (baseline 0 gives 1.5), shared with the daily level.
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    /// Solves for the spread `sd` such that a raw elevation of `marginBPM` squashes to exactly `band`:
    /// `band = 3 / (1 + e^(-marginBPM/sd))`. Translates `baselineRelativeHighMarginBPM` into the `sd`
    /// the shared curve expects, so "baseline + margin" lands on `band` by construction. Falls back
    /// defensively if `band` is outside the open range (0, 3).
    static func marginToSigma(marginBPM: Double, atBand band: Double) -> Double {
        let ratio = 3.0 / band - 1.0
        guard ratio > 0, marginBPM > 0 else { return max(marginBPM, 1e-9) }
        return marginBPM / (-log(ratio))
    }

    /// The bucket a local timestamp falls in for a grid offset by `phase` (0 is the on-the-hour grid;
    /// `timelineStepSeconds` is the same grid slid forward).
    private static func bucketOf(_ localTs: Int, phase: Int) -> Int {
        floorDiv(localTs - phase, bucketSeconds) * bucketSeconds + phase
    }

    // MARK: - Public API


    /// Builds the daytime stress timeline from a day's banked HR and R-R.
    ///
    /// - Parameters:
    ///   - hr: the day's `[HRSample]` (any order).
    ///   - rr: the day's `[RRInterval]`.
    ///   - gravity: the day's `[GravitySample]` for the motion gate; empty means nothing is masked.
    ///   - tzOffsetSeconds: seconds east of UTC, placing buckets on the local clock. Defaults to UTC.
    ///   - mode: `.dayRelative` (default) or `.baselineRelative` (vs a personal rolling baseline).
    ///   - includeTimeline: also compute `Result.timeline`. Opt-in: the Stress screen draws its own
    ///     timeline and would pay a second bucketing pass plus an RMSSD per extra window.
    ///
    /// Returns `.empty` when no hour has enough HR to score.
    public static func analyze(hr: [HRSample], rr: [RRInterval],
                               gravity: [GravitySample] = [],
                               tzOffsetSeconds: Int = 0,
                               mode: ScoringMode = .dayRelative,
                               includeTimeline: Bool = false) -> Result {
        // Memoized (#707): bucketing a full day of HR + R-R and an RMSSD per hour is expensive and the
        // Stress view re-evaluates `body`. Key on the stream fingerprints, tz offset and mode; for
        // baseline-relative the mode key folds in only (baseline, spread), the fields that change the score.
        let modeKey: ModeKey
        switch mode {
        case .dayRelative:
            modeKey = .dayRelative
        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            modeKey = .baselineRelative(hrBaseline: hrBaseline.baseline, hrSpread: hrBaseline.spread,
                                        rmssdBaseline: rmssdBaseline?.baseline, rmssdSpread: rmssdBaseline?.spread)
        }
        let key = StressKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            // Fold all three axes into one quant so different gravity streams cannot share a key.
            gravity: StreamFingerprint.of(gravity, ts: { $0.ts }, quant: {
                Int(($0.x * 128).rounded()) &+ Int(($0.y * 128).rounded()) &* 257
                    &+ Int(($0.z * 128).rounded()) &* 66_049
            }),
            // includeTimeline is part of the key: otherwise a screen read (false) would seed the cache and a
            // later widget read (true) would silently lose the sliding series.
            tz: tzOffsetSeconds, mode: modeKey, includeTimeline: includeTimeline)
        return analyzeCache.value(key) {
            analyzeUncached(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tzOffsetSeconds,
                            mode: mode, includeTimeline: includeTimeline)
        }
    }

    private struct StressKey: Hashable {
        let hr: StreamFingerprint; let rr: StreamFingerprint; let gravity: StreamFingerprint
        let tz: Int; let mode: ModeKey; let includeTimeline: Bool
    }

    /// Hashable fingerprint of `ScoringMode` for the memo cache: only `baseline` / `spread` can change
    /// the score.
    private enum ModeKey: Hashable {
        case dayRelative
        case baselineRelative(hrBaseline: Double, hrSpread: Double, rmssdBaseline: Double?, rmssdSpread: Double?)
    }

    private static let analyzeCache = AnalyticsMemoCache<StressKey, Result>(capacity: 8)

    private static func analyzeUncached(hr: [HRSample], rr: [RRInterval],
                                        gravity: [GravitySample],
                                        tzOffsetSeconds: Int, mode: ScoringMode,
                                        includeTimeline: Bool) -> Result {
        guard !hr.isEmpty else { return .empty }

        // 1) Bucket HR and R-R into local hour-of-day buckets keyed by the floored bucket start.
        func hrBuckets(_ phase: Int) -> [Int: [Double]] {
            var m: [Int: [Double]] = [:]
            for s in hr { m[bucketOf(s.ts + tzOffsetSeconds, phase: phase), default: []].append(Double(s.bpm)) }
            return m
        }
        func rrBuckets(_ phase: Int) -> [Int: [Double]] {
            var m: [Int: [Double]] = [:]
            for s in rr { m[bucketOf(s.ts + tzOffsetSeconds, phase: phase), default: []].append(Double(s.rrMs)) }
            return m
        }
        let hrByBucket = hrBuckets(0)
        let rrByBucket = rrBuckets(0)

        // 2) Per-hour mean HR and RMSSD (via the shared HRV cleaner, so ectopic beats can't fabricate
        //    variability). An hour under minHourHRSamples is left unscored, never invented.
        struct HourAgg { let bucket: Int; let meanHR: Double?; let rmssd: Double?; let nHR: Int }
        func aggregate(_ hrGrid: [Int: [Double]], _ rrGrid: [Int: [Double]]) -> [HourAgg] {
            let ordered = hrGrid.keys.sorted()
            var out: [HourAgg] = []
            out.reserveCapacity(ordered.count)
            for b in ordered {
                let hrs = hrGrid[b] ?? []
                let mHR = hrs.count >= minHourHRSamples ? mean(hrs) : nil
                let rrRes = HRVAnalyzer.analyze(rawRR: rrGrid[b] ?? [])
                out.append(HourAgg(bucket: b, meanHR: mHR, rmssd: rrRes.rmssd, nHR: hrs.count))
            }
            return out
        }
        let aggs = aggregate(hrByBucket, rrByBucket)

        // 2b) Motion gate: an hour is ambulatory when at least `activityMaskFraction` of its records clear
        //     `WorkoutDetector.motionThreshold`, reusing the activity series the sedentary and workout
        //     detectors trust. Derived once and re-bucketed per grid (it walks the whole day's gravity).
        let activity = gravity.isEmpty ? [] : WorkoutDetector.activitySeries(gravity)
        func activeFractions(_ phase: Int) -> [Int: Double] {
            var out: [Int: Double] = [:]
            guard !activity.isEmpty else { return out }
            var counts: [Int: (active: Int, total: Int)] = [:]
            for p in activity {
                let bucket = bucketOf(p.ts + tzOffsetSeconds, phase: phase)
                var e = counts[bucket] ?? (0, 0)
                e.total += 1
                if p.intensity > WorkoutDetector.motionThreshold { e.active += 1 }
                counts[bucket] = e
            }
            for (b, e) in counts where e.total > 0 {
                out[b] = Double(e.active) / Double(e.total)
            }
            return out
        }
        let activeFracByBucket = activeFractions(0)
        func isAmbulatory(_ bucket: Int) -> Bool {
            (activeFracByBucket[bucket] ?? 0) >= activityMaskFraction
        }

        // 3) Reference point and spread per signal, from `mode`; only this differs between modes.
        let refHR: Double?
        let sdHR: Double
        let refRMSSD: Double?
        let sdRMSSD: Double
        let hrOnlyFallback: Bool
        switch mode {
        case .dayRelative:
            // Day-relative reference from WAKING hours only. Sleep is the lowest-HR / highest-HRV stretch and
            // the window starts at local midnight, so including night hours would drag the anchor beneath every
            // waking hour and trip the sustained-high Breathe nudge. Ambulatory hours are excluded too so
            // exertion does not lift the anchor or inflate the spread.
            let referenceAggs = aggs.filter { isWakingHour($0.bucket) && !isAmbulatory($0.bucket) }
            let hrMeans = referenceAggs.compactMap { $0.meanHR }
            let rmssdVals = referenceAggs.compactMap { $0.rmssd }
            // Anchor on the day's typical waking hour (median), not the calm quartile: the curve puts the
            // reference itself at 1.5, so a calm-quartile anchor made an ordinary hour read "high".
            refHR = typicalReference(hrMeans)
            refRMSSD = typicalReference(rmssdVals)
            // Floored spreads: early in the day or on an even day the across-hour SD can be a couple of bpm,
            // squashing an ordinary rise to ~2.9. The floors keep a z of 1 at a meaningful change.
            sdHR = max(std(hrMeans, mean: mean(hrMeans)), dayRelativeMinSDHR)
            sdRMSSD = max(std(rmssdVals, mean: mean(rmssdVals)), dayRelativeMinSDRMSSD)
            hrOnlyFallback = false

        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            // Personal cross-day baseline folded by the caller (see `ScoringMode`). Ambulatory hours are
            // masked in step 4, so the external reference needs no exclusion.
            refHR = hrBaseline.baseline
            // Validated tuning, not `Baselines.sigma(hrBaseline)`: a roughly fixed bpm margin over the personal
            // floor matched Oura best. `marginToSigma` makes `refHR + baselineRelativeHighMarginBPM` land on
            // `highBandFloor`.
            sdHR = Self.marginToSigma(marginBPM: baselineRelativeHighMarginBPM, atBand: highBandFloor)
            if let rmssdBaseline {
                refRMSSD = rmssdBaseline.baseline
                // No validated RMSSD margin yet: scale by the person's own spread.
                sdRMSSD = Baselines.sigma(rmssdBaseline)
                hrOnlyFallback = false
            } else {
                // No personal RMSSD baseline: `rawScore` skips a nil meanRMSSD, so this degrades to HR-only,
                // flagged in the output.
                refRMSSD = nil
                sdRMSSD = 0
                hrOnlyFallback = true
            }
        }

        // 4) Score each waking-hour bucket on the shared 0-3 curve. Takes the bucket grid as a parameter so
        //    the on-the-hour and half-step passes share one scoring expression.
        func scoreGrid(_ gridAggs: [HourAgg], _ activeFrac: [Int: Double]) -> [HourPoint] {
            func ambulatory(_ bucket: Int) -> Bool {
                (activeFrac[bucket] ?? 0) >= activityMaskFraction
            }
            var points: [HourPoint] = []
            points.reserveCapacity(gridAggs.count)
            for a in gridAggs {
            guard isWakingHour(a.bucket) else { continue }
            let hourOfDay = floorDiv(a.bucket, bucketSeconds) % 24
            // Wall-clock bucket start (undo the local shift).
            let wallStart = a.bucket - tzOffsetSeconds
            // Motion gate: an ambulatory hour, or the shadow hour whose HR hasn't recovered to the calm
            // reference, is exertion and masked rather than read as stress. Only an hour that had a reading
            // counts as masked; a no-HR hour is plain `.noData`.
            let shadow = ambulatory(a.bucket - bucketSeconds)
                && a.meanHR != nil && refHR != nil && a.meanHR! > refHR! + postActivityShadowBPM
            let masked = a.meanHR != nil && (ambulatory(a.bucket) || shadow)
            // Score only when HR cleared the count gate and the hour was not motion-masked (RMSSD enriches it).
            let level: Double? = (a.meanHR != nil && !masked)
                ? squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: sdHR,
                                  rmssd: a.rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD))
                : nil
            points.append(HourPoint(hour: hourOfDay, startTs: wallStart,
                                    level: level, meanHR: a.meanHR, rmssd: a.rmssd,
                                    maskedForActivity: masked))
            }
            return points
        }
        let points = scoreGrid(aggs, activeFracByBucket)
        let activityMaskedHours = points.reduce(0) { $0 + ($1.maskedForActivity ? 1 : 0) }

        // 4b) Half-step display timeline: the same hour window re-read every `timelineStepSeconds` against
        //     the same references, merged with the on-the-hour points. Nothing that counts hours reads it.
        let timeline: [HourPoint] = {
            guard includeTimeline,
                  timelineStepSeconds > 0, timelineStepSeconds < bucketSeconds else { return points }
            let midAggs = aggregate(hrBuckets(timelineStepSeconds), rrBuckets(timelineStepSeconds))
            return (points + scoreGrid(midAggs, activeFractions(timelineStepSeconds)))
                .sorted { $0.startTs < $1.startTs }
        }()

        let scored = points.compactMap { p -> (HourPoint, Double)? in p.level.map { (p, $0) } }
        guard !scored.isEmpty else {
            // No scorable hour: still return the unscored timeline so the UI can say "not enough data".
            // `hrOnlyFallback` is a mode property, so it is still reported.
            return points.isEmpty ? .empty
                : Result(hours: points, sustainedHigh: false, sustainedRun: 0,
                         dayMean: nil, peak: nil, activityMaskedHours: activityMaskedHours,
                         highStressMinutes: 0, hrOnlyFallback: hrOnlyFallback, timeline: timeline)
        }

        // 5) Sustained-high: walk back from the latest scored hour while each is HIGH.
        var run = 0
        for (_, lvl) in scored.reversed() {
            if lvl >= highBandFloor { run += 1 } else { break }
        }
        let sustained = run >= sustainedHours

        let dayMean = mean(scored.map { $0.1 })
        let peak = scored.max { $0.1 < $1.1 }?.0

        // 6) Time in high stress: each scored hour at/above `highBandFloor` is one bucket, in minutes
        //    (same threshold as `StressBand.high` and the sustained-high check).
        let highStressMinutes = scored.filter { $0.1 >= highBandFloor }.count * (bucketSeconds / 60)

        return Result(hours: points, sustainedHigh: sustained, sustainedRun: run,
                      dayMean: dayMean, peak: peak, activityMaskedHours: activityMaskedHours,
                      highStressMinutes: highStressMinutes, hrOnlyFallback: hrOnlyFallback,
                      timeline: timeline)
    }

    // MARK: - Helpers

    /// Floor division that is correct for negative numerators.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// Whether a local hour-bucket start falls in the waking window (06:00-22:00); the single source
    /// of truth for both the reference and the scored hours.
    static func isWakingHour(_ bucket: Int) -> Bool {
        let hourOfDay = floorDiv(bucket, bucketSeconds) % 24
        return hourOfDay >= wakingStartHour && hourOfDay < wakingEndHour
    }

    /// The day-relative reference: the median of the waking hours (plain mean below four, nil when empty).
    static func typicalReference(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        guard xs.count >= 4 else { return mean(xs) }
        return quantile(xs.sorted(), 0.5)
    }

    static func calmReference(_ xs: [Double], calmIsLow: Bool) -> Double? {
        guard !xs.isEmpty else { return nil }
        guard xs.count >= 4 else { return mean(xs) }
        let s = xs.sorted()
        return calmIsLow ? quantile(s, 0.25) : quantile(s, 0.75)
    }

    /// Linear-interpolated quantile of an already-sorted, non-empty array.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }   // defensive: callers guard emptiness; never trap on []
        if n == 1 { return sorted[0] }
        let pos = q * Double(n - 1)
        let lo = Int(pos), hi = min(lo + 1, n - 1)
        let frac = pos - Double(lo)
        return sorted[lo] + frac * (sorted[hi] - sorted[lo])
    }
}
