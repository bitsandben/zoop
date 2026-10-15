import Foundation
import WhoopProtocol
import WhoopStore   // OuraRespScale: the one place a ring's milli-bpm respiration row is read
@preconcurrency import WhoopStore

// Orchestrator: given a day's raw streams, a profile and personal baselines, runs the analyzers and
// assembles a `DailyMetric` plus the detected `SleepSession`s and their cache rows. Pure: no database
// access, and all derived values are approximate.

public enum AnalyticsEngine {

    /// Pair WRIST_OFF/WRIST_ON events into off-wrist `[start, end)` intervals for the sleep detector's
    /// fractional wear filter (#500). An OFF closes at the next ON, or at `windowEnd` if still off; an
    /// unmatched tail may end earlier when sustained valid HR resumes, but explicit pairs are never
    /// shortened. Events need not be sorted; kinds look like "WRIST_OFF(10)" and match by prefix.
    /// Unpartnered repeats are coalesced.
    public static func offWristIntervals(events: [WhoopEvent], windowEnd: Int,
                                         hr: [HRSample] = []) -> [(start: Int, end: Int)] {
        let wear = events
            .filter { $0.kind.hasPrefix("WRIST_OFF") || $0.kind.hasPrefix("WRIST_ON") }
            .sorted { $0.ts < $1.ts }
        var intervals: [(start: Int, end: Int)] = []
        var offStart: Int? = nil
        var lastOff: Int? = nil
        for e in wear where e.ts <= windowEnd {
            if e.kind.hasPrefix("WRIST_OFF") {
                if offStart == nil { offStart = e.ts }
                lastOff = e.ts // a repeated OFF invalidates evidence before it
            } else {                                              // WRIST_ON closes an open off-wrist span
                if let s = offStart, e.ts > s { intervals.append((start: s, end: e.ts)) }
                offStart = nil
            }
        }
        if let s = offStart, windowEnd > s {
            let end = WristWearRecovery.firstSustainedHR(hr, after: lastOff ?? s, before: windowEnd)
                ?? windowEnd
            if end > s { intervals.append((start: s, end: end)) }
        }
        return intervals
    }

    /// Baselines built from prior nights, passed in by the caller.
    public struct ProfileBaselines: Sendable {
        public let hrv: BaselineState?
        public let restingHR: BaselineState?
        public let resp: BaselineState?
        public let skinTemp: BaselineState?
        public init(hrv: BaselineState? = nil, restingHR: BaselineState? = nil,
                    resp: BaselineState? = nil, skinTemp: BaselineState? = nil) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp
            self.skinTemp = skinTemp
        }
    }

    /// The full analysis result for one day. Not `Sendable`: it embeds `DailyMetric` and
    /// `CachedSleepSession` from WhoopStore.
    public struct DayResult {
        /// DailyMetric in the WhoopStore cache shape.
        public let daily: DailyMetric
        /// Detected sleep sessions with stage segments.
        public let sleepSessions: [SleepSession]
        /// One cache row per detected session.
        public let cachedSleep: [CachedSleepSession]
        /// Detected workout sessions.
        public let workouts: [ExerciseSession]
        /// Where the detector lost each candidate workout (#1545). nil only when detection did not run; populated even when `workouts` is empty.
        public let detectionFunnel: WorkoutDetector.DetectionFunnel?
        /// Charge score [0,100], or nil (cold start / no HRV baseline).
        public let recovery: Double?
        /// Charge driver breakdown, biggest mover first; empty when there is no score. The UI renders one row per driver and never recomputes the score.
        public let chargeDrivers: [ChargeDriver]
        /// Skin temperature as a relative deviation from baseline (signed °C plus cooler/typical/warmer tier), or nil.
        public let skinTempRelative: SkinTempRelative?
        /// Effort [0,100], or nil (insufficient HR samples / invalid HRR).
        public let strain: Double?
        /// Rest composite [0,100], or nil (no asleep time). This is the value the `sleep_performance`
        /// metric key carries.
        public let restScore: Double?
        /// Per-score confidence tiers (Charge / Effort / Rest); worst case `.calibrating`.
        public let chargeConfidence: ScoreConfidence
        public let effortConfidence: ScoreConfidence
        public let restConfidence: ScoreConfidence
        /// Wear-gated mean in-bed skin temperature (°C) for the night, or nil. Baseline-independent: the
        /// caller seeds a personal baseline from these means and re-derives `DailyMetric.skinTempDevC` in pass 2.
        public let nightlySkinTempC: Double?
        /// Per-epoch motion magnitudes keyed by each session's start, on the same 30 s grid as its
        /// `stagesJSON`, for `WhoopStore.persistSessionMotion`. A session with too little gravity is omitted,
        /// so the caller never persists a fabricated zero series.
        public let sessionMotionByStart: [Int: [Double]]
        /// Per-epoch band sleep_state (0 wake / 1 still / 2 asleep / 3 up) keyed by session start, on the
        /// same 30 s grid, for `WhoopStore.persistSessionSleepState`. A session with no band samples is
        /// omitted so the caller persists NULL. Feeds the re-onset confirm guard on the next pass; never
        /// overrides the derived hypnogram. Empty on a WHOOP 4.0.
        public let sessionSleepStateByStart: [Int: [Int]]
        /// Bounds of the day's main-night group (the same `mainGroup` the aggregates and the refused-main-night HRV rule use); empty with no main night. Lets the `hrv diag` line describe the night the gate judged (#2425).
        public let mainNightBlocks: [SleepStageTotals.NightBlock]

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?, nightlySkinTempC: Double? = nil,
                    restScore: Double? = nil,
                    chargeConfidence: ScoreConfidence = .calibrating,
                    effortConfidence: ScoreConfidence = .calibrating,
                    restConfidence: ScoreConfidence = .calibrating,
                    sessionMotionByStart: [Int: [Double]] = [:],
                    sessionSleepStateByStart: [Int: [Int]] = [:],
                    chargeDrivers: [ChargeDriver] = [],
                    skinTempRelative: SkinTempRelative? = nil,
                    detectionFunnel: WorkoutDetector.DetectionFunnel? = nil,
                    mainNightBlocks: [SleepStageTotals.NightBlock] = []) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.mainNightBlocks = mainNightBlocks
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.detectionFunnel = detectionFunnel
            self.recovery = recovery; self.strain = strain
            self.chargeDrivers = chargeDrivers
            self.skinTempRelative = skinTempRelative
            self.nightlySkinTempC = nightlySkinTempC
            self.restScore = restScore
            self.chargeConfidence = chargeConfidence
            self.effortConfidence = effortConfidence
            self.restConfidence = restConfidence
            self.sessionMotionByStart = sessionMotionByStart
            self.sessionSleepStateByStart = sessionSleepStateByStart
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// UTC YYYY-MM-DD day string for unix seconds.
    public static func dayString(_ ts: Int) -> String {
        isoDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Local YYYY-MM-DD day string (#277). `offsetSec` is seconds east of UTC; shifting the instant by
    /// it turns the fixed-UTC formatter into a local-calendar one. The bucket must be the LOCAL day or a
    /// west-of-UTC evening lands in the next bucket and "today" never finds it. `offsetSec == 0` equals
    /// the UTC overload.
    public static func dayString(_ ts: Int, offsetSec: Int) -> String {
        dayString(ts + offsetSec)
    }

    /// UTC-midnight epoch seconds of an ISO `day` key. `isoDay` is a fixed-UTC formatter, so
    /// `dayString(ts, offsetSec:) == day` iff `(ts + offsetSec)` is in `[dayStartUtcSeconds(day), +86400)`;
    /// this turns per-sample DateFormatter calls into an integer range check (#996). A malformed key
    /// falls back to 0 (an empty 1970 window) rather than trapping.
    ///
    /// This is a UTC midnight paired with one offset and fixed 86,400 s blocks, so boundaries beyond a
    /// clock change sit an hour off the local midnight. `LocalDayWindows` is the zone-rule-correct
    /// primitive and is not yet wired in; `LocalDayWindowsTests` pins both answers.
    static func dayStartUtcSeconds(_ day: String) -> Int {
        Int(isoDay.date(from: day)?.timeIntervalSince1970 ?? 0)
    }

    /// Filters the in-memory night list down to the calendar day instead of re-reading the store (#997).
    /// For a past day `[dayLo, dayHi]` is a subset of the night window already held. Returns nil when
    /// unsafe so the caller reads directly:
    /// - today: its day runs past the 18 h night cap (`dayHi > nightHi`);
    /// - a night read that hit `limit` rows may be truncated inside the day span (`LIMIT` drops late rows).
    /// Same inclusive bounds and ts-ascending order as the store read, and the HR coalesce dedups on a
    /// range-independent `h.ts = p.ts` anti-join, so filtering after coalescing equals coalescing the
    /// day range. A DST-shifted bound falls outside the window and declines, never returning wrong data.
    public static func daySliceFromNight<T>(_ night: [T],
                                            nightLo: Int, nightHi: Int,
                                            dayLo: Int, dayHi: Int,
                                            limit: Int = 200_000,
                                            ts: (T) -> Int) -> [T]? {
        guard dayLo >= nightLo, dayHi <= nightHi, night.count < limit else { return nil }
        return night.filter { ts($0) >= dayLo && ts($0) <= dayHi }
    }

    /// JSON-encode stage segments to the array shape CachedSleepSession stores. `.sortedKeys` keeps the
    /// output reproducible so the self-heal's "skip write when unchanged" check works.
    public static func encodeStages(_ stages: [StageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stages) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Inverse of `encodeStages`. Only the on-device segment-array shape decodes; the imported minute-dict
    /// shape (`{light,deep,rem,awake}`) yields `[]` (#804).
    public static func decodeStages(_ json: String?) -> [StageSegment] {
        guard let json, let data = json.data(using: .utf8),
              let stages = try? JSONDecoder().decode([StageSegment].self, from: data) else { return [] }
        return stages
    }

    /// Rebuild the pure `SleepSession` from a device-provided `CachedSleepSession` (e.g. an Oura
    /// SleepNet hypnogram, #773). Uses the edit-aware onset, keeps stored efficiency (deriving it from
    /// stage minutes only if none), passes `restingHR`/`avgHRV` through (nil for a ring night; `analyzeDay`
    /// re-derives them). Returns nil when the row has no decodable stage timeline, so a minute-dict row is
    /// never injected (#804).
    public static func sleepSession(fromProvided c: CachedSleepSession) -> SleepSession? {
        let stages = decodeStages(c.stagesJSON)
        guard !stages.isEmpty else { return nil }
        let efficiency: Double
        if let e = c.efficiency {
            efficiency = e
        } else if let m = SleepStageTotals.minutes(fromStagesJSON: c.stagesJSON), m.inBed > 0 {
            efficiency = m.asleep / m.inBed
        } else {
            efficiency = 0
        }
        return SleepSession(start: c.effectiveStartTs, end: c.endTs, efficiency: efficiency,
                            stages: stages, restingHR: c.restingHr, avgHRV: c.avgHrv)
    }

    /// Analyze one day's streams into a `DayResult`.
    ///
    /// - Parameters:
    ///   - day: the calendar day (UTC) this metric is for; a sleep session is attributed to the day its
    ///     `end` falls on.
    ///   - hr/rr/resp/gravity: the day's raw streams (a wider window around the night may be passed).
    ///   - profile: age/sex/weight/height for HRmax and calories.
    ///   - baselines: personal baselines for recovery normalization.
    ///   - maxHROverride: explicit HRmax (bpm) for strain/zones; nil uses Tanaka from age.
    ///
    /// The night's respiratory rate (breaths/min) from the strap's own per-window rate rows (the Oura
    /// 0x6A `breath`, milli-bpm), or nil with too little coverage. Not the RSA estimate: this is a
    /// device measurement, so the question is coverage. The value is the median of rows inside a matched
    /// in-bed session, with two guards:
    /// * the rows must span at least `vendorRespMinSpanS` (cadence is not a proxy for coverage, and a
    ///   partial tail is not the night's respiration);
    /// * the median must fall in `SleepStager.respPlausibleRangeBpm` (8-25), so one corrupt record cannot
    ///   publish an impossible rate.
    public static func vendorRespRateBpm(_ rows: [RespSample],
                                         sessions: [(start: Int, end: Int)]) -> Double? {
        guard !rows.isEmpty, !sessions.isEmpty else { return nil }
        let inSession = rows.filter { r in sessions.contains { r.ts >= $0.start && r.ts <= $0.end } }
        guard let first = inSession.map(\.ts).min(), let last = inSession.map(\.ts).max(),
              last - first >= vendorRespMinSpanS else { return nil }
        let median = HRVAnalyzer.median(inSession.map { OuraRespScale.breathsPerMin(raw: $0.raw) })
        return SleepStager.respPlausibleRangeBpm.contains(median) ? median : nil
    }

    /// Minimum span (seconds) the vendor respiration rows must cover before their median is used: one hour.
    public static let vendorRespMinSpanS = 3_600

    public static func analyzeDay(day: String,
                                  // Optional sink for the Effort funnel line; nil builds nothing. A parameter so the engine stays pure.
                                  strainDiag: ((String) -> Void)? = nil,
                                  hr: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  // The strap's own per-window respiratory rate rows (Oura 0x6A `breath`, milli-bpm; see
                                  // `OuraRespScale`). Kept apart from `resp`, the raw WHOOP ADC waveform, which is a different quantity.
                                  // Empty for every WHOOP night.
                                  vendorResp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  steps: [StepSample] = [],
                                  // Calendar-day-scoped overrides for the additive daily totals (steps, activeKcalEst), workout
                                  // detection and Effort. nil falls back to the night window the rest of the analysis uses. The caller
                                  // supplies a full local-day read so late hours, outside the ~42 h night window (ends near noon), are
                                  // seen: an afternoon workout is detected on its own day, split at local midnight like the totals.
                                  // Sleep and recovery keep using hr/rr/resp/gravity, since staging needs the pre-midnight span.
                                  dayHr: [HRSample]? = nil,
                                  daySteps: [StepSample]? = nil,
                                  dayGravity: [GravitySample]? = nil,
                                  // Wear-gated nightly skin-temp mean is harvested here (baseline-independent); the caller seeds a
                                  // personal baseline across nights and re-derives skinTempDevC in pass 2.
                                  skinTemp: [SkinTempSample] = [],
                                  // Device family that wrote `skinTemp`, so the raw to °C conversion picks the right scale (#938):
                                  // 5/MG stores centidegrees (raw/100); the WHOOP 4.0 v24 field is a raw ADC on a different scale.
                                  skinTempFamily: DeviceFamily = .whoop5,
                                  // Per-device WHOOP 4.0 worn anchor raw (#938): the raw that maps to 33.0 °C for this device. The
                                  // @72 ADC's register offset varies per device, so the global 826 anchor can fail the worn gate
                                  // entirely. nil uses the global `Whoop4SkinTemp.anchorRaw`; `.whoop5` ignores the anchor.
                                  skinTempAnchorRaw: Double? = nil,
                                  // Seconds a worn HR sample may sit from a skin-temp sample and still count (#1467). 0 is exact-timestamp;
                                  // a non-zero value is for owners whose HR and skin-temp streams are not co-sampled (Oura,
                                  // see `defaultOuraWornToleranceSec`).
                                  skinTempWornToleranceSec: Int = 0,
                                  // WHOOP 4.0 raw SpO2 PPG ADC samples (red/IR) for the night (#93). Nightly means are banked as raw
                                  // ADC, not a calibrated blood-oxygen %.
                                  spo2: [SpO2Sample] = [],
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  // Wall-clock UTC offset (seconds) for the sleep detector's daytime false-sleep guard (#90).
                                  tzOffsetSeconds: Int = 0,
                                  // Off-wrist `[start, end)` intervals (unix seconds) from `offWristIntervals` for the off-wrist
                                  // sleep backstop (#500). A session is dropped only when its off-wrist coverage reaches
                                  // maxOffWristSleepFraction; the HR-gap proxy in detectSleep remains the always-on guard.
                                  wristOff: [(start: Int, end: Int)] = [],
                                  // sleepNeedHours: personal sleep need (h), default 8; drives the 0.50 duration term.
                                  // sleepConsistency: sleep/wake regularity in [0,1]; nil leaves the consistency term neutral.
                                  sleepNeedHours: Double = Rest.defaultNeedHours,
                                  sleepConsistency: Double? = nil,
                                  // The user's learned habitual midsleep (local seconds in [0, 86400)) for the main-night pick, so a
                                  // shift sleeper's real night out-scores a nap. nil = cold start: broad overnight-band bonus (#547).
                                  habitualMidsleepSec: Int? = nil,
                                  // The strap's own persisted band sleep_state per timestamp (`(sb>>4)&3`: 0 wake / 1 still / 2 asleep /
                                  // 3 up). Used only to confirm a borderline morning re-onset (#531).
                                  bandSleepState: [(ts: Int, state: Int)] = [],
                                  // Selects the V2 sleep stager. Defaults false for pure-function callers; the shipped app threads
                                  // `PuffinExperiment.experimentalSleepV2Enabled`, which is default on.
                                  useSleepStagerV2: Bool = false,
                                  // Opt-in motion-aware wake refinement (#364). When true, `WakeMotionRefinement` runs after V1/V2
                                  // staging and reclassifies hot-but-still wake segments to light. It self-gates on gravity and step
                                  // density, so it is a no-op on sparse nights (e.g. WHOOP 4.0). Threaded from
                                  // `PuffinExperiment.motionAwareWakeEnabled`.
                                  useMotionAwareWake: Bool = false,
                                  // Experimental: fire times of the strap's own alarm; a night ending near one ends when the user got up (`AlarmAnchoredWake`).
                                  alarmFires: [Int] = [],
                                  useAlarmAnchoredWake: Bool = false,
                                  // Already-staged sessions to fold in alongside the motion detector's, e.g. an Oura SleepNet night
                                  // rebuilt via `sleepSession(fromProvided:)` (#804). They bypass detectSleep and wake refinement and
                                  // win over overlapping detected sessions; non-overlapping detected sessions (a nap) are kept. A
                                  // provided session's restingHR/avgHRV is derived here from the day's hr/rr when the stored row had none.
                                  providedSleep: [SleepSession] = [],
                                  // Provenance for the per-day sleep trace. The caller passes `.imported(...)` when an imported row won the daily merge. Trace-only.
                                  sleepProvenance: SleepProvenance = .measured,
                                  // Sleep & Rest test-mode trace sink. Forwards the detectSleep gate trace and Rest sub-score line; side effects only.
                                  traceSink: ((String) -> Void)? = nil,
                                  // HRV test-mode sink (#141): nightly per-5-min-window RMSSDs tagged by sleep stage plus a whole-night vs deep-only vs last-SWS summary.
                                  hrvTraceSink: ((String) -> Void)? = nil,
                                  // Emit the ~90 per-window `hrv window` lines or only the summary. Set for the most recent night only so the ring buffer is not flooded.
                                  hrvWindowDetail: Bool = false,
                                  // When true the nightly HRV is RMSSD over deep-sleep windows only (WHOOP-style) instead of the whole-night mean (#141).
                                  deepHrvWindow: Bool = false,
                                  // Which TRIMP recipe scores Effort (#1545). Edwards is time-in-zone and pays nothing below 50% HRR,
                                  // so intermittent work can score near zero; Banister is exponential in %HRR with no floor.
                                  effortMethod: StrainScorer.Method = .edwards,
                                  // The wearer's sleep-onset strictness and learned offset, threaded into detection. `.standard` is the shipped rule.
                                  onsetTuning: SleepOnsetTuning = .standard) -> DayResult {

        // Day UTC bounds computed once (#996): `dayString(ts, offsetSec:) == day` is membership in [dayStartUtc, +86400).
        let dayStartUtc = dayStartUtcSeconds(day)
        let dayEndUtc = dayStartUtc + 86_400
        func tsInDay(_ ts: Int) -> Bool { (ts + tzOffsetSeconds) >= dayStartUtc && (ts + tzOffsetSeconds) < dayEndUtc }

        // Sleep detection + staging
        let detectedSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                  tzOffsetSeconds: tzOffsetSeconds, wristOff: wristOff,
                                                  bandSleepState: bandSleepState,
                                                  useSleepStagerV2: useSleepStagerV2,
                                                  onsetTuning: onsetTuning,
                                                  traceSink: traceSink)
        // Motion-aware wake refinement runs after V1/V2 staging over every detected session; it self-gates on
        // observed step density, so empty/sparse `steps` is a no-op.
        let refinedSessions = useMotionAwareWake
            ? detectedSessions.map { WakeMotionRefinement.refine($0, grav: gravity, steps: steps) }
            : detectedSessions
        let wakeAnchoredSessions = useAlarmAnchoredWake && !alarmFires.isEmpty
            ? refinedSessions.map { AlarmAnchoredWake.refine($0, alarmFires: alarmFires, hr: hr) }
            : refinedSessions
        // Fold in the caller's device-provided hypnogram (see `providedSleep`): enrich each provided
        // session's restingHR/avgHRV from this day's hr/rr using the same helpers detectSleep uses, then keep
        // only detected sessions that do not overlap a provided one.
        let allSessions: [SleepSession]
        if providedSleep.isEmpty {
            allSessions = wakeAnchoredSessions
        } else {
            let rrSorted = rr.sortedByTsStable()
            let enrichedProvided: [SleepSession] = providedSleep.map { s in
                // No HR-only special case: fill whatever is missing uniformly. A short-circuit on `hrOnly` would skip
                // the fill for an HR-only night that measured RHR but no HRV (#1884).
                guard s.restingHR == nil || s.avgHRV == nil else { return s }
                let rhr = s.restingHR ?? SleepStager.sessionRestingHR(start: s.start, end: s.end, hr: hr)
                let hrv = s.avgHRV ?? SleepStager.sessionAvgHRV(start: s.start, end: s.end, rr: rrSorted,
                                                                stages: s.stages)
                // `hrOnly` is carried explicitly: this rebuilds the struct field by field, so a new flag is dropped
                // by default unless named here.
                return SleepSession(start: s.start, end: s.end, efficiency: s.efficiency,
                                    stages: s.stages, restingHR: rhr, avgHRV: hrv, hrOnly: s.hrOnly)
            }
            let keptDetected = wakeAnchoredSessions.filter { d in
                !enrichedProvided.contains { $0.start < d.end && d.start < $0.end }
            }
            allSessions = keptDetected + enrichedProvided
        }
        // Sessions attributed to `day` end on it (LOCAL day, #277).
        let matched = allSessions.filter { tsInDay($0.end) }

        // The day's main night (#525). A day can hold an overnight sleep and a nap; the duration figures
        // (total sleep, stages, efficiency, disturbances, hence Rest and sleep debt) describe the MAIN night,
        // the same block the Sleep tab hero shows, and must not sum the nap in. Naps stay their own rows.
        // `SleepStageTotals.mainNightIndex` is the single shared selector.
        // Pick by learned-timing score using the habitual midsleep (nil = cold-start overnight band).
        // Biphasic bridge (#561): `mainNightGroupIndices` bridges adjacent blocks whose gap is under
        // `gapBridgeMaxMin`, scores the bridged span and returns all fragments of the winning group. The
        // aggregate below sums their stages; in-bed is the sum of each fragment's own span (the gap is not
        // invented as WASO here). With no bridgeable gap it collapses to the single block.
        let mainGroupIdx = SleepStageTotals.mainNightGroupIndices(
            matched.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: tzOffsetSeconds, habitualMidsleepSec: habitualMidsleepSec) ?? []
        let mainGroup: [SleepSession] = mainGroupIdx.map { matched[$0] }

        // Daily sleep aggregates (AASM) summed over the main-night group (#525 / #561)
        var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0
        var inBedS = 0.0, effWeighted = 0.0
        var disturbances = 0
        // Hypnogram coverage across the group: how much of the fragments' spans the stage segments account
        // for. Kept apart from `inBedS`, which later absorbs the inter-fragment gap (#777/#705); a bridged
        // gap is known-awake, whereas a hole inside a fragment is time never observed. Summed off the
        // decoded segments and handed to `HypnogramCoverage` so the ratio/clamp/nil rules have one definition.
        // Scope note: a minute-dict session decodes to zero segments (span, no cover); `fraction`'s
        // `coveredSeconds > 0` check returns nil for a group with no timestamped stages. This holds while a
        // group is single-sourced, which the day merge ensures; a mixed group would read as holed
        // (`HypnogramCoverageTests.testMixedSourceGroupReadsAsHoled`).
        var coveredS = 0.0, spanS = 0.0
        for s in mainGroup {
            let m = SleepStager.hypnogramMetrics(s)
            let inBed = Double(s.end - s.start)
            inBedS += inBed                       // each fragment's own in-bed span (the gap is added below)
            effWeighted += s.efficiency * inBed   // in-bed-weighted efficiency across the group
            spanS += inBed
            for seg in s.stages where seg.end > seg.start { coveredS += Double(seg.end - seg.start) }
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        let stageCoverage = HypnogramCoverage.fraction(coveredSeconds: coveredS, spanSeconds: spanS)
        // Out-of-bed time between bridged fragments is awake (#777/#705): it is in no fragment's span, so a
        // 20-min gap used to read as ~4 min. Folded into awake by extending the in-bed denominator
        // (tstS unchanged), using the same `SleepStageTotals.interFragmentAwakeSeconds` as the edit/recompute
        // seam so the denominator is never double-counted. A bridged gap counts as one disturbance.
        let gapAwakeS = SleepStageTotals.interFragmentAwakeSeconds(mainGroup.map { (start: $0.start, end: $0.end) })
        if gapAwakeS > 0 {
            inBedS += gapAwakeS              // the gap is fully awake: extends in-bed, adds 0 to effWeighted
            disturbances += 1
        }
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

        // Rest composite (Charge/Effort/Rest)
        // The 0-100 sleep score behind `sleep_performance`; the Charge "Rest quality" term reads it /100.
        let hasStagedSleep = (deepS + remS) > 0
        let restScore: Double? = tstS <= 0 ? nil : Rest.composite(
            tstSeconds: tstS,
            inBedSeconds: inBedS,
            efficiency: efficiency,
            restorativeSeconds: deepS + remS,
            needHours: sleepNeedHours,
            consistency: sleepConsistency,
            deepSeconds: deepS)
        // Gravity-sparse computed once, shared by the sleep-motion trace and the Rest confidence guard so they cannot diverge (#345).
        let gravitySparse = SleepStager.isGravitySparse(gravity, hr: hr)
        // Test mode: Rest sub-score breakdown from the identical inputs `restScore` used, so trace and score cannot disagree. Emitted only when requested and a night scored.
        if let traceSink, !matched.isEmpty {
            if restScore != nil {
                traceSink(Rest.subScoreLine(
                    tstSeconds: tstS, inBedSeconds: inBedS, efficiency: efficiency,
                    restorativeSeconds: deepS + remS, needHours: sleepNeedHours,
                    consistency: sleepConsistency, deepSeconds: deepS,
                    groupFragments: mainGroup.count, groupInBedSeconds: inBedS))
            }
            // Motion coverage and staging context behind the Rest number (#319): WHOOP 4.0 motion is coarse, so
            // sparse nights default most epochs to sleep and over-count duration. `stager` says whether V1/V2 ran.
            traceSink(AnalyticsEngine.sleepMotionLine(
                day: day, grav: gravity.count, hr: hr.count,
                sparse: gravitySparse,
                useSleepStagerV2: useSleepStagerV2, family: skinTempFamily))
            // Append sleep provenance so an imported row winning the merge is visible (#799). sourceRowId is the
            // main night's start ts for the measured path, else the caller-supplied winning-row id. Trace-only.
            let mainStart = mainGroup.map { $0.start }.min() ?? matched.map { $0.start }.min() ?? 0
            traceSink(sleepProvenanceLine(provenance: sleepProvenance,
                                          hoursAsleepMin: tstS / 60.0,
                                          sourceRowId: String(mainStart)))
            // Onset decision (#271): did HR dip when the window opened, or did it open on a still-but-awake
            // stretch? Baseline and at-onset window read the same HR detection ran over (`dayHr ?? hr`), so the
            // onset is inside it and the baseline is a real day median. Silent for motion-only nights.
            let onsetHr = dayHr ?? hr
            if mainStart > 0,
               let baselineHr = AnalyticsEngine.medianBpm(onsetHr.map { $0.bpm }),
               let hrAtOnset = AnalyticsEngine.medianBpm(
                   onsetHr.filter { $0.ts >= mainStart && $0.ts < mainStart + AnalyticsEngine.onsetTraceWindowSec }
                     .map { $0.bpm }) {
                traceSink(AnalyticsEngine.sleepOnsetLine(onsetTs: mainStart,
                                                         hrAtOnsetBpm: hrAtOnset,
                                                         baselineHrBpm: baselineHr))
            }
        }

        // The sleep-duration figures above are main-night-only, but the physiological aggregates below
        // (resting HR, HRV, respiration) deliberately stay over all matched sessions: the overnight dominates
        // them anyway, and narrowing would widen the change's reach into the recovery score for a negligible
        // shift (#525). Daily resting HR = lowest per-session resting HR across matched sessions.
        // Physiology sessions (#1801/#1884): motion-backed sessions are preferred; an HR-only night is used
        // only when the day has no other kind. Only the session bounds are inferred from HR; each RMSSD is
        // measured over its own 5-minute window, so excluding the night discarded a real HRV and left Charge
        // with no input. The night still travels marked `hrOnly`.
        // Named once because the deep-window HRV pool and the SDNN index re-derive from `rr` over each
        // session's own stages, so the session set is the only place to scope them.
        let physiologyOnly = matched.filter { !$0.hrOnly }
        let physiologySessions = physiologyOnly.isEmpty ? matched : physiologyOnly
        // Use the gated lowest five-minute bin from the primary session, not its whole-session mean (#2522).
        // Choosing the session first keeps #2358's nap protection; #804's device-provided value still wins.
        let primarySession = physiologySessions.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        let providedPrimaryRHR = primarySession
            .flatMap { p in providedSleep.first(where: { $0.start == p.start && $0.end == p.end })?.restingHR }
        let restingHRDaily: Int? = providedPrimaryRHR ?? primarySession?.restingHR
        // In-bed-weighted mean of per-session avg HRV.
        let avgHRVDaily: Double? = {
            if deepHrvWindow {
                // WHOOP-style HRV (#141): pool RMSSD over deep-stage 5-min windows only, reusing `sessionHrvWindows` so
                // the value equals the trace's `deepOnly` figure. rr must be sorted (RMSSD = successive diffs). nil
                // without deep sleep: the caller shows calibrating.
                let rrSorted = rr.sortedByTsStable()
                let deep = physiologySessions.flatMap { s in
                    SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rrSorted, stages: s.stages)
                        .filter { $0.stage == "deep" }.compactMap { $0.rmssd }
                }
                return deep.isEmpty ? nil : deep.reduce(0, +) / Double(deep.count)
            }
            // A main night refused by the #1118 over-count gate is not replaced by the day's naps: once the gate
            // makes its HRV nil it carries zero weight, and a 26-minute nap would become 100% of the day's HRV.
            // So when a main-group session's HRV is nil because the gate refused it, only the main group is
            // pooled. A main night that simply banked no R-R is not refused, so #1884's fill-in still applies.
            let mainNightRefused = mainGroup.contains { s in
                s.avgHRV == nil && SleepStager.sessionHrvOverCounted(start: s.start, end: s.end, rr: rr)
            }
            let hrvPool = mainNightRefused
                ? physiologySessions.filter { p in mainGroup.contains { $0.start == p.start && $0.end == p.end } }
                : physiologySessions
            let pairs = hrvPool.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Daily SDNN (ms): the 5-min SDNN index (Task Force), the mean of per-segment SDNN over in-bed R-R,
        // the broad autonomic-variability counterpart to the vagal RMSSD above. A whole-night SD is dominated
        // by sleep-stage HR drift and reads 2-3x high, so the windowed index is used. nil when no segment
        // has enough clean beats. Keeps R-R timestamps (segmentation needs them).
        let avgSDNNDaily: Double? = {
            let inBed = rr.filter { r in physiologySessions.contains { r.ts >= $0.start && r.ts < $0.end } }
            return inBed.isEmpty ? nil : HRVAnalyzer.sdnnIndex(inBed, segmentSec: 300)
        }()

        // HRV nightly trace (#141): per-5-min-window RMSSD tagged by stage, then a summary comparing the
        // reported whole-night mean with a deep-only mean and a last-slow-wave-sleep value, so a report that
        // HRV reads high shows which stages lift it. Reuses `sessionHrvWindows`; zero cost with a nil sink.
        if let hrvTraceSink {
            func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
            // `sessionHrvWindows` needs ts-sorted rr; the value path passes the stager's pre-sorted copy, so sort our own once here.
            let rrSorted = rr.sortedByTsStable()
            var allWin: [SleepStager.HrvWindow] = []
            for s in matched {
                let wins = SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rrSorted, stages: s.stages)
                if hrvWindowDetail {
                    for w in wins {
                        let rm = w.rmssd.map { "\(r2($0))ms" } ?? "nil"
                        hrvTraceSink("hrv window t=\((w.startTs - s.start) / 60)min stage=\(w.stage) beats=\(w.cleanBeats) rmssd=\(rm)")
                    }
                }
                allWin.append(contentsOf: wins)
            }
            func meanMs(_ ws: [SleepStager.HrvWindow]) -> String {
                let v = ws.compactMap { $0.rmssd }
                return v.isEmpty ? "nil" : "\(r2(v.reduce(0, +) / Double(v.count)))ms"
            }
            let withR = allWin.filter { $0.rmssd != nil }
            let deepW = withR.filter { $0.stage == "deep" }
            let lastSws = SleepStager.lastDeepRun(allWin).filter { $0.rmssd != nil }
            // `reported` is the displayed duration-weighted session-mean-of-means; `wholeNight` is the pooled-window
            // mean (equal on single-session nights) and the baseline for the deepOnly/lastSWS comparison.
            let reported = avgHRVDaily.map { "\(r2($0))ms" } ?? "nil"
            // Say why `reported` is nil, but only when real window means are printed beside it (#2128): a nil
            // next to `wholeNight=31.55ms` reads as a lost value when the usual cause is the #1118 gate refusing
            // an over-counted night. Derived from the two existing calls: inside `sessionAvgHRV` the only paths
            // to nil are "no window yielded an RMSSD" and the gate, so windows-with-RMSSD plus nil is the gate.
            // It says `overCount` rather than a verdict because that function pins every over-count to
            // crossSecondOverCount internally. Not in deep-window mode, which never reads `s.avgHRV`, so naming
            // the gate there would assert a cause not verified (`nDeep` already explains it).
            let refused = !deepHrvWindow && avgHRVDaily == nil && !withR.isEmpty
                && physiologySessions.contains { s in
                    SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rrSorted, stages: [])
                        .contains { $0.rmssd != nil }
                        && SleepStager.sessionAvgHRV(start: s.start, end: s.end, rr: rrSorted) == nil
                }
            hrvTraceSink("hrv nightSummary reported=\(reported) \(refused ? "refused=overCount " : "")wholeNight=\(meanMs(withR)) deepOnly=\(meanMs(deepW)) lastSWS=\(meanMs(lastSws)) nWin=\(withR.count) nDeep=\(deepW.count)")
        }

        // Nightly respiratory rate (breaths/min), approximate: RSA from the R-R stream per matched in-bed
        // session, median of finite per-session estimates; nil if none. WHOOP5 v18 has no raw resp ADC.
        // A device-measured rate wins when the night has one: `vendorResp` carries the strap's own rows
        // (today the Oura 0x6A `breath`, see `vendorRespRateBpm`). On a ring night the RSA estimate comes
        // from banked R-R and returns the same 13.3333 bpm shuffled or reversed, i.e. no breathing
        // information. A WHOOP night passes no `vendorResp` and keeps the RSA path.
        let respRateDaily: Double? = {
            if let vendor = Self.vendorRespRateBpm(vendorResp,
                                                   sessions: matched.map { (start: $0.start, end: $0.end) }) {
                return vendor
            }
            let perSession = matched
                .map { SleepStager.respRateFromRR(rr, start: $0.start, end: $0.end) }
                .filter { $0.isFinite }
            return perSession.isEmpty ? nil : HRVAnalyzer.median(perSession)
        }()

        let sleepStart = matched.map { $0.start }.min()
        let sleepEnd = matched.map { $0.end }.max()

        // Skin-temperature deviation, computed before recovery so Charge can fold it in. Wear-gated in-bed
        // mean (baseline-independent, harvested every pass) plus the deviation against the personal baseline.
        // Pass 1 has no baseline, so the deviation is nil; the caller seeds it from the means for pass 2.
        let nightlySkinTempC = wornNightlySkinTempC(matched, hr: hr, skinTemp: skinTemp,
                                                    family: skinTempFamily, anchorRaw: skinTempAnchorRaw,
                                                    wornToleranceSec: skinTempWornToleranceSec)
        let skinTempDevC: Double? = nightlySkinTempC.flatMap { (v: Double) -> Double? in
            guard let b = baselines.skinTemp, b.usable else { return nil }
            return round2(Baselines.deviation(v, state: b).delta)
        }

        // Raw SpO2 (WHOOP 4.0 v24 PPG ADC): nightly red/IR ADC means over the in-bed spans, nil if none.
        // Banked as-is for the Health "Raw SpO2" tile; not a calibrated blood-oxygen % (#93).
        let nightlySpo2Raw = nightlySpo2RawMeans(matched, spo2: spo2)

        // Recovery / Charge
        var recovery: Double? = nil
        // Ordered "why is Charge what it is" rows built from the same inputs as the score (empty when no score).
        var chargeDrivers: [ChargeDriver] = []
        if let hrvVal = avgHRVDaily, let rhrVal = restingHRDaily, let hrvBase = baselines.hrv {
            // The sleep term is sleep sufficiency (asleep / need), WHOOP's published sleep input, not the Rest composite.
            let sleepPerf: Double? = tstS > 0 ? Rest.sufficiency(tstSeconds: tstS, needHours: sleepNeedHours) : nil
            recovery = RecoveryScorer.recovery(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: respRateDaily,       // term drops + renormalizes when nil / no baseline
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf,
                skinTempDev: skinTempDevC)  // symmetric penalty; drops + renormalizes when nil
            // Driver breakdown from the identical inputs; missing terms are omitted, never faked.
            chargeDrivers = RecoveryScorer.chargeDrivers(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: respRateDaily,
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf,
                skinTempDev: skinTempDevC)
        }
        // Skin temp as a relative deviation marker (a trend, not a clinical absolute); nil without a deviation.
        let skinTempRelative = RecoveryScorer.skinTempRelative(deviationC: skinTempDevC)

        // Strain / Effort over the full calendar day. Integrates dayHr (clamped to `now` for today) when
        // supplied, so a same-day afternoon workout counts and the prior evening's HR does not bleed in;
        // falls back to the night `hr` for pure-function callers.
        let effMaxHR: Double? = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restForStrain = restingHRDaily.map(Double.init) ?? StrainScorer.defaultRestingHR
        // The Effort ring's funnel. A nil sink builds nothing; IntelligenceEngine passes its per-day recorder.
        let strain = StrainScorer.strain(dayHr ?? hr, maxHR: effMaxHR, restingHR: restForStrain,
                                         method: effortMethod, sex: profile.sex,
                                         diag: strainDiag, day: day)
        // Log contributions (#2438) need to know whether the day was scored against the user's setting or
        // the age formula, and how far the day's HR ran above it. The `effort score` line above collapses
        // override and Tanaka into one word, and the provenance is gone once `strain` receives HRmax, so it
        // is built here. Only built with a sink attached; changes no score.
        if let strainDiag {
            let hrForPeak = dayHr ?? hr
            strainDiag(StrainScorer.dayCalibrationLine(
                // The HRmax the day was actually scored against; for an age-less profile that is the value `strain`
                // substitutes internally, so this line cannot contradict the `effort score` line.
                day: day, hrmax: effMaxHR ?? Double(StrainScorer.defaultMaxHR()),
                hrmaxSource: maxHROverride != nil ? "override" : (profile.age > 0 ? "tanaka" : "default"),
                tanaka: profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil,
                observedPeak: hrForPeak.max(by: { $0.bpm < $1.bpm }).map { Double($0.bpm) },
                restingHR: restForStrain)
                // The raw peak is often one isolated sample on a ring; this is the value held (#2438).
                + StrainScorer.sustainedPeakField(StrainScorer.sustainedPeak(hrForPeak))
                + StrainScorer.sustainedPeakSpanField(StrainScorer.sustainedPeakSpan(hrForPeak)))
        }

        // Workouts. Detect over the full calendar day (dayHr/dayGravity) when supplied so a same-day
        // afternoon workout is caught on its own day; falls back to the night window. restingHR comes from the
        // night's sessions; nil lets WorkoutDetector derive it from the day's HR floor.
        var detectionFunnel: WorkoutDetector.DetectionFunnel? = nil
        let workouts = WorkoutDetector.detect(
            hr: dayHr ?? hr, gravity: dayGravity ?? gravity,
            restingHR: restingHRDaily.map(Double.init),
            // The day's effective HRmax, not just the override (#1545). Without it the detector fell back to
            // `StrainScorer.estimateHRmax` = max(observed p99.5, Tanaka), a larger reserve than the day used, so
            // bouts were held to a stricter %HRR yardstick than the day containing them (age 30 / RHR 60 / observed
            // 195: a 125 bpm minute is zone 1 for the day, zone 0 for the bout). It also feeds the z2+ gate below,
            // so it changes which bouts are detected. Still nil for an age-less profile.
            maxHR: effMaxHR,
            age: profile.age > 0 ? profile.age : nil,
            profile: profile,
            // Bouts must be scored by the same recipe as the day itself (#1545); otherwise a session could score
            // less than the day it sits inside.
            effortMethod: effortMethod,
            funnel: { detectionFunnel = $0 })

        // Steps (approximate). step_motion_counter@57 is a cumulative u16 that wraps at 65536. The daily
        // total is the sum of wrap-aware increments over the time-ordered 1 Hz records:
        // delta = (cur - prev) & 0xFFFF; the first record contributes 0. Reading byte @57 alone and summing
        // it exploded the count to ~10M/day (#132/#276/#316). An estimate, not cloud/clinical parity.
        let stepsTotal: Int? = {
            // Prefer the full-calendar-day stream for the additive total, else the night window; filter to the
            // LOCAL-day key (#277). The wrap-aware tick math lives in the shared StepsCounter kernel so daily and
            // per-workout (#398) totals cannot disagree.
            let inDay = (daySteps ?? steps).filter { tsInDay($0.ts) }
            guard let ticks = StepsCounter.stepsInWindow(inDay) else { return nil }
            // @57 counts motion ticks, not validated steps (the 5/MG counter overcounts). Divided by the user's
            // ticks-per-step (default 1.0 = raw; floor 0.5 so a bad pref can at most double the total) (#139).
            let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
            return scaled > 0 ? scaled : nil
        }()

        // Daily calories (approximate, HR-only whole-day estimate): the per-second resting/active model the
        // per-workout estimate uses (resting BMR below activeThreshold, Keytel above), with the same effMaxHR
        // and restingHRDaily as strain; nil without HR. Additive totals (steps, calories) sum over the full
        // LOCAL calendar day from dayHr/daySteps, not the ~42 h sleep-detection window, which would drop a
        // past day's late hours and double-count seconds shared with adjacent days (#277). Falls back to
        // the night hr. Strain keeps the full window.
        let dayHrFiltered = (dayHr ?? hr).filter { tsInDay($0.ts) }
        let activeKcalEst: Double? = dayHrFiltered.isEmpty ? nil : Calories.estimateDayCalories(
            dayHrFiltered, profile: profile, hrmax: effMaxHR,
            restingHR: restingHRDaily.map(Double.init))

        // Assemble DailyMetric
        let daily = DailyMetric(
            day: day,
            totalSleepMin: matched.isEmpty ? nil : tstS / 60.0,
            efficiency: matched.isEmpty ? nil : efficiency,
            deepMin: matched.isEmpty ? nil : deepS / 60.0,
            remMin: matched.isEmpty ? nil : remS / 60.0,
            lightMin: matched.isEmpty ? nil : lightS / 60.0,
            disturbances: matched.isEmpty ? nil : disturbances,
            restingHr: restingHRDaily,
            avgHrv: avgHRVDaily,
            recovery: recovery,
            strain: strain,
            exerciseCount: workouts.count,
            spo2Pct: nil,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateDaily,
            steps: stepsTotal,
            activeKcalEst: activeKcalEst,
            spo2Red: nightlySpo2Raw?.red,
            spo2Ir: nightlySpo2Raw?.ir,
            avgSdnn: avgSDNNDaily,
            // The absolute this pass's deviation was derived from (#1636); set beside `skinTempDevC` so any path
            // persisting the struct keeps both thermal values.
            skinTempC: nightlySkinTempC,
            // Every session this day was staged from heart rate alone. Read from the sessions' own `hrOnly`
            // marker, not `physiologySessions.isEmpty`: that set now falls back to `matched` and can never be
            // empty when `matched` is not, which would pin the flag false (#1884).
            sleepHrOnly: matched.isEmpty ? nil : matched.allSatisfy { $0.hrOnly })
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // Cache rows
        let cachedSleep = matched.map { s in
            CachedSleepSession(
                startTs: s.start, endTs: s.end,
                efficiency: s.efficiency,
                restingHr: s.restingHR,
                avgHrv: s.avgHRV,
                stagesJSON: encodeStages(s.stages),
                // Stamp the day's motion-coverage verdict on every session so the Sleep tab can caption a sparse
                // night (#345). Zoop-computed nights are always true/false; imported nights never reach this path and keep nil.
                stagingSparse: gravitySparse)
        }

        // Per-session per-epoch motion (H8): the strap's movement on the same 30 s grid as the stages, for the
        // caller to persist beside `stagesJSON`. A session that cannot grid is omitted so the caller persists NULL.
        var sessionMotionByStart: [Int: [Double]] = [:]
        for s in matched {
            let motion = SleepStager.sessionEpochMotion(start: s.start, end: s.end, grav: gravity)
            if !motion.isEmpty { sessionMotionByStart[s.start] = motion }
        }

        // Per-session per-epoch band sleep_state (#175): the strap's own state (the `bandSleepState` samples
        // the re-onset guard consumes) gridded onto each session's 30 s epochs, for the caller to persist.
        // A session without band samples is omitted (NULL stays NULL). Empty on a WHOOP 4.0. Carried
        // verbatim; it only confirms a borderline re-onset and never overrides the hypnogram.
        var sessionSleepStateByStart: [Int: [Int]] = [:]
        if !bandSleepState.isEmpty {
            for s in matched {
                let states = SleepStager.sessionEpochSleepState(start: s.start, end: s.end,
                                                                sleepState: bandSleepState)
                if !states.isEmpty { sessionSleepStateByStart[s.start] = states }
            }
        }

        // Per-score confidence tiers
        let chargeConfidence = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines.hrv)
        let effortConfidence = ScoreConfidence.effort(strain: strain, hrSampleCount: hr.count)
        // Rest confidence: a high-efficiency night with implausibly low deep+REM share downgrades to low
        // confidence (likely staging miss). `stageCoverage` adds a third guard: a timeline covering only part
        // of its span (an incompletely received device hypnogram) cannot earn a solid Rest.
        let restConfidence = ScoreConfidence.rest(hasSession: !matched.isEmpty,
                                                  hasStagedSleep: hasStagedSleep,
                                                  asleepSeconds: tstS, restorativeSeconds: deepS + remS,
                                                  efficiency: efficiency, gravitySparse: gravitySparse,
                                                  stageCoverage: stageCoverage)

        return DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                         workouts: workouts, recovery: recovery, strain: strain,
                         nightlySkinTempC: nightlySkinTempC,
                         restScore: restScore,
                         chargeConfidence: chargeConfidence,
                         effortConfidence: effortConfidence,
                         restConfidence: restConfidence,
                         sessionMotionByStart: sessionMotionByStart,
                         sessionSleepStateByStart: sessionSleepStateByStart,
                         chargeDrivers: chargeDrivers,
                         skinTempRelative: skinTempRelative,
                         detectionFunnel: detectionFunnel,
                         mainNightBlocks: mainGroup.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) })
    }

    /// The R-R rows the always-on `hrv diag` line describes (#2425). Pure. The line reads the main-night
    /// group (`DayResult.mainNightBlocks`) over the gate's own inclusive `[start, end]` window, so on a
    /// one-block night it is exactly the beat set `SleepStager.sessionHrvOverCounted` judged and the
    /// over-count half of the verdict cannot disagree with the gate. A bridged multi-fragment night spans
    /// its bridge gap, which can only pull coverage down. A day with no main night uses the pooled
    /// `fallback` set.
    public static func hrvDiagnosticRows(_ rr: [RRInterval], mainNight: [SleepStageTotals.NightBlock],
                                         fallback: [SleepStageTotals.NightBlock]) -> [RRInterval] {
        if mainNight.isEmpty {
            return rr.filter { r in fallback.contains { r.ts >= $0.start && r.ts < $0.end } }
        }
        return rr.filter { r in mainNight.contains { r.ts >= $0.start && r.ts <= $0.end } }
    }

    // MARK: - Rest composite (Charge/Effort/Rest)

    /// The 0-100 Rest score (Sleep ring / Sleep screen). Composite of four components:
    /// - duration vs personal need (0.45): hours asleep / need, clamped to 1.0, raised to
    ///   `durationExponent` (1.5) so a short night costs more than linearly (6 h of 8 h gives 0.65).
    /// - efficiency (0.20): asleep / in-bed mapped onto [`efficiencyFloor`, `efficiencyFull`]
    ///   (65% to 0, 95% to 1), not the raw ratio.
    /// - restorative share (0.20): (deep + REM) / asleep clamped to a 0.50 target, scaled by deep adequacy.
    /// - consistency (0.15): duration regularity across recent nights and/or distance of this night's
    ///   midsleep from the habitual midsleep (`timingConsistency`). With neither signal the term is left
    ///   out and the other weights are renormalised.
    /// Sub-scores clamp to [0,1]; the weighted sum scales to [0,100].
    ///
    /// The mapping spreads nights that raw efficiency and a linear duration term used to park in 85-95
    /// (a 5.5 h night in 8.2 h in bed reads ~50, a full efficient night ~88-92).
    ///
    /// Deep-sleep honesty: when `deepSeconds` is supplied, the restorative sub-score is scaled by a gentle
    /// deep-adequacy factor, full credit at `deepShareTarget` (~13% of asleep), ramping to
    /// `deepFloorFactor` (0.5, never zeroed) as deep goes to 0. Unknown deep gives 1.0.
    ///
    /// Approximate and unvalidated against a reference device; constants spread realistic nights and are
    /// not fitted to WHOOP's sleep score.
    public enum Rest {
        /// Default personal sleep need (hours).
        public static let defaultNeedHours: Double = 8.0
        /// Full-marks restorative (deep+REM) share of asleep time.
        public static let restorativeTarget: Double = 0.50
        /// Deep share of asleep time that earns full restorative credit (~13%, the healthy floor).
        public static let deepShareTarget: Double = 0.13
        /// Most the restorative term is scaled down when deep is absent: half, never zero.
        public static let deepFloorFactor: Double = 0.5
        /// Exponent on asleep / need; >1 makes duration convex (0.75 gives 0.65, 0.6875 gives 0.57).
        public static let durationExponent: Double = 1.5
        /// Efficiency at/below which the efficiency term scores 0.
        public static let efficiencyFloor: Double = 0.65
        /// Efficiency at/above which the efficiency term scores 1.
        public static let efficiencyFull: Double = 0.95
        /// Midsleep deviation (minutes) still scored as fully on time.
        public static let timingToleranceMin: Double = 30
        /// Midsleep deviation (minutes) at/after which the timing term scores 0.
        public static let timingZeroMin: Double = 180

        public static let wDuration: Double = 0.45
        public static let wEfficiency: Double = 0.20
        public static let wRestorative: Double = 0.20
        public static let wConsistency: Double = 0.15

        /// Minimum trailing nights before a personal sleep-need estimate is trusted; below it the population
        /// default is used.
        public static let minNeedNights: Int = 7
        /// Cap on personalized need (h).
        public static let maxNeedHours: Double = 9.5

        /// Population target nightly sleep need (hours) for an age (NSF/AASM range midpoint), used as a floor:
        /// the personal estimate only adjusts up for long sleepers, so a chronic under-sleeper's need cannot
        /// drift toward their deficit and erase their sleep debt.
        public static func populationNeedFloorHours(age: Int?) -> Double {
            guard let age, age > 0 else { return 8.0 }   // unknown → adult target
            switch age {
            case ..<18: return 9.0     // children/teens need more (NSF 8–12; target ~9)
            default: return 8.0        // adults (18–64) & older (65+): NSF 7–9, target ~8 (the app default)
            }
        }

        /// Personalized nightly need (hours), anchored to the population target and age-floored. The personal
        /// component is the upper-quartile nightly duration over the trailing window (not the average, which
        /// a chronic deficit drags down), floored at the age target and capped at `maxNeedHours`. Fewer than
        /// `minNeedNights` scorable nights gives the population default. Zero/negative entries are dropped.
        public static func personalizedNeedHours(nightlyHours: [Double], age: Int?) -> Double {
            let floor = populationNeedFloorHours(age: age)
            let xs = nightlyHours.filter { $0 > 0 }.sorted()
            guard xs.count >= minNeedNights else {
                return min(max(defaultNeedHours, floor), maxNeedHours)
            }
            // Linear-interpolated 75th percentile.
            let pos = 0.75 * Double(xs.count - 1)
            let lo = Int(pos), hi = min(lo + 1, xs.count - 1)
            let q = xs[lo] + (pos - Double(lo)) * (xs[hi] - xs[lo])
            return min(max(q, floor), maxNeedHours)
        }

        /// The four sub-scores (each [0,1]) behind `composite`, plus the consistency term used (nil when the
        /// term is left out). Shared by `composite` and the test-mode `subScoreLine`.
        public struct Terms: Equatable {
            public let duration: Double
            public let efficiency: Double
            public let restorative: Double
            public let deepFactor: Double
            public let consistency: Double?
        }

        /// Timing consistency in [0,1] from the distance of a night's midsleep from the habitual midsleep.
        /// Circular over 24 h. Within `timingToleranceMin` gives 1; at/after `timingZeroMin` gives 0; linear between.
        public static func timingConsistency(midsleepSec: Int, habitualMidsleepSec: Int) -> Double {
            let day = 86_400
            var d = abs((midsleepSec - habitualMidsleepSec) % day)
            if d > day / 2 { d = day - d }
            return timingConsistency(deviationMin: Double(d) / 60.0)
        }

        /// `timingConsistency` from a deviation in minutes (sign ignored).
        public static func timingConsistency(deviationMin: Double) -> Double {
            let dev = abs(deviationMin)
            if dev <= timingToleranceMin { return 1.0 }
            if dev >= timingZeroMin { return 0.0 }
            return 1.0 - (dev - timingToleranceMin) / (timingZeroMin - timingToleranceMin)
        }

        /// The sub-scores `composite` weighs; see `Rest`.
        public static func terms(tstSeconds: Double,
                                 efficiency: Double,
                                 restorativeSeconds: Double,
                                 needHours: Double,
                                 consistency: Double?,
                                 deepSeconds: Double? = nil,
                                 timingConsistency: Double? = nil) -> Terms {
            func clamp01(_ x: Double) -> Double { max(0.0, min(1.0, x)) }
            let needSeconds = max(needHours, 0.1) * 3600.0
            let duration = pow(clamp01(tstSeconds / needSeconds), durationExponent)
            let eff = clamp01((efficiency - efficiencyFloor) / (efficiencyFull - efficiencyFloor))
            // Deep-adequacy factor in [deepFloorFactor, 1]; nil deep gives 1.0.
            let deepFactor: Double = {
                guard let deep = deepSeconds, tstSeconds > 0, deepShareTarget > 0 else { return 1.0 }
                let adequacy = clamp01((deep / tstSeconds) / deepShareTarget)
                return deepFloorFactor + (1.0 - deepFloorFactor) * adequacy
            }()
            let restorative = tstSeconds > 0
                ? clamp01((restorativeSeconds / tstSeconds) / restorativeTarget) * deepFactor
                : 0.0
            // Mean of whichever regularity signals the caller has; neither gives nil (term omitted).
            let signals = [consistency, timingConsistency].compactMap { $0 }.map(clamp01)
            let cons: Double? = signals.isEmpty ? nil : signals.reduce(0, +) / Double(signals.count)
            return Terms(duration: duration, efficiency: eff, restorative: restorative,
                         deepFactor: deepFactor, consistency: cons)
        }

        /// Build the composite. `tstSeconds` is total sleep, `restorativeSeconds` deep+REM, `deepSeconds`
        /// deep only (nil: no deep adjustment). `consistency` is duration regularity, `timingConsistency` comes
        /// from `timingConsistency(midsleepSec:habitualMidsleepSec:)`; with neither, the weight is
        /// redistributed. `inBedSeconds` is kept for call-site stability. Returns [0,100], 2 dp.
        public static func composite(tstSeconds: Double,
                                     inBedSeconds: Double,
                                     efficiency: Double,
                                     restorativeSeconds: Double,
                                     needHours: Double,
                                     consistency: Double?,
                                     deepSeconds: Double? = nil,
                                     timingConsistency: Double? = nil) -> Double {
            let t = terms(tstSeconds: tstSeconds, efficiency: efficiency,
                          restorativeSeconds: restorativeSeconds, needHours: needHours,
                          consistency: consistency, deepSeconds: deepSeconds,
                          timingConsistency: timingConsistency)
            var weighted = wDuration * t.duration + wEfficiency * t.efficiency + wRestorative * t.restorative
            var totalWeight = wDuration + wEfficiency + wRestorative
            if let c = t.consistency {
                weighted += wConsistency * c
                totalWeight += wConsistency
            }
            let score = totalWeight > 0 ? weighted / totalWeight : 0
            return (score * 10000.0).rounded() / 100.0
        }

        /// Sleep sufficiency in [0,1]: asleep / personal need, capped at 1. WHOOP's published "sleep performance",
        /// and the sleep term Charge is scored with in Zoop; the Rest composite stays the Sleep ring's score.
        public static func sufficiency(tstSeconds: Double, needHours: Double) -> Double {
            max(0.0, min(1.0, tstSeconds / (max(needHours, 0.1) * 3600.0)))
        }

        /// `sufficiency` from a persisted `DailyMetric`; nil when the day has no sleep.
        public static func sufficiency(daily d: DailyMetric, needHours: Double = defaultNeedHours) -> Double? {
            guard let tstMin = d.totalSleepMin, tstMin > 0 else { return nil }
            return sufficiency(tstSeconds: tstMin * 60.0, needHours: needHours)
        }

        /// Rest composite [0,100] from a persisted `DailyMetric` (the pass-2 / display path); nil without sleep.
        /// Single source of truth for the persisted `sleep_performance` series and the Charge Rest term.
        public static func composite(daily d: DailyMetric, needHours: Double = defaultNeedHours,
                                     consistency: Double? = nil) -> Double? {
            guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
            let tstSec = tstMin * 60.0
            let deepSec = (d.deepMin ?? 0) * 60.0
            let restorativeSec = (d.deepMin ?? 0) * 60.0 + (d.remMin ?? 0) * 60.0
            return composite(tstSeconds: tstSec, inBedSeconds: tstSec / max(eff, 0.01),
                             efficiency: eff, restorativeSeconds: restorativeSec,
                             needHours: needHours, consistency: consistency,
                             deepSeconds: deepSec)
        }
    }

    /// Round to 2 decimal places.
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }

    /// Min worn, in-bed skin-temp samples (1 Hz, so seconds) before a nightly mean is trusted; ~5 min.
    public static let minSkinTempSamples = 300

    /// Plausible worn skin-temperature range (°C); off-wrist/charging samples drift to ambient. The strap's own decode gate is the looser 5-45.
    static let skinTempMinC = 28.0
    static let skinTempMaxC = 42.0

    /// Wear-gated mean in-bed skin temperature (°C), or nil with too few worn samples. A sample counts
    /// when it falls inside an in-bed `sessions` span, a concurrent HR sample reads a worn BPM (HR streams
    /// only on-wrist), and the value is in the plausible range.
    /// The raw to °C conversion is family-aware (#938): 5/MG stores centidegrees (raw/100) in
    /// skin_temp_raw@73, the WHOOP 4.0 v24 field@72 is a raw ADC on a different scale; dividing it by 100
    /// read every worn 4.0 night ~8 °C, under the gate. `skinTempCelsius(raw:family:)` (WhoopProtocol)
    /// picks the scale.
    static func wornNightlySkinTempC(_ sessions: [SleepSession],
                                     hr: [HRSample],
                                     skinTemp: [SkinTempSample],
                                     family: DeviceFamily = .whoop5,
                                     // Per-device WHOOP 4.0 worn anchor raw (#938); nil uses the global `Whoop4SkinTemp.anchorRaw`.
                                     anchorRaw: Double? = nil,
                                     minSamples: Int = minSkinTempSamples,
                                     // Seconds a worn HR sample may sit from a skin-temp sample and still count (#1467); 0 = exact timestamp.
                                     // See `skinTempFunnel` for why a ring needs more.
                                     wornToleranceSec: Int = 0) -> Double? {
        skinTempFunnel(sessions, hr: hr, skinTemp: skinTemp, family: family,
                       anchorRaw: anchorRaw, minSamples: minSamples,
                       wornToleranceSec: wornToleranceSec).mean
    }

    /// Nightly means of the WHOOP 4.0 raw SpO2 PPG channels (red/IR ADC) over the in-bed `sessions`, or
    /// nil when none fell inside a span. Raw device output banked as-is (unit "raw_adc"), not a calibrated
    /// blood-oxygen %. No worn/range gate: the strap streams SpO2 only on-wrist and the value is never scored.
    static func nightlySpo2RawMeans(_ sessions: [SleepSession], spo2: [SpO2Sample]) -> (red: Int, ir: Int)? {
        guard !sessions.isEmpty, !spo2.isEmpty else { return nil }
        var redSum = 0, irSum = 0, kept = 0
        for s in spo2 where sessions.contains(where: { $0.start <= s.ts && s.ts <= $0.end }) {
            redSum += s.red; irSum += s.ir; kept += 1
        }
        guard kept > 0 else { return nil }
        return (red: redSum / kept, ir: irSum / kept)
    }

    /// Nightly gated mean of the 5/MG SpO2 candidate byte (`@82`) over the in-bed `sessions`, with the
    /// sample count it rests on, or nil when no in-band reading fell inside any span (#112, tracking #103).
    ///
    /// The candidate is decoded and stored but never scored: it tracked the WHOOP app on one 8-night check
    /// yet moved the opposite way on the two nights from the strap it was found on, so it cannot be
    /// promoted. This gives one number to compare against the app's figure for the same night; `samples`
    /// travels with the mean because a mean over 11 readings is not the same evidence as one over 1100.
    ///
    /// Gated to `70...100`, the decoder's own in-band window for `spo2_candidate_82`: sub-70 nonzero values
    /// are diagnostic codes and bit-7 values are saturation sentinels.
    ///
    /// Diagnostic only: never writes `spo2Pct` and is not a blood-oxygen reading.
    ///
    /// The mean is rounded, not floored: `sum / kept` on Ints truncates, biasing down by up to 0.99 (97.97
    /// shipped as 97, missing a displayed 98). Values are positive, so round-half-up and
    /// round-half-away-from-zero agree.
    public static func nightlySpo2CandidateMean(_ sessions: [SleepSession],
                                         aux: [V18AuxSample]) -> (mean: Int, samples: Int)? {
        guard !sessions.isEmpty, !aux.isEmpty else { return nil }
        var sum = 0, kept = 0
        for a in aux {
            guard let v = a.auxByte82, (70...100).contains(v) else { continue }
            guard sessions.contains(where: { $0.start <= a.ts && a.ts <= $0.end }) else { continue }
            sum += v; kept += 1
        }
        guard kept > 0 else { return nil }
        return (mean: Int((Double(sum) / Double(kept)).rounded()), samples: kept)
    }

    /// Plausible range for a raw Oura `0x6F` SpO2 sample before the ceiling transform. Excludes the
    /// mis-scaled `dc_raw`/perfusion contamination (-1016 ... 11,709,098, OURA_PROTOCOL.md 6.5.0.1) by three
    /// orders of magnitude; same bounds as `Repository.spo2SingleChannelPlausible`, kept in sync manually
    /// (the app layer cannot be imported here).
    public static let spo2SingleChannelPlausible = 50...110

    /// Nightly ceiling@100 mean of the Oura ring's decoded SpO2 (`spo2Sample.red`, `0x6F`) over the
    /// in-bed `sessions`, with the sample count, or nil when no plausible sample fell inside any span.
    /// Oura counterpart of `nightlySpo2CandidateMean`.
    ///
    /// Why ceiling@100: the raw `0x6F` mean carries a positive bias (20-48% of samples on a clean night
    /// read above the physical 100% ceiling, OURA_PROTOCOL.md 6.5.0.1) and has missed the Oura app's
    /// displayed value on every full-tier paired night measured (n=3). `min(sample, 100)` applied
    /// per-sample before averaging (clamping the aggregate is a different, wrong number) round-matched the
    /// app on all 3, edging the offset-0.32+clamp[85,100] fit (2/3). Not a validated calibration, so per
    /// the derived-biosignal rule it ships diagnostic-only, behind the display toggle, never written to
    /// `spo2Pct` and never scored.
    ///
    /// Gated to `spo2SingleChannelPlausible` (50...110) before the ceiling, so a contaminated row cannot
    /// drag the mean down. Rounded rather than floored for the same reason as `nightlySpo2CandidateMean`.
    public static func nightlySpo2CeilingMean(_ sessions: [SleepSession],
                                        spo2: [SpO2Sample]) -> (mean: Int, samples: Int)? {
        guard !sessions.isEmpty, !spo2.isEmpty else { return nil }
        var sum = 0, kept = 0
        for s in spo2 {
            guard spo2SingleChannelPlausible.contains(s.red) else { continue }
            guard sessions.contains(where: { $0.start <= s.ts && s.ts <= $0.end }) else { continue }
            sum += min(s.red, 100); kept += 1
        }
        guard kept > 0 else { return nil }
        return (mean: Int((Double(sum) / Double(kept)).rounded()), samples: kept)
    }

    /// Shadow metric (#1169): the primary-session mean resting HR. Windows each session's HR to
    /// `[start, end)` and delegates to `PrimarySessionRestingHR.meanHR`. Stored beside the shipped HR floor
    /// (`daily.restingHr`) as "rhr_primary_session": instrumentation only, never shown or scored.
    public static func primarySessionRestingHR(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples) -> Double? {
        PrimarySessionRestingHR.meanHR(sessions: primarySessions(sessions: sessions, hr: hr),
                                       validBpm: validBpm, minValidSamples: minValidSamples)
    }

    /// Coverage inputs for the shadow `rhr_primary_session` mean (valid-sample count + primary-session
    /// duration), built from the same inputs as `primarySessionRestingHR`, so nil in lockstep with the mean.
    public static func primarySessionRestingHRCoverage(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples) -> PrimarySessionRestingHR.Coverage? {
        PrimarySessionRestingHR.coverage(sessions: primarySessions(sessions: sessions, hr: hr),
                                         validBpm: validBpm, minValidSamples: minValidSamples)
    }

    /// Window `hr` to each session's `[start, end)` once, the shared input for both the #1169 mean and its coverage (O(sessions x hr), so done once).
    private static func primarySessions(sessions: [SleepSession], hr: [HRSample]) -> [PrimarySessionRestingHR.Session] {
        sessions.map { s in
            PrimarySessionRestingHR.Session(
                durationSec: Double(s.end - s.start),
                bpm: hr.filter { $0.ts >= s.start && $0.ts < s.end }.map { $0.bpm })
        }
    }

    /// The #1169 mean and its coverage from one windowing of `hr`; identical to calling the two separately but windows the samples once.
    public static func primarySessionRestingHRWithCoverage(
        sessions: [SleepSession], hr: [HRSample],
        validBpm: ClosedRange<Int> = PrimarySessionRestingHR.defaultValidBpm,
        minValidSamples: Int = PrimarySessionRestingHR.defaultMinValidSamples)
        -> (mean: Double?, coverage: PrimarySessionRestingHR.Coverage?) {
        let built = primarySessions(sessions: sessions, hr: hr)
        return (PrimarySessionRestingHR.meanHR(sessions: built, validBpm: validBpm, minValidSamples: minValidSamples),
                PrimarySessionRestingHR.coverage(sessions: built, validBpm: validBpm, minValidSamples: minValidSamples))
    }

    // MARK: - Skin-temp funnel diagnostic (#752)

    // Skin-temp absence is opaque (no samples, none in a session span, none worn, out of range, or too
    // few survivors). This read-only funnel re-runs the same gates as `wornNightlySkinTempC` and counts
    // where samples dropped, without changing the mean or any score, so an absent skin temp can be
    // triaged. Logged by the caller (#752).

    /// Why nightly skin temp funneled toward absent for one night. Each raw sample is attributed to the
    /// first gate that dropped it, in `wornNightlySkinTempC`'s order (not-worn, out-of-window, out-of-range,
    /// kept), so the four buckets plus `kept` sum to `totalSamples`. Shares the gate logic with the real
    /// computation.
    public struct SkinTempFunnelDiagnostic: Equatable, Sendable {
        /// Raw skin-temp samples seen for the night.
        public let totalSamples: Int
        /// Dropped: no concurrent worn-HR second (the strap streams HR only on-wrist).
        public let droppedNotWorn: Int
        /// Worn, but in no detected in-bed span.
        public let droppedOutOfWindow: Int
        /// Worn and in-window, but outside the plausible worn range (28-42 °C); likely off-wrist/charging drift.
        public let droppedOutOfRange: Int
        /// Samples that passed every gate.
        public let kept: Int
        /// Minimum kept samples before a nightly mean is trusted.
        public let minSamples: Int
        /// The nightly mean (°C), or nil when `kept < minSamples` or there is no input.
        public let mean: Double?
        // Raw-ADC visibility so an absent WHOOP 4.0 skin temp explains why (anchor mis-map vs no worn data).
        // Pure observations; they do not affect `mean` or the gates.
        /// Min / median / max of the night's raw skin-temp ADC values (nil without samples). The WHOOP 4.0 worn
        /// band is ~550-2040.
        public let rawMin: Int?
        public let rawMedian: Int?
        public let rawMax: Int?
        /// Raw samples inside the worn ADC band (`Whoop4SkinTemp.wornMin...wornMaxRaw`). At least 100 lets the
        /// per-device anchor learn (#938/#404); below that the global 826 anchor is used.
        public let inBandCount: Int
        /// The anchor raw used for the °C map: the caller's per-device anchor, else the global 826; nil on 5/MG.
        public let resolvedAnchorRaw: Double?
        /// °C the median raw maps to under `resolvedAnchorRaw`. Outside 28-42 °C means every worn sample is
        /// gated out (the #404 anchor mis-map signature); nil on 5/MG or without samples.
        public let medianMappedC: Double?

        public init(totalSamples: Int, droppedNotWorn: Int, droppedOutOfWindow: Int,
                    droppedOutOfRange: Int, kept: Int, minSamples: Int, mean: Double?,
                    rawMin: Int? = nil, rawMedian: Int? = nil, rawMax: Int? = nil,
                    inBandCount: Int = 0, resolvedAnchorRaw: Double? = nil, medianMappedC: Double? = nil) {
            self.totalSamples = totalSamples; self.droppedNotWorn = droppedNotWorn
            self.droppedOutOfWindow = droppedOutOfWindow; self.droppedOutOfRange = droppedOutOfRange
            self.kept = kept; self.minSamples = minSamples; self.mean = mean
            self.rawMin = rawMin; self.rawMedian = rawMedian; self.rawMax = rawMax
            self.inBandCount = inBandCount; self.resolvedAnchorRaw = resolvedAnchorRaw
            self.medianMappedC = medianMappedC
        }

        /// True when the night produced no usable mean.
        public var isAbsent: Bool { mean == nil }

        /// Human-readable line(s) for the caller to log; with raw samples, a second `skin-temp-raw:` line shows the ADC band and anchor mapping.
        public var summary: String {
            var s = "skin-temp-funnel: \(totalSamples) samples → kept \(kept)/\(minSamples) "
                + "(mean=\(mean.map { String(format: "%.2f°C", $0) } ?? "absent")); "
                + "dropped[notWorn=\(droppedNotWorn), outOfWindow=\(droppedOutOfWindow), "
                + "outOfRange=\(droppedOutOfRange)]"
            if let lo = rawMin, let mid = rawMedian, let hi = rawMax {
                s += "\nskin-temp-raw: raw[min=\(lo) p50=\(mid) max=\(hi)] inBand=\(inBandCount)/\(totalSamples)"
                if let a = resolvedAnchorRaw, let mapped = medianMappedC {
                    s += String(format: "; anchor=%.0f → p50 maps %.1f°C (worn gate 28–42°C, ADC band 550–2040)",
                                a, mapped)
                }
            }
            return s
        }
    }

    /// Seconds a valid HR sample may sit from a skin-temp sample and still mark it worn, when the caller
    /// opts in via `wornToleranceSec` > 0 (#1467). On a 7-night Oura gap, exact-timestamp co-occurrence left
    /// every night just under `minSkinTempSamples` (155-296 kept of 300) despite 269-675 raw samples,
    /// because the ring's HR and skin-temp channels are independently clocked (only ~40-55% of timestamps
    /// coincide). A +/-2 s window recovered every real night (622-635 kept); this default carries margin.
    public static let defaultOuraWornToleranceSec = 5

    /// Read-only skin-temp funnel for one night (#752). Re-runs the wear/window/range gates of
    /// `wornNightlySkinTempC` (which is a thin wrapper over this, so the two cannot disagree) and counts
    /// where each sample dropped.
    public static func skinTempFunnel(_ sessions: [SleepSession],
                                      hr: [HRSample],
                                      skinTemp: [SkinTempSample],
                                      family: DeviceFamily = .whoop5,
                                      // Per-device WHOOP 4.0 worn anchor raw (#938); nil uses the global `Whoop4SkinTemp.anchorRaw`.
                                      anchorRaw: Double? = nil,
                                      minSamples: Int = minSkinTempSamples,
                                      // Seconds tolerance for the worn match (#1467); 0 = exact timestamp. A device whose HR and skin-temp
                                      // streams are not co-sampled at 1 Hz (an Oura ring) needs more; see `defaultOuraWornToleranceSec`.
                                      // Threaded per owner device so WHOOP behavior is untouched.
                                      wornToleranceSec: Int = 0) -> SkinTempFunnelDiagnostic {
        let total = skinTemp.count
        // Raw-ADC band and resolved anchor: pure observation computed once for both return paths; never touches the mean/gate logic.
        let sortedRaws = skinTemp.map { $0.raw }.sorted()
        let rawMin = sortedRaws.first
        let rawMax = sortedRaws.last
        let rawMedian = sortedRaws.isEmpty ? nil : sortedRaws[sortedRaws.count / 2]
        let inBandCount = family == .whoop4
            ? sortedRaws.filter { $0 >= Whoop4SkinTemp.wornMinRaw && $0 <= Whoop4SkinTemp.wornMaxRaw }.count
            : total
        let usedAnchor: Double? = family == .whoop4 ? (anchorRaw ?? Whoop4SkinTemp.anchorRaw) : nil
        let medianMappedC: Double? = (usedAnchor != nil && rawMedian != nil)
            ? skinTempCelsius(raw: rawMedian!, family: family, anchorRaw: usedAnchor!) : nil
        // No sessions means every sample is out of window; no samples means an empty funnel. The mean is nil either way.
        if sessions.isEmpty || skinTemp.isEmpty {
            return SkinTempFunnelDiagnostic(totalSamples: total, droppedNotWorn: 0,
                                            droppedOutOfWindow: sessions.isEmpty ? total : 0,
                                            droppedOutOfRange: 0, kept: 0, minSamples: minSamples, mean: nil,
                                            rawMin: rawMin, rawMedian: rawMedian, rawMax: rawMax,
                                            inBandCount: inBandCount, resolvedAnchorRaw: usedAnchor,
                                            medianMappedC: medianMappedC)
        }
        // Tolerance 0 keeps the exact-second Set lookup (every WHOOP night). Tolerance > 0 sorts the valid HR
        // timestamps once and binary-searches the nearest per skin-temp sample, O(hr log hr + skinTemp log hr)
        // rather than O(hr x skinTemp).
        let wornSeconds: Set<Int>?
        let sortedValidHrTs: [Int]?
        if wornToleranceSec <= 0 {
            var s = Set<Int>(minimumCapacity: hr.count)
            for h in hr where (30...220).contains(h.bpm) { s.insert(h.ts) }
            wornSeconds = s
            sortedValidHrTs = nil
        } else {
            wornSeconds = nil
            sortedValidHrTs = hr.filter { (30...220).contains($0.bpm) }.map { $0.ts }.sorted()
        }
        // True when some valid HR reading sits within `wornToleranceSec` of `ts` (inclusive).
        func isWorn(_ ts: Int) -> Bool {
            if let wornSeconds { return wornSeconds.contains(ts) }
            guard let sortedValidHrTs, !sortedValidHrTs.isEmpty else { return false }
            var lo = 0, hi = sortedValidHrTs.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let d = sortedValidHrTs[mid] - ts
                if abs(d) <= wornToleranceSec { return true }
                if d < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return false
        }
        var sum = 0.0
        var kept = 0
        var notWorn = 0, outOfWindow = 0, outOfRange = 0
        for t in skinTemp {
            if !isWorn(t.ts) { notWorn += 1; continue }
            if !sessions.contains(where: { t.ts >= $0.start && t.ts <= $0.end }) { outOfWindow += 1; continue }
            // WHOOP 4.0 only (#938): drop raws outside the plausible worn ADC band before the anchor map. The
            // no-contact floor (~509) and the 11-bit saturation ceiling (2047) are doff/charging transients that,
            // with a per-device anchor, could map into 28-42 °C and poison the mean. Counted in the same
            // `outOfRange` bucket so the buckets still sum to totalSamples.
            if family == .whoop4,
               t.raw < Whoop4SkinTemp.wornMinRaw || t.raw > Whoop4SkinTemp.wornMaxRaw {
                outOfRange += 1; continue
            }
            // Per-device anchor (#938): nil anchorRaw uses the global `Whoop4SkinTemp.anchorRaw` (826); `.whoop5` ignores it.
            let c = skinTempCelsius(raw: t.raw, family: family, anchorRaw: anchorRaw ?? Whoop4SkinTemp.anchorRaw)
            if c < skinTempMinC || c > skinTempMaxC { outOfRange += 1; continue }
            sum += c
            kept += 1
        }
        let mean = kept >= minSamples ? sum / Double(kept) : nil
        return SkinTempFunnelDiagnostic(totalSamples: total, droppedNotWorn: notWorn,
                                        droppedOutOfWindow: outOfWindow, droppedOutOfRange: outOfRange,
                                        kept: kept, minSamples: minSamples, mean: mean,
                                        rawMin: rawMin, rawMedian: rawMedian, rawMax: rawMax,
                                        inBandCount: inBandCount, resolvedAnchorRaw: usedAnchor,
                                        medianMappedC: medianMappedC)
    }
}
