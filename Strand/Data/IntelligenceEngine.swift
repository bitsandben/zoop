import Dispatch
import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device scoring: computes recovery, day-strain and sleep from raw strap streams (HRV vs personal
/// baseline ~60%, resting HR ~20%, sleep ~15%, respiration ~5%; strain 0-21 from cardiovascular load), so
/// Zoop scores any day with raw data itself rather than trusting imported CSV values.
@MainActor
final class IntelligenceEngine: ObservableObject {
    /// Minimum raw HR samples a day needs before it is scored. Spelled `IntelligenceEngine.minHrSamples` at
    /// use sites (not `Self.`) inside the `Task.detached` closure to avoid dynamic-Self capture questions.
    static let minHrSamples = 200

    private let dayCycleCache = DayCycleIntelligenceIntegration.Cache()
    private let repo: Repository
    private let profile: ProfileStore
    /// Canonical id (stable "my-whoop") under whose `-noop` sibling the computed daily rows are written and
    /// the imported-only baseline (`hist`) is read. It must not follow the active strap, or a remove and
    /// re-add would orphan computed history (#814). Per-day owner resolution (`resolveDayOwner`) reads the
    /// registry's active id for raw streams; the Repository union read surfaces both.
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    /// #899: a `force: true` recompute arriving while a pass holds the `computing` lock is queued rather
    /// than dropped; the in-flight pass's `defer` re-invokes `analyzeRecent` once (the queue is cleared
    /// first, so at most one extra pass). The queue keeps the callers' fingerprint gate so it cannot become
    /// an unconditional full pass.
    private var pendingRescore: QueuedRescore?
    /// Uptime the pass holding `computing` started at, and how many days it covers; nil when none is running.
    private var runningPassStart: UInt64?
    private var runningPassDays = 0
    /// #899 heal bound: true while the last heal already re-armed a rescore, so a heal on the next pass
    /// cannot re-arm again (hard-bounded to one re-pass). Reset by any pass whose heal finds nothing.
    private var healRearmedThisCycle = false

    /// #1005 battery: per-day reuse for `analyzeRecent` pass 1, day -> (cache key, scored `DayScan`). A
    /// post-offload only adds rows to the 1-2 newest days, yet every re-score re-read all nights (heavy
    /// users: ~4.6 min/pass). A night whose scored inputs are unchanged reproduces a byte-identical
    /// `DayScan`, so it is reused.
    /// Fail-safe: any miss, un-cacheable owner, active Test-Centre trace or config change takes the full
    /// path; only the analyzeDay stage is skipped (pass 2 is unaffected). In memory, per device, never
    /// persisted or backed up. See `AnalyzeRecentDayCache`.
    private var dayScanCache: [String: (key: String, scan: DayScan)] = [:]
    /// UserDefaults key holding the persisted `stepsMotionCache` payload. Versioned in the key as well as
    /// in the payload header so a format change cannot even be read, let alone half-parsed.
    private static let stepsMotionCacheDefaultsKey = "analyzeRecent.stepsMotionCache.v1"
    /// Whether this process has seeded `stepsMotionCache` from its defaults key. Read once per process:
    /// afterwards the in-memory cache is at least as fresh as the payload.
    private var stepsMotionCacheLoaded = false
    /// The payload currently in UserDefaults, so an unchanged cache is not rewritten (~4 KB per pass in
    /// back-to-back offload-storm passes).
    private var stepsMotionCachePersisted = ""
    /// Per-day steps-calibration motion folds `[day: (key, motion)]`, keyed by `StepsMotionCache.cacheKey`.
    /// In memory like `dayScanCache`; pruned to the calibration window each pass.
    private var stepsMotionCache: [String: (key: String, motion: Double)] = [:]
    /// Scoring-config signature the `dayScanCache` entries were produced under (profile, baselines, tz,
    /// sleep need/consistency, habitual midsleep, stager toggles). These feed `analyzeDay` but are
    /// pass-global, so a differing signature drops the whole cache. Empty until the first pass.
    private var dayScanCacheConfigSig = ""

    /// Names of the config-signature fields, in the order `dayCacheConfigSig` builds them. The two must
    /// stay in step; `changedConfigField` refuses to guess when they are not.
    /// `nonisolated` so synchronous tests can reach it (the engine is @MainActor); `[String]` is Sendable.
    nonisolated static let dayCacheConfigFields: [String] = [
        "hrvBaseline", "rhrBaseline", "age", "sex", "stepTicksPerStep", "maxHROverride",
        "tzOffset", "sleepNeedHours", "sleepConsistency", "habitualMidsleep",
        "experimentalSleepV2", "motionAwareWake", "deepHrvWindow", "spo2CandidateDisplay",
        "effortMethod", "dayCycleMode", "scoringRecipe",
    ]

    /// Zoop scoring-recipe tag. Bump it whenever a change alters what a re-score writes without moving raw
    /// data, so the per-day cache and idle-tick watermark stop serving the old recipe.
    /// v1: weighted overnight HRV and sleep sufficiency as Charge's sleep term. v2: nap bar runs
    /// 08:00-21:00. v3: HR-confirmed sleep onset and the spread-out Rest recipe.
    nonisolated static let scoringRecipe = "zoop-charge-v3"

    /// Which config field(s) moved between two signatures, for the `configDropped` tally. Never guesses:
    /// "first" on a process's first drop (the signature starts empty) and "unknown" when the field count
    /// differs from the list. `nonisolated` as a pure function so synchronous tests can drive it.
    nonisolated static func changedConfigField(previous: String, current: String) -> String {
        if previous.isEmpty { return "first" }
        let a = previous.split(separator: "|", omittingEmptySubsequences: false)
        let b = current.split(separator: "|", omittingEmptySubsequences: false)
        guard a.count == b.count, b.count == dayCacheConfigFields.count else { return "unknown" }
        let moved = b.indices.filter { a[$0] != b[$0] }.map { dayCacheConfigFields[$0] }
        return moved.isEmpty ? "none" : moved.joined(separator: "+")
    }

    /// The `stages=` token of the per-day sleep diagnostic line (#386): `<deep>+<rem>+<light>=<sum>` in
    /// rounded minutes, or nil when any component is absent. The sum is printed so a rollup-vs-stages
    /// divergence is a one-line check against `totalSleepMin=`. Pure.
    static func sleepStagesLogToken(deep: Double?, rem: Double?, light: Double?) -> String {
        guard let deep, let rem, let light else { return "nil" }
        return "\(Int(deep.rounded()))+\(Int(rem.rounded()))+\(Int(light.rounded()))=\(Int((deep + rem + light).rounded()))"
    }

    enum DaySource: Equatable {
        case computed
        case whoopImport
        case appleHealth

        /// The badge shown on the By-Day card. Brand wording matches the rest of the app
        /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
        var badge: String {
            switch self {
            case .computed:    return String(localized: "On-device")
            case .whoopImport: return "Whoop"
            case .appleHealth: return "Apple Health"
            }
        }

        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            case .appleHealth: return "imported:apple"
            }
        }

        /// Resolves a day's provenance from the imported day-key sets: a WHOOP export wins the dashboard
        /// merge, then Apple Health (matching DailyMetricSource.vitalPriority), otherwise computed. Pure
        /// and set-based; the same logic `analyzeRecent` ships.
        static func classify(day: String, importedWhoopDays: Set<String>,
                             appleHealthDays: Set<String>) -> DaySource {
            if importedWhoopDays.contains(day) { return .whoopImport }
            if appleHealthDays.contains(day) { return .appleHealth }
            return .computed
        }
    }

    /// One day's off-actor scan output: the pure `AnalyticsEngine.DayResult` plus the precomputed RHR
    /// floor-vs-mean diagnostic line (#691), replayed through the MainActor `diagnosticSink` in per-day
    /// order. Deliberately not `Sendable` (DayResult is not formally Sendable; the project builds with
    /// minimal strict concurrency).
    private struct DayScan {
        let result: AnalyticsEngine.DayResult
        let rhrLine: String?
        let rhrBinLine: String?
        let respLine: String?
        /// The resolved read owner id this day was scored from and its HR row count for the night window,
        /// for the `dayOwner` self-diagnostic emitted on the main actor (#814/#799).
        let readOwner: String
        let hrRows: Int
        let sleepTrace: [String]
        /// Steps test-mode raw-counter trace lines (5/MG cumulative series, wrap-aware deltas), replayed
        /// tagged `.steps`. Empty unless Steps mode is active; recomputes the same wrap-aware sum
        /// analyzeDay computed.
        let stepsTrace: [String]
        let hrvTrace: [String]
        /// #195: always-on whole-night HRV cleaning summary (`hrv diag`), built off-main where `rr` is in
        /// scope; nil when the night has no in-sleep R-R.
        let hrvDiag: String?
        /// Nightly SpO2 candidate mean, computed when the candidate toggle is on. WHOOP: the
        /// `spo2_candidate_82` V18Aux byte mean; Oura: the ceiling@100 `0x6F` mean
        /// (`AnalyticsEngine.nightlySpo2CeilingMean`). nil when off or no in-band reading. Written as
        /// "spo2_candidate" under the "-zoop" device id in pass 2.
        let spo2Candidate: Int?
        /// #1118: whether the night's in-sleep R-R is over-counted (`crossSecondOverCount` /
        /// `sameSecondOverCount`), the WHOOP 4.0 two-optical-channel artifact that inflates R-R. nil when
        /// no in-sleep R-R. Persisted as "hrv_rr_overcount" (1/0) so the HRV card can flag the reading
        /// unverified.
        let hrvOverCounted: Bool?
        /// #1169 shadow metric: primary-session mean resting HR (#1174) beside the shipped nightly HR
        /// floor; nil when no session clears coverage. Written as "rhr_primary_session"; instrumentation
        /// only, never shown or scored.
        let primarySessionRHR: Double?
        /// #1169 coverage inputs for the shadow mean (valid samples, primary-session duration); nil in
        /// lockstep with `primarySessionRHR`.
        let primarySessionRHRCoverage: PrimarySessionRestingHR.Coverage?
    }

    /// Exact pre-upgrade R-R-derived cells retained only while an unlabelled WHOOP 5 window is withheld.
    private struct LegacyScoreSnapshot {
        let avgHrv: Double
        let recovery: Double?
        let respRateBpm: Double?
        let avgSdnn: Double?
        let recoverySource: String?
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        /// Real provenance of the day's dashboard headline (computed vs an import that won the merge), so
        /// the By-Day badge is honest. Set per day in `analyzeRecent`.
        var source: DaySource = .computed
        /// Charge confidence. `.solid` for a strap-scored night; the Apple-Watch fold sets `WatchRecovery`
        /// confidence so watch-only recovery reads "calibrating" until enough nights.
        var confidence: ScoreConfidence = .solid
        /// Shared engine/UI contract: ordered "what shaped it" Charge drivers, biggest mover first
        /// (`RecoveryScorer.chargeDrivers`). Empty with no score or for non-strap rows; the UI gates on
        /// that.
        var drivers: [ChargeDriver] = []
        /// Skin temperature as a relative deviation from the personal baseline
        /// (`RecoveryScorer.skinTempRelative`), or nil. Never a fake clinical absolute.
        var skinTempRel: SkinTempRelative? = nil
        var id: String { day }

        func withLegacyScore(hrv: Double, recovery: Double?) -> Computed {
            Computed(day: day, recovery: recovery, strain: strain, sleepMin: sleepMin, hrv: hrv, rhr: rhr,
                     source: source, confidence: confidence, drivers: drivers, skinTempRel: skinTempRel)
        }
    }

    /// Optional sink for the per-day scoring diagnostic, fed into the shareable strap log (PII-scrubbed by
    /// `LiveState.append(log:)`). Lines are counts-only summaries, optionally tagged with a TestDomain.
    /// `AppModel` wires it to `live.append(log:domain:)`; nil keeps the engine testable without UI.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    // The engine intentionally has no `adoptActiveDeviceId`: its write target (`deviceId + "-zoop"`) and
    // imported-baseline read stay on the canonical "my-whoop" so a remove and re-add never orphans computed
    // history (#814). The Repository unions it with the active strap's live data at read time.

    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Diagnostic line for the night's computed respiratory rate (breaths/min) or "nil" (#1331). When nil
    /// it carries why: the RSA estimate needs beat-accurate R-R, and `HRVAnalyzer.beatValuesAreTrustworthy`
    /// refuses streams that are not (notably WHOOP 4.0 with the #1008/#1118 over-count). Below the boundary
    /// the gate refused; at or above it another estimator exit applied, which this does not guess. Omitting
    /// `beatAccurate` restores the original one-field line. Must match Android `respRateLogLine` byte for
    /// byte.
    nonisolated static func respRateLogLine(day: String,
                                            respRateBpm: Double?,
                                            beatAccurate: Double? = nil,
                                            rrIntegrity: String? = nil) -> String {
        let base = "resp day=\(day) rpm=\(respRateBpm.map { String(format: "%.1f", $0) } ?? "nil")"
        guard respRateBpm == nil, let beatAccurate else { return base }
        // "NaN" spelled explicitly: C-style %f renders non-finite as "nan" and the JVM as "NaN", so the
        // twin lines would differ.
        let acc = beatAccurate.isNaN ? "NaN" : String(format: "%.2f", beatAccurate)
        let gate = String(format: "%.2f", HRVAnalyzer.beatAccuracyMinFraction)
        let integrity = rrIntegrity ?? "unknown"
        if beatAccurate < HRVAnalyzer.beatAccuracyMinFraction {
            return "\(base) beatAccurate=\(acc)<\(gate) rrIntegrity=\(integrity) — RSA gate refused the R-R"
        }
        return "\(base) beatAccurate=\(acc)>=\(gate) rrIntegrity=\(integrity) — gate passed, cause is elsewhere"
    }

    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = Zoop RHR; mean = sleeping-HR-app number)"
    }

    /// End of the window the sleep pipeline reads for the night finishing on `dayStart`'s day. A past day
    /// reads to the next local midnight (late sleepers, shift workers); a fixed 18:00 bound truncated reads
    /// and reported a flat 18:00 wake (#500). Today is capped at `now`, since a day-sleeper can still be
    /// asleep past 18:00 and the night would re-score to the real time at midnight.
    nonisolated static func sleepReadWindowEnd(dayStart: Int, nowLocalMidnight: Int, now: Int) -> Int {
        let nextMidnight = dayStart + 86_400
        return dayStart < nowLocalMidnight ? nextMidnight : min(nextMidnight, now)
    }

    /// The provided session the NO-NIGHT line reports as `providedLongest`: the longest, ties broken by
    /// later END. The tie-break matters because `Array.max(by:)` and Kotlin's `maxByOrNull` disagree on
    /// equal elements, and equal durations are common (the HR-only spine works in fixed epochs), which
    /// would make the line differ across platforms. Pure and `nonisolated`; twin of Kotlin
    /// `longestProvidedForDiag`.
    nonisolated static func longestProvidedForDiag(_ sessions: [SleepSession]) -> SleepSession? {
        return sessions.max(by: { ($0.end - $0.start, $0.end) < ($1.end - $1.start, $1.end) })
    }

    /// Folds the per-day diagnostic lines onto the one channel already replayed on the main actor.
    /// `hrvDiag` is the loop-1 diagnostic channel (split on newlines): built where inputs are in scope,
    /// emitted where the sink is safe to touch.
    nonisolated static func mergedDayDiag(_ hrvDiag: String?, _ extra: [String]) -> String? {
        var parts: [String] = []
        if let hrvDiag, !hrvDiag.isEmpty { parts.append(hrvDiag) }
        parts.append(contentsOf: extra)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated static func sleepDetectNoNightLogLine(day: String, hrCount: Int, rrCount: Int,
                                                      respCount: Int, gravCount: Int, stepCount: Int,
                                                      providedCount: Int, providedEndingOnDay: Int,
                                                      providedLongestMin: Int?,
                                                      providedLongestEndDay: String?,
                                                      windowHours: Int,
                                                      skinCount: Int) -> String {
        // `reason` names which absence this is. Since #1801 a no-gravity day also runs
        // `SleepStager.hrOnlySessions`, so grav=0 alone no longer means nothing was attempted. The
        // no-gravity case splits:
        // no-motion: no gravity and nothing provided
        // no-motion-provided-unused: sessions were provided yet no night came out (a question about what
        // dropped them, not the strap)
        // Says "provided", not "HR-only": the source is indistinguishable here; the `[sleep] hr-only gate`
        // trace says which branch ran.
        let reason: String
        if gravCount > 0 {
            reason = "staged-none"
        } else {
            reason = providedCount > 0 ? "no-motion-provided-unused" : "no-motion"
        }
        // #1118: name any stream that came back at its read cap. A read returning exactly the limit is
        // truncated (`full.count >= limit`), which counts alone cannot reveal. Gravity needs it most:
        // unlike HR and R-R (SlidingStreamWindow counts its own truncations) it has no counter.
        var atCap: [String] = []
        // Only the plain reads (gravity, skin). HR and R-R arrive via `SlidingStreamWindow.rows`, a slice
        // that can sit under the cap even when truncated, so the marker would falsely stay quiet; their
        // truncation count is logged per pass by `WindowedStreamPlan.logLine`. resp and steps stay
        // unmarked: neither is a staging input.
        if gravCount >= StreamReadCap.gravity { atCap.append("grav") }
        if skinCount >= StreamReadCap.skin { atCap.append("skin") }
        let capNote = atCap.isEmpty ? "" : " atCap=" + atCap.joined(separator: ",")
        // Where the provided sessions fall, which `provided=` alone does not say. A session is attributed
        // to the day it ends on (`AnalyticsEngine.analyzeDay`, `tsInDay(it.end)`), so `provided=3` with an
        // empty night means they ended elsewhere. `providedHere` is the count that ended on this day; 0
        // beside a non-zero `provided` is the diagnosis. `providedLongestEnd` equal to `day` with
        // `providedHere` 0 points at the filter. Emitted only when something was provided.
        let providedNote: String
        if providedCount > 0 {
            providedNote = " providedHere=\(providedEndingOnDay)"
                + " providedLongest=\(providedLongestMin.map(String.init) ?? "nil")"
                + " providedLongestEnd=\(providedLongestEndDay ?? "nil")"
        } else {
            providedNote = ""
        }
        return "sleep-detect day=\(day) NO-NIGHT hr=\(hrCount) rr=\(rrCount) resp=\(respCount) "
            + "grav=\(gravCount) skin=\(skinCount) steps=\(stepCount) provided=\(providedCount)"
            + providedNote + " "
            + "window=\(windowHours)h reason=\(reason)" + capNote
    }

    /// Divergence line (#674/#1244): a computed day whose scoring matched zero sessions yet carries a
    /// non-nil totalSleepMin, from a folded edited/hand-logged block (sleepEditedDaily). That total leaks
    /// to Today while the Sleep tab shows nothing. `editFold` counts the rows folded onto the session-less
    /// day. Counts only. Must match Android `sleepDivergenceLogLine`.
    nonisolated static func sleepDivergenceLogLine(day: String, totalSleepMin: Int, editFold: Int) -> String {
        return "sleep divergence day=\(day) totalSleepMin=\(totalSleepMin) matched=0 editFold=\(editFold)"
    }

    /// Device ids the banked-sleep heal (#899) must sweep: the computed-scores id and every registered id
    /// (#1248). A live source such as an Oura ring banks its own hypnogram under its own id, which a
    /// computedId-only heal never collapsed (one night became 14 rows). De-duplicated and sorted for
    /// determinism. Must match Android `healDeviceIds`.
    nonisolated static func healDeviceIds(computedId: String, registeredIds: [String]) -> [String] {
        Set([computedId] + registeredIds).sorted()
    }

    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// Assesses Fitness Age readiness from the last 7 of `gateDays` (merged history up to `satKey`, up to
    /// 30 days; baselines are 30-day medians) and, when ready, builds the fitness_age points: age,
    /// per-factor weighted years, inputs and the VO2max estimate. Empty when not ready. The single
    /// gate+compute shared by the recompute pass, the manual refresh and the history backfill.
    static func fitnessAgeRows(
        gateDays: [DailyMetric], age: Int, sex: String, waistCm: Double, heightCm: Double, weightKg: Double,
        computedId: String, satKey: String, measuredVO2: Double? = nil, bodyFatPct: Double? = nil,
    ) -> [MetricPoint] {
        let window = Array(gateDays.sorted { $0.day < $1.day }.suffix(30))
        let last7 = window.suffix(7)
        let rhrs = window.compactMap { $0.restingHr }.map(Double.init)
        let strains = window.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let activeDaysPerWeek = Int((Double(strains.count) * 7 / Double(max(window.count, 7))).rounded())
        let waist: Double? = waistCm > 0 ? waistCm : nil
        let ready = FitnessAgeEngine.assessReadiness(
            hasAge: age > 0, hasSex: !sex.isEmpty,
            rhrDays: last7.compactMap { $0.restingHr }.count, activityDays: last7.compactMap { $0.strain }.count,
            hasHeightWeight: heightCm > 0 && weightKg > 0, hasWaist: waist != nil)
        guard ready.canCompute, !rhrs.isEmpty else { return [] }
        let rhr = medianOf(rhrs)
        let pai = FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: activeDaysPerWeek, meanActiveStrain: meanStrain)
        let hrvs = window.compactMap { $0.avgHrv }.filter { $0 > 0 }
        let nights = window.compactMap { $0.totalSleepMin }.map { $0 / 60 }.filter { $0 > 0 }
        let bmi: Double? = heightCm > 0 && weightKg > 0
            ? FitnessAgeEngine.bmi(weightKg: weightKg, heightCm: heightCm) : nil
        let nes: Double? = waist.map {
            FitnessAgeEngine.estimateVO2max(age: Double(age), sex: sex, waistCm: $0, restingHR: rhr, paIndex: pai)
        }
        // A measured VO₂max (Apple Health) wins over the Nes estimate; the HR-only Uth estimate is never
        // used for the age because resting HR already has its own factor.
        let vo2ForAge = measuredVO2 ?? nes
        let inputs = FitnessAgeInputs(
            chronoAge: Double(age), sex: sex, restingHR: rhr,
            vo2max: vo2ForAge, vo2Source: measuredVO2 != nil ? .measured : .nesEstimate,
            rmssd: hrvs.isEmpty ? nil : medianOf(hrvs), activityIndex: pai,
            bmi: bmi, bodyFatPct: bodyFatPct,
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights))
        guard let res = FitnessAgeEngine.compute(inputs) else { return [] }
        var rows = [MetricPoint(day: satKey, key: "fitness_age", value: res.fitnessAge)]
        for (factor, years) in res.contributions {
            rows.append(MetricPoint(day: satKey, key: factor.contributionKey, value: years))
        }
        if let v = vo2ForAge {
            rows.append(MetricPoint(day: satKey, key: FitnessAgeFactor.vo2max.inputKey, value: v))
            rows.append(MetricPoint(day: satKey, key: FitnessAgeKeys.vo2Measured, value: measuredVO2 != nil ? 1 : 0))
        }
        rows.append(MetricPoint(day: satKey, key: FitnessAgeFactor.restingHR.inputKey, value: rhr))
        if let r = inputs.rmssd { rows.append(MetricPoint(day: satKey, key: FitnessAgeFactor.hrv.inputKey, value: r)) }
        rows.append(MetricPoint(day: satKey, key: FitnessAgeFactor.activity.inputKey, value: pai))
        if let bf = bodyFatPct { rows.append(MetricPoint(day: satKey, key: FitnessAgeKeys.bodyFat, value: bf)) }
        else if let b = bmi { rows.append(MetricPoint(day: satKey, key: FitnessAgeKeys.bmi, value: b)) }
        if let c = inputs.sleepConsistency {
            rows.append(MetricPoint(day: satKey, key: FitnessAgeFactor.sleep.inputKey, value: c))
        }
        // #1391: offer a VO2max without a waist: Nes 2011 waist-based estimate when set, else Uth 2004
        // HR-ratio (15.3 x HRmax/RHR, as the calorie path uses) with Tanaka HRmax. Both persist as
        // "vo2max_est"; the card labels it "Estimated".
        let vo2 = nes
            ?? Calories.vo2maxFor(hrmax: StrainScorer.estimateHRmax([], age: Double(age)).0, restingHR: rhr)
        if let v = vo2 { rows.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
        return rows
    }

    /// The Apple Health inputs of a fitness age ending on `endDay`: the 30-day median measured VO₂max and
    /// the latest body fat of the last 180 days. Pure, so the backfill can slice one fetched series.
    static func fitnessHealthInputs(
        vo2: [(day: String, value: Double)], bodyFat: [(day: String, value: Double)], endDay: String
    ) -> (vo2: Double?, bodyFat: Double?) {
        let from30 = shiftDay(endDay, by: -29), from180 = shiftDay(endDay, by: -179)
        let v = vo2.filter { $0.day >= from30 && $0.day <= endDay && $0.value > 0 }.map(\.value)
        let bf = bodyFat.filter { $0.day >= from180 && $0.day <= endDay && $0.value > 0 }
            .max { $0.day < $1.day }?.value
        return (v.isEmpty ? nil : medianOf(v), bf)
    }

    nonisolated static func shiftDay(_ day: String, by days: Int) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: day), let s = cal.date(byAdding: .day, value: days, to: d) else { return day }
        return fmt.string(from: s)
    }

    private func fitnessHealthSeries() async -> (vo2: [(day: String, value: Double)], bodyFat: [(day: String, value: Double)]) {
        let vo2 = await repo.resolvedSeries(key: "vo2max", source: "apple-health", days: 400).points
            .map { (day: $0.day, value: $0.value) }
        let bf = await repo.resolvedSeries(key: "body_fat", source: "apple-health", days: 400).points
            .map { (day: $0.day, value: $0.value) }
        return (vo2, bf)
    }

    /// Fitness age rows for `satKey` from the merged daily history, the profile and Apple Health.
    private func fitnessAgeRows(satKey: String, days: [DailyMetric],
                                health: (vo2: [(day: String, value: Double)], bodyFat: [(day: String, value: Double)])) -> [MetricPoint] {
        let extra = Self.fitnessHealthInputs(vo2: health.vo2, bodyFat: health.bodyFat, endDay: satKey)
        return Self.fitnessAgeRows(
            gateDays: days, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: deviceId + "-zoop",
            satKey: satKey, measuredVO2: extra.vo2, bodyFatPct: extra.bodyFat)
    }

    /// One-shot rewrite of the last 26 weekly fitness ages with the multi-marker model, so the history
    /// chart and the per-factor rows have a past to show. Reads stored dailies only; flagged so it runs once.
    func runFitnessAgeBackfillIfNeeded(weeks: Int = 26) async {
        let flag = "zoop.fitnessAge.multiMarker.v1.done"
        guard !UserDefaults.standard.bool(forKey: flag), profile.age > 0 else { return }
        guard let store = await repo.storeHandle() else { return }
        let tzOffset = TimeZone.current.secondsFromGMT()
        let now = Int(Date().timeIntervalSince1970)
        let today = AnalyticsEngine.dayString(Self.midnightLocal(now, offsetSec: tzOffset), offsetSec: tzOffset)
        let lastSat = Self.saturdayKey(onOrBefore: today)
        let firstSat = Self.shiftDay(lastSat, by: -7 * (weeks - 1))
        let all = await repo.dailyMetrics(fromDay: Self.shiftDay(firstSat, by: -29), toDay: today)
            .sorted { $0.day < $1.day }
        let health = await fitnessHealthSeries()
        var rows: [MetricPoint] = []
        for w in 0..<weeks {
            let sat = Self.shiftDay(firstSat, by: 7 * w)
            let end = w == weeks - 1 ? today : sat
            let from = Self.shiftDay(end, by: -29)
            rows += fitnessAgeRows(satKey: sat, days: all.filter { $0.day >= from && $0.day <= end },
                                   health: health)
        }
        guard !rows.isEmpty else { return }
        do {
            try await store.persistMetricSeriesWithProvenance(
                points: rows.filter { $0.key != "vo2max_est" }, provenance: [], deviceId: deviceId + "-zoop")
            UserDefaults.standard.set(true, forKey: flag)
        } catch {}
    }

    /// Method metadata for a newly computed VO2max point; empty when `points` holds none. Method is
    /// captured at compute time, since changing or removing a waist legitimately switches estimators.
    static func vo2MaxProvenance(
        points: [MetricPoint], waistCm: Double
    ) -> [ScoreInputProvenanceRow] {
        guard let point = points.first(where: { $0.key == "vo2max_est" }) else { return [] }
        return [ScoreInputProvenanceRow(
            day: point.day,
            key: point.key,
            sourceId: Vo2MaxEstimator.forWaistCm(waistCm).rawValue
        )]
    }

    /// Manual "refresh Fitness Age": recomputes the weekly value now from persisted merged daily history
    /// (no raw-HR rescoring) with the same gate (`fitnessAgeRows`) as the recompute pass. Returns true if a
    /// value was written.
    func recomputeFitnessAgeOnly(maxDays: Int = 30) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let computedId = deviceId + "-zoop"
        let now = Int(Date().timeIntervalSince1970)
        let tzOffset = TimeZone.current.secondsFromGMT()
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400, offsetSec: tzOffset)
        let window = await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay)
        let rows = fitnessAgeRows(satKey: Self.saturdayKey(onOrBefore: newestDay), days: window,
                                  health: await fitnessHealthSeries())
        if !rows.isEmpty {
            try? await store.persistMetricSeriesWithProvenance(
                points: rows,
                provenance: Self.vo2MaxProvenance(points: rows, waistCm: profile.waistCm),
                deviceId: computedId
            )
        }
        return !rows.isEmpty
    }

    /// Completion flag for the shared full-history Effort and sleep-wear repair pass.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"

    /// One-shot, on-upgrade full-history Effort rescore (#313 part B) for the move from the 0-21 axis to
    /// Zoop's 0-100 axis. Rows computed by older builds (capped at `maxDays`) may still hold 0-21 strain.
    /// Strain is recomputed from raw HR (no blind x21->100 multiply, which would double-rescale rows
    /// already on 0-100) by running `analyzeRecent` once with the cap lifted, then a flag makes it run
    /// once. Imported rows are never rewritten. Shares a pass with sleep-wear repair; cached-only days are
    /// preserved.
    func runEffortRescoreIfNeeded(historyDays: Int = 4000) async {
        await runHistoryRepairIfNeeded(historyDays: historyDays)
    }

    /// Upgrade repair for nights rejected by an unmatched WRIST_OFF, including history older than 21 days.
    /// Reuses the full-history scoring path (edited/dismissed sleep protection and dependent metrics).
    /// Either pending flag triggers one run and both are set only after every required write succeeds; only
    /// recomputed days are written.
    static let sleepWearRescoreFlagKey = "intelligence.sleepWearRescore.v1.done"
    private var sleepWearRescoreRunning = false

    static func historyRepairIsPending(effortDone: Bool, sleepWearDone: Bool) -> Bool {
        !effortDone || !sleepWearDone
    }

    func runSleepWearRescoreIfNeeded(historyDays: Int = 4000) async {
        await runHistoryRepairIfNeeded(historyDays: historyDays)
    }

    private func runHistoryRepairIfNeeded(historyDays: Int) async {
        guard Self.historyRepairIsPending(
                  effortDone: UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey),
                  sleepWearDone: UserDefaults.standard.bool(forKey: Self.sleepWearRescoreFlagKey)),
              !sleepWearRescoreRunning, !computing, !Task.isCancelled,
              !RescoreBackgroundScheduler.isBackgrounded else { return }
        sleepWearRescoreRunning = true
        defer { sleepWearRescoreRunning = false }
        await analyzeRecent(maxDays: historyDays, triggerLabel: "sleep-wear-history-repair",
                            preserveUnscoredHistory: true) {
            UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey)
            UserDefaults.standard.set(true, forKey: Self.sleepWearRescoreFlagKey)
        }
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 re-pollution re-arm: a strap with a wandering clock keeps re-sending bad-dated records, so when
    /// a sync's ingest gate drops implausible records `BLEManager` sets this flag and the next analyze tick
    /// re-runs the purge, even after the one-shot `done` flag. Plain UserDefaults so the BLE layer needs no
    /// engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Marks the #547 heal for a re-run after a sync dropped bad-clock records; called from
    /// `BLEManager.exitBackfilling`.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547): purges rows dated to
    /// garbage (far past, bogus 2027, future) that re-attributed one ~12h block to every day, then rescores
    /// from surviving raw data. Idempotent; a flag skips it on later launches. Runs before the normal
    /// `analyzeRecent` loop.
    func runTimestampHealIfNeeded(historyDays: Int = 4000) async {
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED , \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        if result.didChange {
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; rescoring the real days.", nil)
            await analyzeRecent(maxDays: historyDays)
            guard !computing else { return }
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Computes on-device scores for each of the last `maxDays` with raw HR data. Personal baselines are
    /// folded from imported history, so even the first live night is scored against your norm.
    func analyzeRecent(maxDays: Int = 21, force: Bool = true, skipIfUnchanged: Bool = false,
                       triggerLabel: String? = nil, preserveUnscoredHistory: Bool = false,
                       onPersisted: (() -> Void)? = nil) async {
        // #899: a concurrent pass holds the lock. A non-forced idle tick is safe to drop; a forced call
        // (post-backfill rescore) is a real update, so re-arm it for the running pass's `defer` to
        // re-invoke once.
        guard !computing else {
            if force {
                // Said once per running pass, not per trigger: a pass that holds the lock for hours otherwise
                // turns every post-offload re-score into a silent no-op, and the log shows syncs but no scores.
                if pendingRescore == nil, let started = runningPassStart {
                    let heldFor = Int(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000)
                    diagnosticSink?("re-score: queued behind a \(runningPassDays)-day pass running for \(heldFor) s", nil)
                }
                pendingRescore = QueuedRescore.merge(
                    pendingRescore, unconditional: !skipIfUnchanged,
                    label: QueuedRescore.triggerName(force: true, skipIfUnchanged: skipIfUnchanged,
                                                     label: triggerLabel))
            }
            return
        }
        // #2607: claim the pass before either store await can admit another MainActor caller; a gate exit
        // must still release the claim and honor a queued forced trigger.
        computing = true
        runningPassStart = DispatchTime.now().uptimeNanoseconds
        runningPassDays = maxDays
        defer {
            computing = false
            runningPassStart = nil
            if let queued = pendingRescore {
                pendingRescore = nil
                let followUpDays = preserveUnscoredHistory ? 21 : maxDays
                Task {
                    await self.analyzeRecent(maxDays: followUpDays, force: true,
                                             skipIfUnchanged: !queued.unconditional,
                                             triggerLabel: queued.label)
                }
            }
        }
        guard let store = await repo.storeHandle() else { note = String(localized: "No on-device store yet."); return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        // #836 idle-tick gate: a cheap whole-history HR fingerprint (count+maxTs plus indexed row
        // frontiers) lets a non-forced caller skip when raw streams are unchanged, avoiding a multi-second
        // re-score every 15-minute tick. All-or-nothing, so window-wide reconciliation is untouched. Every
        // real update path calls with `force: true`.
        // #1392: fingerprint streams across all devices, not the construction-time `deviceId` (pinned to
        // "my-whoop"); the per-device read returned 0 on Oura/Apple Watch/re-added-WHOOP installs. Scoring
        // still reads the registry's active device.
        // The recipe tag rides on the watermark so a scoring change re-scores once. An empty fingerprint
        // stays empty (read as unknown).
        let fingerprint = (try? await store.analysisFingerprint()) ?? ""
        let wmKey = fingerprint.isEmpty ? "" : fingerprint + "|" + Self.scoringRecipe + SleepOnsetPrefs.tuning.signature
        // #1538: read the stored watermark once for both gates and the attribution line, so the logged
        // `newData` and the gate are the same comparison by construction.
        let storedWatermark = UserDefaults.standard.string(forKey: Self.analyzeWatermarkKey)
        if !force, !wmKey.isEmpty, storedWatermark == wmKey {
            return
        }
        // #1196/#1146: a forced post-offload pass may opt into the fingerprint gate: an empty or duplicate
        // offload (fingerprint == watermark) would reproduce identical rows, and the churn made
        // Trends/streak reads flicker like data loss. Scoped via `skipIfUnchanged` to the post-offload
        // caller only, so import/edit/recalibrate re-scores (which change scores without changing the HR
        // fingerprint) always run.
        if force, skipIfUnchanged, !wmKey.isEmpty, storedWatermark == wmKey {
            let skipped = triggerLabel ?? "post-offload"
            diagnosticSink?("re-score: trigger=\(skipped) newData=no — skipped (nothing changed since last run)", nil)
            return
        }
        // Attribute the re-score about to run (#1538, #2238): `trigger=` was logged only on the skip path,
        // so a post-offload pass that ran read as `forced`. `skipIfUnchanged` is an exact witness for
        // post-offload, unless a caller names itself. A non-forced pass is the AppModel idle tick.
        // `newData=no` means the fingerprint equals the watermark, so the re-score is trigger-driven
        // (#1005). Diagnostic only.
        let trigger = QueuedRescore.triggerName(force: force, skipIfUnchanged: skipIfUnchanged, label: triggerLabel)
        let hadNew = wmKey.isEmpty || storedWatermark != wmKey
        diagnosticSink?("re-score: trigger=\(trigger) "
                        + "newData=\(hadNew ? "yes" : "no (nothing changed since last run)")", nil)

        // #1005: time the whole pass so a re-score storm is visible in the log. Uptime, not `Date()`: the
        // figure is banked as pass cost, and a suspended phone once banked 19 003 s and deferred every
        // later background re-score.
        let reScoreStart = DispatchTime.now().uptimeNanoseconds
        let reScoreCPUStart = RescoreBackgroundScheduler.processCPUSeconds()
        let reScoreExpiriesAtStart = RescoreBackgroundScheduler.assertionExpiries
        // #1538: past every gate; mark the pass started durably so a killed process leaves evidence a later
        // one can read. Cleared beside the watermark at the end (`RescoreBackgroundPolicy` stops
        // re-attempting a pass that cannot finish in background).
        // #1681: keep the token this debt was stamped with, so at the end our own debt is told apart from
        // one a later trigger recorded mid-pass, which must survive. Same capture-at-start discipline as
        // `wmKey`.
        let owedToken = RescoreBackgroundScheduler.markRescoreOwed(passStarting: true)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        let tzOffset = TimeZone.current.secondsFromGMT()

        // Pass 1: analyse each offloaded night against the imported-only baseline. A BLE-only user has no
        // imported rows, so recovery is null here, but avgHrv/restingHr are baseline-independent, so
        // harvest them to seed the baseline and re-score in pass 2.
        // Read imported rows directly (computed rows live under the `-noop` sibling), not `repo.days`: the
        // merged cache back-fills imported HRV/RHR with computed values and made the fold window depend on
        // the last refresh (4000 vs 120 days).
        let hist = ((try? await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        // HRV baseline honours the manual Recalibrate epoch (`noop.hrvBaselineEpoch`), resting HR the
        // Charge-wide sibling (`noop.recoveryBaselineEpoch`). Day keys let foldHistory drop nights before
        // the epoch; a 0/absent epoch is byte-identical to the plain fold.
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, dayKeys: hist.map { $0.day }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, dayKeys: hist.map { $0.day },
                                             cfg: rhrCfg, baselineEpoch: Baselines.recoveryBaselineEpoch())
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result, not raw streams: everything except recovery is
        // baseline-independent, so pass 2 re-scores only the cheap recovery composite and memory stays
        // bounded.
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?,
                            sessionMotion: [Int: [Double]],
                            sessionSleepState: [Int: [Int]],
                            hrvDiag: String?,
                            detectionFunnel: WorkoutDetector.DetectionFunnel?)] = []   // #195: carried from loop 1
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        // Device-registry snapshot for per-day owner resolution (invariant I2: a day's scores come from
        // exactly one source), read once. With only the seeded 'my-whoop' row, `resolveDayOwner` returns
        // `deviceId` for every day.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        // #1567: an empty device list is not neutral: every day resolves to `.whoop5`, so a WHOOP 4.0's raw
        // skin-temp ADC is read as centidegrees, misses the 28-42 C worn gate and yields nothing;
        // `regDevices` also supplies model/brand. Still non-fatal, but no longer silent. See
        // `registryUnavailableLine`.
        let regDevices: [PairedDevice]
        do {
            regDevices = try registry.all()
        } catch {
            regDevices = []
            diagnosticSink?(AnalyticsEngine.registryUnavailableLine(importedDeviceId: deviceId), nil)
        }
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)

        // Learned habitual midsleep (#547): computed once per run from the trailing sleep history (one
        // HistoryBlock per session keyed by the local day of its midpoint; the longest per day wins, so
        // naps drop out) so the main-night pick follows the user's real bedtime. nil under
        // `habitualMinDays` of history (cold start keeps the overnight-band bonus). The same value feeds
        // analytics and the Sleep tab.
        let (habitualMidsleepSec, nightlyHours) = await Self.computeHabitualSleep(
            store: store, importedId: deviceId, computedId: deviceId + "-zoop",
            windowStart: nowLocalMidnight - maxDays * 86_400 - StreamReadCap.lookbackSeconds,
            windowEnd: now, finishedBefore: nowLocalMidnight, offsetSec: tzOffset)
        // Personal sleep regularity and population-anchored need, computed once from trailing durations and
        // threaded to every analyzeDay (regularity over the recent 28 nights; need from the full history's
        // upper quartile). Thin history degrades to a neutral term / population default.
        let sleepConsistency = VitalityEngine.sleepConsistency(nightlyHours: Array(nightlyHours.suffix(28)))
        let sleepNeedHours = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: nightlyHours,
                                                                        age: profile.age)

        // Run the entire per-day enumeration off the main actor. Each `await store...` continuation would
        // resume on the @MainActor engine (~32 000 resumes for a 4000-day import pass, ~1 minute of jank).
        // The loop touches only immutable captured inputs, the `WhoopStore` actor, the nonisolated
        // `registry` and pure functions, so it runs in one `Task.detached(priority: .utility)` and hops
        // back to fold results and `refresh()` once. Scoring order and the `hr.count >= 200` skip are
        // unchanged; diagnostic lines (#691) are replayed in the same order.
        let computedId = deviceId + "-zoop"
        let ownerFallbackId = deviceId
        let sleepTraceActive = TestCentre.active(.sleep)
        let hrvTraceActive = TestCentre.active(.hrv)
        // HRV window (#141): read ONCE. When the user picked WHOOP-style, the nightly HRV is RMSSD over deep
        // sleep only; default whole-night otherwise. Captured into the detached loop, threaded to analyzeDay.
        let deepHrvWindow = UserDefaults.standard.string(forKey: UnitPrefs.hrvWindowKey) == HrvWindow.deep.rawValue
        let stepsTraceActive = TestCentre.active(.steps)
        // #103: read the SpO2 candidate toggle once. When on, each night's candidate mean (WHOOP
        // `spo2_candidate_82`; Oura ceiling@100 `0x6F`) is written as "spo2_candidate" under "-zoop" for
        // the Blood Oxygen tile's "strap estimate (unverified)" fallback. Default off per the
        // derived-biosignal rule; neither is a validated calibration.
        let spo2CandidateDisplayOn = PuffinExperiment.spo2CandidateDisplayEnabled
        // #1545: the Effort TRIMP recipe, read ONCE per pass. Global (same for every day), so it folds
        // into the config signature below rather than the per-day key.
        let effortMethodGlobal = PuffinExperiment.effortMethod
        let dayCycleMode = DayCycleMode.persisted(UserDefaults.standard.string(forKey: DayCycleMode.storageKey))

        _ = StoreProbeRecorder.take()
        let useSleepStagerV2Global = PuffinExperiment.experimentalSleepV2Enabled
        let useMotionAwareWakeGlobal = PuffinExperiment.motionAwareWakeEnabled
        let useAlarmAnchoredWakeGlobal = PuffinExperiment.alarmAnchoredWakeEnabled
        // Sleep-onset strictness and the offset learned from the wearer's corrections. Global; folds into
        // the "scoringRecipe" signature field (empty by default) so cached nights re-detect when it moves.
        let onsetTuningGlobal = SleepOnsetPrefs.tuning
        // Cache eligibility: #1575 an active Test-Centre trace no longer disables reuse. `DayScan` carries
        // the sleep/hrv/steps traces, a cache hit appends the whole scan, and the main-actor loop replays
        // all three. Owner eligibility (registered WHOOP) is checked per day.
        let dayCacheEligible = true
        // Pass config signature: every input to `analyzeDay` not in the per-day key, so any change
        // invalidates every cached night. baselines1 is signed structurally; Doubles by raw bit pattern.
        // Compared only in memory.
        // Not all fields are stable across an offload storm (#1538, #1402): `sleepNeedHours`,
        // `sleepConsistency` and `habitualMidsleepSec` come from `computeHabitualSleep(windowEnd: now)`,
        // which reads the sessions the previous pass banked. That invalidation is correct (a night going
        // from half-loaded to complete changes what days are scored against). Churn is limited by learning
        // only from nights finished before today (`computeHabitualSleep(finishedBefore:)`) and by the
        // post-backfill re-score being coalesced (iOS debounces `lastSyncedAt` 2 s, #755), which is
        // load-bearing.
        // Field names live in `dayCacheConfigFields` in this exact order. `changedConfigField` catches
        // count mismatches but not a reorder.
        let dayCacheConfigSig = [
            String(describing: baselines1.hrv),
            String(describing: baselines1.restingHR),
            String(up.age.bitPattern), up.sex, String(up.stepTicksPerStep.bitPattern),
            maxHR.map { String($0.bitPattern) } ?? "nil",
            "\(tzOffset)",
            String(sleepNeedHours.bitPattern),
            sleepConsistency.map { String($0.bitPattern) } ?? "nil",
            habitualMidsleepSec.map { "\($0)" } ?? "nil",
            // The alarm-wake toggle rides in the "motionAwareWake" field (both move the end of a night), so
            // the field list stays the same and an install with it off keeps its cached days.
            "\(useSleepStagerV2Global)",
            "\(useMotionAwareWakeGlobal)" + (useAlarmAnchoredWakeGlobal ? "+alarm" : ""),
            "\(deepHrvWindow)",
            "\(spo2CandidateDisplayOn)",
            "\(effortMethodGlobal)",
            dayCycleMode.rawValue,
            Self.scoringRecipe + (onsetTuningGlobal.signature.isEmpty ? "" : "+" + onsetTuningGlobal.signature),
        ].joined(separator: "|")
        // Drop the whole cache on a config change, then snapshot it into a Sendable `let` for the detached
        // loop (the loop cannot touch `self`) and write the result back after `.value`. #2073: record the
        // drop, since there is then no entry to compare and the miss tally would stay silent.
        var dayCacheConfigDropped = false
        var dayCacheConfigMoved = ""
        if dayCacheConfigSig != dayScanCacheConfigSig {
            dayCacheConfigMoved = Self.changedConfigField(previous: dayScanCacheConfigSig,
                                                          current: dayCacheConfigSig)
            dayScanCache.removeAll()
            dayScanCacheConfigSig = dayCacheConfigSig
            dayCacheConfigDropped = true
        }
        let inDayScanCache = dayScanCache

        let (scanned, skippedDayLines, updatedDayScanCache):
            ([DayScan], [String], [String: (key: String, scan: DayScan)]) = await Task.detached(priority: .utility) {
            var out: [DayScan] = []
            var skippedDayLines: [String] = []
            // #1121: skipped-for-low-HR days collected into ONE line after the loop
            // (`skippedSleepDaysLine`). A local here; Kotlin must use a field because of the JVM
            // method-size ceiling. Do not align the two shapes.
            var skippedSleepDays: [(day: String, hrSamples: Int)] = []
            // #938: the WHOOP 4.0 ADC offset is per-device, not per-night. Learn one anchor per owner
            // from the whole scan window and reuse it for every night so cross-night deviations survive.
            let skinAnchorScanFrom = nowLocalMidnight - (maxDays - 1) * 86_400 - StreamReadCap.lookbackSeconds
            let skinAnchorScanTo = nowLocalMidnight + 18 * 3_600
            var skinAnchorByOwner: [String: Double] = [:]
            var skinAnchorResolvedOwners = Set<String>()
            var dayScanCacheLocal = inDayScanCache
            var dayCacheReused = 0
            // #2073: WHY a night missed, tallied by cause. The reuse count alone cannot separate "today's
            // heart rate grew" from "something shared by all 21 keys moved", and those need different fixes.
            var dayCacheMissBy: [String: Int] = [:]
            if dayCacheConfigDropped { dayCacheMissBy["configDropped(\(dayCacheConfigMoved))"] = 1 }
            var dayPrepSeconds = 0.0
            var dayScoreSeconds = 0.0
            var dayCacheCacheable = 0
            // #1538: backward sliding read buffers for HR and R-R. Pass 1 walks 54-hour windows on a
            // 24-hour stride (30 h overlap), so rows were materialised ~2.25x; these read only the missing
            // stride and fall back to the shipped read whenever safety is unproven.
            // Each window's read cap and truncation threshold must be the same number: a read at the cap is
            // never sliced, because `ORDER BY ts ASC LIMIT` drops the newest rows. Pass one `StreamReadCap`
            // value into both slots.
            // HR and R-R no longer share a cap: 200,000 fit HR (~194,400 rows per 54 h) but silently
            // truncated per-beat R-R (233k-389k; a capture showed `rr[... truncated=10]`). See
            // `StreamReadCap`.
            let hrWindow = SlidingStreamWindow<HRSample>(tsOf: { $0.ts }, limit: StreamReadCap.hr) { o, f, t in
                try? await store.hrSamples(deviceId: o, from: f, to: t, limit: StreamReadCap.hr)
            }
            let activeWhoop5RR = (try? await store.isWhoop5RRSource(deviceId: regActiveId)) ?? true
            let rrWindow = SlidingStreamWindow<RRInterval>(tsOf: { $0.ts }, limit: StreamReadCap.rr) { o, f, t in
                try? await store.rrIntervals(deviceId: o, from: f, to: t, limit: StreamReadCap.rr,
                                            unlabelledAliasOfWhoop5: activeWhoop5RR && o == Repository.whoopSource)
            }
            var paceMark = DispatchTime.now().uptimeNanoseconds
            for offset in 0..<maxDays {
                if offset > 0 { await RescoreBackgroundScheduler.paceIfBackgrounded(since: &paceMark) }
                let dayStart = nowLocalMidnight - offset * 86_400
                let day = AnalyticsEngine.dayString(dayStart, offsetSec: tzOffset)
                let from = dayStart - StreamReadCap.lookbackSeconds
                let to = Self.sleepReadWindowEnd(dayStart: dayStart,
                                                 nowLocalMidnight: nowLocalMidnight,
                                                 now: now)

                // I2: pick the single device that owns this day and read its streams (active strap > other
                // live straps > imports, or a locked override). Falls back to `deviceId` if the registry is
                // unreadable.
                let owner = await Self.resolveDayOwner(day: day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId)

                // #1005 per-day reuse: reuse this night's `DayScan` when its inputs are provably unchanged
                // this session, skipping the 7 stream reads + `analyzeDay`. Gated to a registered WHOOP
                // (4.0 or 5/MG) via `forRegistryDevice` (nil for ring/import/unknown, whose `providedSleep`
                // can change without an HR move; since #1801 a no-gravity WHOOP's HR-only `providedSleep`
                // derives from the already-fingerprinted HR). The key folds the night's HR fingerprint and,
                // for a 4.0, the window-wide skin anchor; a 5/MG banks centidegrees so its anchor stays
                // nil. Pass-global inputs already dropped the cache on change. A miss takes the full path.
                var dayCacheKey: String? = nil
                if dayCacheEligible,
                   let ownerFamily = DeviceFamily.forRegistryDevice(
                        model: regDevices.first(where: { $0.id == owner })?.model,
                        brand: regDevices.first(where: { $0.id == owner })?.brand) {
                    // Resolve the 4.0 window-wide anchor before the gate (it is a key input), once per
                    // owner from the sparse skin stream; the per-day anchor block below then finds it
                    // resolved. Skipped for a 5/MG.
                    if ownerFamily == .whoop4, !skinAnchorResolvedOwners.contains(owner) {
                        let windowSkin = (try? await store.skinTempSamples(deviceId: owner,
                                                                           from: skinAnchorScanFrom,
                                                                           to: skinAnchorScanTo,
                                                                           limit: StreamReadCap.skin)) ?? []
                        if let anchor = Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) {
                            skinAnchorByOwner[owner] = anchor
                        }
                        skinAnchorResolvedOwners.insert(owner)
                    }
                    if let fp = try? await store.hrFingerprint(deviceId: owner, from: from, to: to),
                       let streamFp = try? await store.dayStreamFingerprint(deviceId: owner, from: from, to: to) {
                        let key = AnalyzeRecentDayCache.cacheKey(
                            owner: owner, hrCount: fp.count, hrMaxTs: fp.maxTs,
                            skinAnchorRaw: skinAnchorByOwner[owner],
                            // #29: fingerprint the other scored streams too. Otherwise a night whose R-R
                            // (or resp/SpO2) landed after its HR keys identically to the HR-only scan and
                            // the HRV-less result is re-served all session; `force` bypasses only the
                            // pass-level watermark gate. Index-only aggregates.
                            streams: streamFp + "|rrAlias5=\(activeWhoop5RR && owner == Repository.whoopSource)",
                            // #1575: `hrvTraceActive &&` matters. With the trace off the flag describes
                            // nothing but would flip at midnight and charge every user an extra day's
                            // re-score.
                            hrvWindowDetail: hrvTraceActive && dayStart == nowLocalMidnight)
                        dayCacheKey = key
                        if dayScanCacheLocal[day] == nil {
                            dayCacheMissBy["absent", default: 0] += 1
                        }
                        if let cached = dayScanCacheLocal[day] {
                            if cached.key == key {
                                out.append(cached.scan)
                                dayCacheReused += 1
                                continue
                            }
                            let why = AnalyzeRecentDayCache.missReason(cachedKey: cached.key, freshKey: key)
                            dayCacheMissBy[why, default: 0] += 1
                        }
                    }
                }

                let tPrep0 = Date()
                let hr = await hrWindow.rows(owner: owner, from: from, to: to)
                guard hr.count >= IntelligenceEngine.minHrSamples else {
                    dayPrepSeconds += Date().timeIntervalSince(tPrep0)
                    skippedSleepDays.append((day: day, hrSamples: hr.count))
                    continue
                }
                let strictWhoop5RR = (try? await store.isWhoop5RRSource(deviceId: owner,
                    unlabelledAliasOfWhoop5: activeWhoop5RR && owner == Repository.whoopSource)) ?? true
                let rr = await rrWindow.rows(owner: owner, from: from, to: to, allowReuse: !strictWhoop5RR)
                // One read, two consumers. `forScoring` strips an Oura ring's respiration rows from the
                // stager's input: the stager peak-detects a ~1 Hz raw ADC waveform and the ring's rows are
                // a per-window RATE (0x6A, milli-bpm, ~1 per 5 min). `forVendorRate` hands those rows to
                // `analyzeDay` as the device's own measured respiratory rate, which becomes `respRateBpm`
                // instead of the RSA estimate. A WHOOP owner is unchanged. See `OuraRespScale`.
                let respRows = (try? await store.respSamples(deviceId: owner, from: from, to: to,
                                                             limit: 200_000)) ?? []
                let resp = OuraRespScale.forScoring(respRows, deviceId: owner)
                let vendorResp = OuraRespScale.forVendorRate(respRows, deviceId: owner)
                let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to,
                                                            limit: StreamReadCap.gravity)) ?? []
                let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: StreamReadCap.skin)) ?? []
                let spo2 = (try? await store.spo2Samples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                // #938: the strap family that wrote this owner's skin-temp rows (5/MG banks centidegrees,
                // WHOOP 4.0 v24 a raw ADC). Unknown/non-WHOOP owners fall back to `.whoop5`.
                let skinFamily = Self.skinTempFamily(forOwner: owner, devices: regDevices)
                let skinWornToleranceSec = Self.skinTempWornToleranceSec(forOwner: owner, devices: regDevices)
                // #938: learn this device's worn skin-temp anchor raw once, window-wide, not per night. The
                // @72 ADC offset is per device (a second 4.0 shares the ~509 no-contact floor and 2047
                // saturation but is worn at ~1100-1600, which the global 826 anchor maps to 47-72 C and
                // fails the 28-42 C gate). Window-wide because a per-night re-centre would erase the
                // cross-night deviation `skinTempDevC` carries; safe because the baseline is re-folded from
                // the same window each run, so the offset cancels. nil for non-4.0 owners or <100 in-band
                // samples (falls back to the global anchor).
                let skinAnchorRaw: Double?
                if skinFamily == .whoop4 {
                    if !skinAnchorResolvedOwners.contains(owner) {
                        let windowSkin = (try? await store.skinTempSamples(deviceId: owner,
                                                                           from: skinAnchorScanFrom,
                                                                           to: skinAnchorScanTo,
                                                                           limit: StreamReadCap.skin)) ?? []
                        if let anchor = Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) {
                            skinAnchorByOwner[owner] = anchor
                        }
                        skinAnchorResolvedOwners.insert(owner)
                    }
                    skinAnchorRaw = skinAnchorByOwner[owner]
                } else {
                    skinAnchorRaw = nil
                }
                // Wrist-wear events in the night window, paired into off-wrist [start, end) intervals for
                // the off-wrist backstop (#500). Under the fractional rule (#504) a session drops only when
                // off-wrist coverage reaches maxOffWristSleepFraction. A span still open closes at `to`.
                let wristEvents = (try? await store.events(deviceId: owner, from: from, to: to, limit: 50_000)) ?? []
                let wristOff = AnalyticsEngine.offWristIntervals(events: wristEvents, windowEnd: to, hr: hr)

                // Calendar-day window for the additive daily totals (steps, calories). The night window
                // ends at dayStart+12h, so late hours of a past day would be undercounted; read
                // [localMidnight(day), +86400) (inclusive store range, so end at -1 s) and hand it to
                // analyzeDay's dayHr/daySteps, used only for totals (#277).
                let dayMid = Self.midnightLocal(dayStart, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                // Same `owner` as the night window (I2): additive totals come from one device. #997: for a
                // past day the night read extends to nextMidnight, so the calendar day is a strict subset
                // of the lists in memory; derive it with `AnalyticsEngine.daySliceFromNight` instead of ~60
                // redundant reads per pass. Today, and a night read that hit the 200_000 limit, decline and
                // read directly, so the shortcut only skips work. (`??` cannot take an `await` on its right
                // side, hence the if/else.)
                let dayHr: [HRSample]
                if let slice = AnalyticsEngine.daySliceFromNight(hr, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayHr = slice
                } else {
                    dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }
                let daySteps: [StepSample]
                if let slice = AnalyticsEngine.daySliceFromNight(steps, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    daySteps = slice
                } else {
                    daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }
                // Full calendar-day gravity for workout detection: the night window ends at dayStart+12h,
                // so an afternoon workout was only found a day later. [localMidnight, +24h) (today clamped
                // to `now` by the store) lets a 5 pm run show up the same day.
                let dayGrav: [GravitySample]
                if let slice = AnalyticsEngine.daySliceFromNight(grav, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayGrav = slice
                } else {
                    dayGrav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }

                // The strap's own band sleep_state for the night window as (ts, state) samples (#531/#175),
                // read directly from `owner` so it is current this pass. Lets the morning-stillness guard
                // confirm a borderline re-onset and analyzeDay grid it per session. Empty on a WHOOP 4.0
                // (no stream) or unbanded window, so the guard falls back to the HR bar. Falls back to the
                // prior pass's persisted per-session state for older DBs banded before v21.
                var bandSleepState = (try? await store.sleepStateSamples(deviceId: owner, from: from, to: to))?
                    .map { (ts: $0.ts, state: $0.state) } ?? []
                if bandSleepState.isEmpty {
                    bandSleepState = await Self.bandSleepStateSamples(computedId: computedId,
                                                                     from: from, to: to, store: store)
                }

                // #690: read the experimental-V2 stager toggle once, off the detached executor, so it
                // drives the normal staging path as well as the userEdited self-heal. V2 is the default for
                // every strap. WHOOP 4.0 is unvalidated either way (V2 can over-stage on sparse motion
                // #319; V1 can under-stage deep/REM #347), so the toggle is the escape hatch (#271).
                let useSleepStagerV2 = PuffinExperiment.experimentalSleepV2Enabled
                // #364: motion-aware wake refinement toggle, read once. Default off
                // (`PuffinExperiment.motionAwareWakeEnabled`); runs after the stager and self-gates on
                // observed gravity and step density, so it is a no-op for sparse nights.
                let useMotionAwareWake = PuffinExperiment.motionAwareWakeEnabled
                let useAlarmAnchoredWake = PuffinExperiment.alarmAnchoredWakeEnabled

                var sleepTrace: [String] = []
                let traceSink: ((String) -> Void)? = sleepTraceActive ? { sleepTrace.append($0) } : nil
                var hrvTrace: [String] = []
                let hrvTraceSink: ((String) -> Void)? = hrvTraceActive ? { hrvTrace.append($0) } : nil
                // #804/#1801: two questions share the "no motion" gate. #804 hands analyzeDay a device's
                // own persisted hypnogram (an Oura ring's SleepNet night, #773) when gravity is absent
                // (`grav.count < 2`) and the owner is not the canonical WHOOP import, reconstructing
                // SleepSession from each CachedSleepSession (minute-dict imports decode to nothing and are
                // skipped); a detected session still wins on overlap. #1801 stages from HR when there is no
                // hypnogram at all and must not inherit #804's owner exclusion: `resolveDayOwner` returns
                // the imported id when the owner source is absent, which skipped the branch on live 5/MG
                // installs. The stored lookup now runs for every no-motion day; a day with stored sessions
                // is left alone.
                let providedSleep: [SleepSession]
                if grav.count < 2 {
                    let persisted = (try? await store.sleepSessions(deviceId: owner, from: from, to: to,
                                                                    limit: 4000)) ?? []
                    let stored = persisted.compactMap { AnalyticsEngine.sleepSession(fromProvided: $0) }
                    if owner != Repository.whoopSource, !stored.isEmpty {
                        traceSink?(SleepStager.GateTrace.hrOnlyGateLine(
                            day: day, attempted: false, reason: "stored-hypnogram",
                            gravRows: grav.count, storedNights: stored.count))
                        providedSleep = stored
                    } else if !stored.isEmpty {
                        traceSink?(SleepStager.GateTrace.hrOnlyGateLine(
                            day: day, attempted: false, reason: "stored-sessions-exist",
                            gravRows: grav.count, storedNights: stored.count))
                        providedSleep = []
                    } else {
                        // Reachable for any owner now, including a WHOOP 4.0 day that banked nothing. A
                        // normal 4.0 day streams gravity and never reaches this gate.
                        traceSink?(SleepStager.GateTrace.hrOnlyGateLine(
                            day: day, attempted: true, reason: "no-motion-no-hypnogram",
                            gravRows: grav.count, storedNights: 0))
                        providedSleep = SleepStager.hrOnlySessions(day: day, hr: hr, rr: rr, resp: resp,
                                                                   traceSink: traceSink)
                    }
                } else {
                    providedSleep = []
                }

                let tScore0 = Date()
                dayPrepSeconds += tScore0.timeIntervalSince(tPrep0)
                // #1770: the Effort ring's funnel is collected in a local buffer, since `diagnosticSink` is
                // main-actor isolated and this loop is not (same reason `hrvDiag` rides the scan).
                var strainDiagLines: [String] = []
                let res = AnalyticsEngine.analyzeDay(day: day,
                                                     strainDiag: { strainDiagLines.append($0) },
                                                     hr: hr, rr: rr, resp: resp,
                                                     vendorResp: vendorResp, gravity: grav,
                                                     steps: steps, dayHr: dayHr, daySteps: daySteps,
                                                     dayGravity: dayGrav,
                                                     skinTemp: skin,
                                                     skinTempFamily: skinFamily,   // #938
                                                     skinTempAnchorRaw: skinAnchorRaw,   // #938 second capture
                                                     skinTempWornToleranceSec: skinWornToleranceSec,   // #1467
                                                     spo2: spo2,                   // #93
                                                     profile: up, baselines: baselines1, maxHROverride: maxHR,
                                                     tzOffsetSeconds: tzOffset, wristOff: wristOff,
                                                     sleepNeedHours: sleepNeedHours,
                                                     sleepConsistency: sleepConsistency,
                                                     habitualMidsleepSec: habitualMidsleepSec,
                                                     bandSleepState: bandSleepState,
                                                     useSleepStagerV2: useSleepStagerV2,
                                                     useMotionAwareWake: useMotionAwareWake,
                                                     alarmFires: AlarmAnchoredWake.alarmFires(wristEvents),
                                                     useAlarmAnchoredWake: useAlarmAnchoredWake,
                                                     providedSleep: providedSleep,
                                                     traceSink: traceSink,
                                                     hrvTraceSink: hrvTraceSink,
                                                     hrvWindowDetail: dayStart == nowLocalMidnight,
                                                     deepHrvWindow: deepHrvWindow,
                                                     effortMethod: effortMethodGlobal,
                                                     onsetTuning: onsetTuningGlobal)
                dayScoreSeconds += Date().timeIntervalSince(tScore0)
                // #195: whole-night HRV cleaning summary for the always-on strap log, so a "reads ~2x too
                // high" report is triageable without HRV test mode: RMSSD vs SDNN (rmssd >> sdnn = jitter
                // surviving the ectopic filter), meanNN, and surviving R-R count (`nInput` is set before
                // the min-beats gate, so sparse nights show rmssd=nil). A separate analyzer pass; the
                // shipped windowed avgHrv is untouched. Built here, emitted in the main-actor replay via
                // `hrvDiag`. Must match the Kotlin line.
                // #2425: uses the main night the #1118 gate judged (`AnalyticsEngine.hrvDiagnosticRows`),
                // not all sessions pooled across gaps; `hrvOverCounted` and the resp gate read the same
                // rows.
                let sleepRrRows = AnalyticsEngine.hrvDiagnosticRows(
                    rr, mainNight: res.mainNightBlocks,
                    fallback: res.cachedSleep.map { SleepStageTotals.NightBlock(start: $0.startTs, end: $0.endTs) })
                let sleepRr = sleepRrRows.map { Double($0.rrMs) }
                let hrvDiag: String?
                let hrvOverCounted: Bool?   // #1118: nil = no in-sleep R-R (no HRV to caveat)
                var respGateAcc: Double?
                var respGateIntegrity: String?
                if sleepRr.isEmpty {
                    hrvOverCounted = nil
                    // #1244: no in-sleep R-R means no HRV summary. If the night also detected no session
                    // (past the 200-HR gate: "HR tracked, no sleep"), carry a counts-only reason line on
                    // the loop-1 channel. `window` is the read span in whole hours.
                    if res.cachedSleep.isEmpty {
                        // from/to are Int unix seconds; the span is always a whole-hour multiple
                        // (30 h + 24 h, or 30 h + 18 h), so integer division is exact. Matches Kotlin.
                        let windowHours = (to - from) / 3_600
                        // Attribute each provided session by the local day its END falls in, as
                        // `analyzeDay` does, so this line and the filter that emptied the night agree by
                        // construction.
                        let longestProvided = Self.longestProvidedForDiag(providedSleep)
                        hrvDiag = Self.sleepDetectNoNightLogLine(
                            day: day, hrCount: hr.count, rrCount: rr.count, respCount: resp.count,
                            gravCount: grav.count, stepCount: steps.count,
                            providedCount: providedSleep.count,
                            providedEndingOnDay: providedSleep.filter {
                                AnalyticsEngine.dayString($0.end, offsetSec: tzOffset) == day
                            }.count,
                            providedLongestMin: longestProvided.map { ($0.end - $0.start) / 60 },
                            providedLongestEndDay: longestProvided.map {
                                AnalyticsEngine.dayString($0.end, offsetSec: tzOffset)
                            },
                            windowHours: windowHours,
                            skinCount: skin.count)
                    } else {
                        hrvDiag = nil
                    }
                } else {
                    let h = HRVAnalyzer.analyze(rawRR: sleepRr)
                    func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "nil" }
                    let rej = h.nInput > 0 ? String(format: "%.0f", 100 * (1 - Double(h.nClean) / Double(h.nInput))) : "0"
                    // #257: coverage (sum of NN / wall-clock span; >1.0 is impossible without
                    // double-counted R-R) plus exact-duplicate beat count, so over-reading reports are
                    // self-diagnosing.
                    let ts = sleepRrRows.map { $0.ts }
                    let covVal = HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: sleepRr)
                    let cov = String(format: "%.2f", covVal)
                    let colCovVal = HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: sleepRr)
                    let colCov = String(format: "%.2f", colCovVal)
                    let dup = HRVAnalyzer.duplicateBeatCount(tsSec: ts, rrMs: sleepRr)
                    let verdict = HRVAnalyzer.classifyCoverage(coverage: covVal, collapsed: colCovVal)
                    // #550: act on the verdict. SDNN inflates directly on an over-counted night (a ring at
                    // 1.25x coverage read ~197 ms vs a 40-100 ms physiological range), so it is withheld
                    // from this line (`rrIntegrity=` says why); meanNN survives. RMSSD still prints here
                    // but the real gate is `SleepStager.sessionAvgHRV` (#1118); kept to stay byte-identical
                    // with the Kotlin twin.
                    // The over-count verdict is necessary but not sufficient: an Oura night showed coverage
                    // 1.03 / `plausible` yet SDNN 174 ms, because a banked stream stamps a whole record of
                    // intervals on one timestamp, so the per-record sum is right (meanNN, RHR) but the
                    // individual intervals are not beat-to-beat. Gate on beat accuracy too.
                    let accVal = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: sleepRr)
                    respGateAcc = accVal
                    let acc = String(format: "%.2f", accVal)
                    let sdnnField = HRVAnalyzer.beatSpreadIsTrustworthy(verdict)
                        && HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accVal)
                        ? "\(ms(h.sdnn))ms" : "withheld"
                    var diagLine = "hrv diag day=\(res.daily.day) rmssd=\(ms(h.rmssd))ms sdnn=\(sdnnField) "
                        + "meanNN=\(ms(h.meanNN))ms rr=\(h.nInput)/\(h.nClean) rejected=\(rej)% coverage=\(cov) collapsedCov=\(colCov) dupBeats=\(dup) "
                        + "beatAccurate=\(acc) "
                        + "rrIntegrity=\(verdict.rawValue)"
                        respGateIntegrity = verdict.rawValue
                    // #1008: on an over-count night only, append a raw-row sample around the densest second
                    // (a second \n-joined line, split at the emit site) so the mechanism is readable; clean
                    // nights stay quiet. Must match the Kotlin `hrv rrsample` line.
                    if verdict == .crossSecondOverCount || verdict == .sameSecondOverCount {
                        let rrOrds = sleepRrRows.map { $0.ord }
                        let sample = HRVAnalyzer.densestSecondWindowSample(
                            tsSec: ts, rrMs: sleepRr, srcCodes: sleepRrRows.map { $0.srcChannel?.rawValue },
                            ords: rrOrds)
                        if !sample.isEmpty { diagLine += "\nhrv rrsample day=\(res.daily.day) \(sample)" }
                        let deliveries = HRVAnalyzer.deliveryHistogram(
                            tsSec: ts, rrMs: sleepRr, ords: rrOrds)
                        if !deliveries.isEmpty { diagLine += "\n\(deliveries) day=\(res.daily.day)" }
                        // #1505: if the live and historical copies are the same beat in two units, a
                        // duplicated second holds two values 1024/1000 apart; different beats scatter. A
                        // night's worth of pairs tells them apart. Measurement only.
                        let dupPairs = HRVAnalyzer.duplicatePairRatios(
                            tsSec: ts, rrMs: sleepRr, ords: rrOrds)
                        if !dupPairs.isEmpty { diagLine += "\n\(dupPairs) day=\(res.daily.day)" }
                        // #1331/#1008/#1118 shadow: log the de-duped stream's HRV, coverage and beat
                        // accuracy beside the raw, to validate a candidate two-channel de-dup against
                        // WHOOP's numbers before it becomes the read path. Instrumentation only. `ex`
                        // (exact duplicates, rrTolMs 0) is the safe floor, `dd` (40 ms same-second) the
                        // aggressive bound.
                        // Retired: the 1-second `xsec` collapse (covXsec 0.80 with beatAccXsec 0.26: it
                        // eats real beats) and the 20/34/60 tolerance sweep (no same-second tolerance
                        // reaches cross-second duplicates). Each `collapseOverCount` sorts ~50-70k
                        // intervals per night every 15 minutes, so six sorts became two; the delivery
                        // histogram supersedes them.
                        let ex = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: sleepRr, rrTolMs: 0)
                        let dd = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: sleepRr)
                        let hDd = HRVAnalyzer.analyze(rawRR: dd.rrMs)
                        let covEx = HRVAnalyzer.rrCoverage(tsSec: ex.tsSec, rrMs: ex.rrMs)
                        let covDd = HRVAnalyzer.rrCoverage(tsSec: dd.tsSec, rrMs: dd.rrMs)
                        let accDd = HRVAnalyzer.beatAccurateFraction(tsSec: dd.tsSec, rrMs: dd.rrMs)
                        diagLine += "\nhrv dedup day=\(res.daily.day) exactN=\(ex.rrMs.count)/\(sleepRr.count) "
                            + "covExact=\(String(format: "%.2f", covEx)) | ch40N=\(dd.rrMs.count) "
                            + "cov40=\(String(format: "%.2f", covDd)) beatAcc40=\(String(format: "%.2f", accDd)) "
                            + "rmssd40=\(ms(hDd.rmssd))ms sdnn40=\(ms(hDd.sdnn))ms meanNN40=\(ms(hDd.meanNN))ms "
                            + "| collapse candidates only; the DELIVERY histogram above sizes the fix"
                        // #1118 sweep: same-second collapse at several tolerances (34 ms is the
                        // two-optical-channel twin spacing). The 0 and 40 points reuse `ex` and `dd` (the
                        // default tolerance is 40) to avoid sorting ~50k intervals again inside the per-day
                        // loop.
                    }
                    hrvDiag = diagLine
                    hrvOverCounted = (verdict == .crossSecondOverCount || verdict == .sameSecondOverCount)
                }
                // Steps test mode: 5/MG raw-counter trace, built only when the mode is on. Recomputes the
                // same wrap-aware @57 sum analyzeDay ran over the same `daySteps`, so it cannot diverge;
                // replayed tagged `.steps`.
                var stepsTrace: [String] = []
                if stepsTraceActive && !daySteps.isEmpty {
                    stepsTrace = StepsEstimateEngine.rawCounterTrace(
                        daySteps: daySteps, dayKey: day, tzOffsetSeconds: tzOffset,
                        ticksPerStep: up.stepTicksPerStep)
                }
                // RHR floor-vs-mean diagnostic (#691). Zoop's `restingHr` is the WHOOP-style floor (lowest
                // sustained 5-min in-bed HR; SleepStager takes the min 5-min rolling mean per session, the
                // day the .min() across them), whereas a "sleeping HR" app reports the night mean, which
                // always sits above it. Zoop reading lower is by design. Log both, over the same matched
                // in-bed span, so reports are explainable; skipped when no floor is banked. Logging only.
                // Computed here and replayed on the main actor in per-day order.
                var rhrLine: String?
                var rhrBinLine: String?
                if let floor = res.daily.restingHr {
                    let inBedBpms = hr.filter { s in
                        res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
                    }.map { $0.bpm }
                    rhrLine = Self.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms)
                    rhrBinLine = SleepStager.rhrBinGateLogLine(
                        day: res.daily.day,
                        sessions: res.cachedSleep.map { ($0.startTs, $0.endTs) },
                        hr: hr, shippedFloor: floor)
                }
                let respLine: String? = Self.respRateLogLine(day: res.daily.day,
                                                            respRateBpm: res.daily.respRateBpm,
                                                            beatAccurate: respGateAcc,
                                                            rrIntegrity: respGateIntegrity)
                // #103: SpO2 candidate nightly mean, computed only with the display toggle on and
                // device-conditional: WHOOP averages the in-band (70-100) `spo2_candidate_82` V18Aux byte;
                // Oura averages its `0x6F` SpO2 through the ceiling@100 transform
                // (`AnalyticsEngine.nightlySpo2CeilingMean`). nil on a WHOOP 4.0 (no v18 aux), an Oura
                // night with no plausible sample, or toggle off. Written to metricSeries as
                // "spo2_candidate" in pass 2, never to `spo2Pct` (enforced by
                // `testHistoricalV18OpticalFieldsAreNotNamedPhysiologically`).
                var spo2CandidateMean: Int? = nil
                if spo2CandidateDisplayOn {
                    // Through the catalog, not a brand-string compare: Kotlin uses
                    // `DeviceBrandCatalog.isOura(owner)` (id prefix to `sourceKind`), so an `oura-` id
                    // without a registry row was Oura on Android but not iOS. Matches
                    // `Repository.activeDeviceIsOura`.
                    let ownerIsOura = DeviceBrandCatalog.isOura(owner)
                    if ownerIsOura {
                        if let cand = AnalyticsEngine.nightlySpo2CeilingMean(res.sleepSessions, spo2: spo2) {
                            spo2CandidateMean = cand.mean
                        }
                    } else {
                        let auxSamples = (try? await store.v18AuxSamples(
                            deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                        if !auxSamples.isEmpty {
                            if let cand = AnalyticsEngine.nightlySpo2CandidateMean(res.sleepSessions, aux: auxSamples) {
                                spo2CandidateMean = cand.mean
                            }
                        }
                    }
                }
                // #1169 shadow metric (instrumentation only): the primary-session mean resting HR, recorded
                // beside the shipped nightly floor (daily.restingHr) so mean-vs-floor accrues on real
                // devices. Never shown or scored; #1174's definition is unchanged. Windowing lives in the
                // tested `AnalyticsEngine`.
                let (primarySessionRHR, primarySessionRHRCoverage) =
                    AnalyticsEngine.primarySessionRestingHRWithCoverage(sessions: res.sleepSessions, hr: hr)
                let scan = DayScan(result: res, rhrLine: rhrLine, rhrBinLine: rhrBinLine,
                                   respLine: respLine,
                                   readOwner: owner, hrRows: hr.count,
                                   sleepTrace: sleepTrace, stepsTrace: stepsTrace, hrvTrace: hrvTrace,
                                   hrvDiag: Self.mergedDayDiag(hrvDiag, strainDiagLines),
                                   spo2Candidate: spo2CandidateMean,
                                   hrvOverCounted: hrvOverCounted,
                                   primarySessionRHR: primarySessionRHR,
                                   primarySessionRHRCoverage: primarySessionRHRCoverage)
                // #1005: cache this freshly scored scan under its per-day key (only cache-eligible days:
                // registered WHOOP owner, not traced). Reused days `continue` above, so the cache holds
                // only fresh scans.
                if let key = dayCacheKey {
                    dayScanCacheLocal[day] = (key: key, scan: scan)
                    dayCacheCacheable += 1
                }
                out.append(scan)
            }
            let dayCacheWindow = Set((0..<maxDays).map {
                AnalyticsEngine.dayString(nowLocalMidnight - $0 * 86_400, offsetSec: tzOffset) })
            dayScanCacheLocal = dayScanCacheLocal.filter { dayCacheWindow.contains($0.key) }
            if let line = skippedSleepDaysLine(skippedSleepDays, minHrSamples: IntelligenceEngine.minHrSamples) {
                skippedDayLines.append(line)
            }
            // #1538: the reuse ratio's denominator is the cacheable days this pass (reused + freshly
            // cached), not `maxDays`: import/ring owners, unreadable fingerprints and sub-200-sample nights
            // can never be reused and made a healthy cache look broken. #2073: the miss tally rides the
            // same line, absent when nothing was cached to miss.
            var missBy = ""
            if !dayCacheMissBy.isEmpty {
                let parts = dayCacheMissBy.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
                missBy = " missBy=" + parts.joined(separator: ",")
            }
            skippedDayLines.append("analyzeRecent dayCache reused=\(dayCacheReused)/"
                                   + "\(dayCacheReused + dayCacheCacheable) "
                                   + "size=\(dayScanCacheLocal.count) days=\(maxDays)\(missBy)")
            // #1538: where the pass goes. `prep` is the nine windowed reads plus session matching; `score`
            // is `analyzeDay`. They do not sum to the pass total (pass 2 and reconciliation are outside),
            // so read them as a ratio: reads dominating means narrowing the 54-hour window is worth it.
            skippedDayLines.append("analyzeRecent cost prep=\(Int(dayPrepSeconds * 1000))ms "
                                   + "score=\(Int(dayScoreSeconds * 1000))ms")
            // #1538: what the sliding windows saved. `served` near 0 means they are declining (truncation,
            // owner flip, dayCache gap) and reads are back to baseline. Must match the Kotlin
            // `analyzeWindowsLogLine`.
            skippedDayLines.append(WindowedStreamPlan.logLine(
                hrRead: hrWindow.rowsRead, hrServed: hrWindow.rowsServed,
                hrTruncated: hrWindow.truncatedReads,
                rrRead: rrWindow.rowsRead, rrServed: rrWindow.rowsServed,
                rrTruncated: rrWindow.truncatedReads,
                hrOwnerFlips: hrWindow.ownerFlips, rrOwnerFlips: rrWindow.ownerFlips,
                hrReuseOff: hrWindow.reuseOffReads, rrReuseOff: rrWindow.reuseOffReads))
            return (out, skippedDayLines, dayScanCacheLocal)
        }.value
        dayScanCache = updatedDayScanCache
        // #1538: stamp each post-loop phase as it completes (`AnalysisPhaseTally` renders them beside
        // `re-score: done`), since the loop's cost line missed time spent later (the steps calibration was
        // re-folding sixty days of gravity per pass). `Date()` matches the loop's clock; the formatter
        // floors a backwards step at zero.
        var postLoopPhases: [(name: String, seconds: Double)] = []
        var postLoopMark = Date()
        func markPostLoopPhase(_ name: String) {
            let now = Date()
            postLoopPhases.append((name: name, seconds: now.timeIntervalSince(postLoopMark)))
            postLoopMark = now
        }

        for line in skippedDayLines { diagnosticSink?(line, nil) }

        // Per-day resolved read owner and its HR-row count, so pass 2 can emit the `dayOwner` line
        // (#814/#799). When it diverges from the registry active id (the write side) on a day with data,
        // the #814 read/write split shows in every export.
        var readOwnerByDay: [String: (owner: String, hrRows: Int)] = [:]
        var resolvedScoreOwnerByDay: [String: String] = [:]
        var spo2CandidateByDay: [String: Int] = [:]
        var hrvOverCountByDay: [String: Bool] = [:]
        var primarySessionRHRByDay: [String: Double] = [:]
        var primarySessionRHRCoverageByDay: [String: PrimarySessionRestingHR.Coverage] = [:]

        for scan in scanned {
            let res = scan.result
            readOwnerByDay[res.daily.day] = (scan.readOwner, scan.hrRows)
            resolvedScoreOwnerByDay[res.daily.day] = scan.readOwner
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            if let cand = scan.spo2Candidate {
                spo2CandidateByDay[res.daily.day] = cand
            }
            if let oc = scan.hrvOverCounted {
                hrvOverCountByDay[res.daily.day] = oc
            }
            if let v = scan.primarySessionRHR {
                primarySessionRHRByDay[res.daily.day] = v
            }
            if let cov = scan.primarySessionRHRCoverage {
                primarySessionRHRCoverageByDay[res.daily.day] = cov
            }
            if let line = scan.rhrLine { diagnosticSink?(line, nil) }
            if let line = scan.rhrBinLine { diagnosticSink?(line, nil) }
            if let line = scan.respLine { diagnosticSink?(line, nil) }
            for line in scan.sleepTrace { diagnosticSink?(line, .sleep) }
            for line in scan.hrvTrace { diagnosticSink?(line, .hrv) }
            for line in scan.stepsTrace { diagnosticSink?(line, .steps) }
            scoredNights.append((daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC,
                                 sessionMotion: res.sessionMotionByStart,
                                 sessionSleepState: res.sessionSleepStateByStart,
                                 hrvDiag: scan.hrvDiag,
                                 detectionFunnel: res.detectionFunnel))
        }

        markPostLoopPhase("dayReplay")
        // Charge baselines (#2525): each is folded from the wearer's own nights over the last
        // `ChargeBaselines.windowDays` calendar days back from today; imported vendor nights only seed it
        // until own nights are trusted, then drop out (see `ChargeBaselines`). This is the BLE-only
        // recovery fix: "-zoop" nightly avgHrv/restingHr feed the baseline so a strap-only user crosses
        // `Baselines.minNightsSeed`. The window is the scan window's own 21 days (a full-history repair
        // pass is trimmed to the same).
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400,
                                                  offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)
        func importedNights(_ value: (DailyMetric) -> Double?) -> [(day: String, value: Double?)] {
            hist.map { (day: $0.day, value: value($0)) }
        }
        func ownNights(_ byDay: [String: Double?]) -> [(day: String, value: Double?)] {
            byDay.map { (day: $0.key, value: $0.value) }
        }

        // Which source measured each night's respiration, the input `Baselines.deviceEraEpoch` (#459)
        // needs: a WHOOP export reports ~16.1, Oura ~14.6, Zoop's own RSA estimate is a third method, and
        // pooling them turns a strap switch into a ~3-sigma step against a ~0.52 bpm spread.
        // `resolvedScoreOwnerByDay` (this pass's resolved owner, before re-homing) is the only per-night
        // source and covers every own night. Imported `hist` rows are tagged `deviceId` (buckets to WHOOP);
        // computed days are written under `computedId`, never into `hist`.
        var respSourceByDay: [String: String] = [:]
        for (day, owner) in resolvedScoreOwnerByDay { respSourceByDay[day] = owner }
        let respCandidateDays = Set(hist.map(\.day)).union(nightlyRespByDay.keys).sorted()
        // rhr/resp/skin honour the Charge-wide recalibration epoch (`noop.recoveryBaselineEpoch`; 0 =
        // no-op), so Recalibrate re-anchors the whole build-up together. The resp baseline is also scoped
        // to the current device era (`deviceEraEpoch` is 0.0 for a single-brand history; `max` keeps the
        // later cut).
        // Known gap: the era bucket is per brand, so it does not separate an imported WHOOP vendor rate
        // from Zoop's RSA estimate on WHOOP nights, and #459's primitive is unwired for HRV and resting HR.
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()
        let respEraEpoch = Baselines.deviceEraEpoch(respCandidateDays.map { (day: $0, sourceId: respSourceByDay[$0] ?? deviceId) })
        let respEpoch = max(recoveryEpoch, respEraEpoch)
        let hrvEpoch = Baselines.hrvBaselineEpoch()
        let hrvHistory = ChargeBaselines.history(imported: importedNights { $0.avgHrv }, own: ownNights(nightlyHrvByDay),
                                                 anchorDay: newestDay, cfg: hrvCfg, baselineEpoch: hrvEpoch)
        let rhrHistory = ChargeBaselines.history(imported: importedNights { $0.restingHr.map(Double.init) },
                                                 own: ownNights(nightlyRhrByDay),
                                                 anchorDay: newestDay, cfg: rhrCfg, baselineEpoch: recoveryEpoch)
        let respHistory = ChargeBaselines.history(imported: importedNights { $0.respRateBpm }, own: ownNights(nightlyRespByDay),
                                                  anchorDay: newestDay, cfg: respCfg, baselineEpoch: respEpoch)
        let skinHistory = ChargeBaselines.history(imported: [], own: ownNights(nightlySkinByDay),
                                                  anchorDay: newestDay, cfg: skinCfg, baselineEpoch: recoveryEpoch)
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a baseline
        // exists, and a calibrating (<4-night) baseline would let one noisy RSA night move recovery.
        let respFold = Baselines.foldHistory(respHistory.values, dayKeys: respHistory.dayKeys, cfg: respCfg,
                                             baselineEpoch: respEpoch)
        let skinFold = Baselines.foldHistory(skinHistory.values, dayKeys: skinHistory.dayKeys, cfg: skinCfg,
                                             baselineEpoch: recoveryEpoch)
        // #1614: the per-night HRV fold, traced. HRV only (Charge's dominant driver and the one whose
        // spread the score divides by); capped at the last 14 nights while the whole history is still
        // folded, so the trace describes the baseline the scorer uses. #2525 adds one line naming what each
        // of the four baselines was folded from.
        if TestCentre.active(.recovery) {
            diagnosticSink?(ChargeBaselines.logLine(anchorDay: newestDay, hrv: hrvHistory, restingHR: rhrHistory,
                                                    resp: respHistory, skin: skinHistory), .recovery)
            let traced = Baselines.foldHistoryTrace(hrvHistory.values, dayKeys: hrvHistory.dayKeys, cfg: hrvCfg,
                                                    metric: "hrv",
                                                    baselineEpoch: hrvEpoch,
                                                    tail: 14)
            for line in traced.lines { diagnosticSink?(line, .recovery) }
        }
        let baselines2 = AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hrvHistory.values, dayKeys: hrvHistory.dayKeys, cfg: hrvCfg,
                                       baselineEpoch: hrvEpoch),
            restingHR: Baselines.foldHistory(rhrHistory.values, dayKeys: rhrHistory.dayKeys, cfg: rhrCfg,
                                             baselineEpoch: recoveryEpoch),
            resp: respFold.usable ? respFold : nil,
            skinTemp: skinFold.usable ? skinFold : nil)
        // Zoop: the Charge recipe for this pass. Sleep enters as asleep ÷ personal need; with recovery
        // calibration on, the morning check-ins supply personal weights and the symptom term.
        let chargeScoring = await RecoveryCalibrationStore.scoring(store: store, computedId: computedId,
                                                                   baselines: baselines2,
                                                                   needHours: sleepNeedHours)

        // Real (non-detected) workouts in the scored window, to de-duplicate detected bouts against both
        // cross-source cases (#107): the strap source carries imported and manual rows (under `deviceId`),
        // and apple-health carries Health imports. A detected bout overlapping any of them is skipped
        // below. `computedId` is bound above.
        let windowStart = now - maxDays * 86_400 - StreamReadCap.lookbackSeconds
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                       to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: "apple-health", from: windowStart,
                                                    to: now, limit: 100_000)) ?? []

        markPostLoopPhase("baselines")
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        // #510: backfilled fields for a real (non-detected) row a dropped bout collided with, grouped by
        // the deviceId to upsert under. The detector is an enrichment input; only the opt-in confirmation
        // card creates a visible workout, and legacy `sport="detected"` rows are preserved, not reconciled
        // here.
        var backfilledByDevice: [String: [WorkoutRow]] = [:]
        var restPoints: [MetricPoint] = []
        // User-corrected sleep windows override detected sleep in a day's aggregates, so Rest and recovery
        // honor edits. Scope (#318): only the computed ("-zoop") source; an edit to an imported night
        // changes the displayed session, but its recovery/performance come verbatim from the export and are
        // not recomputed.
        // Self-heal any night edited before its raw streams synced (`Repository.selfHealEditedStages`):
        // re-derive stages over the locked bounds and return refreshed rows. Idempotent; a no-op for
        // imports. Must run before the scoring loop.
        let editedRows = await repo.selfHealEditedStages(from: windowStart, to: now)
        var cycleCandidates: [(owner: String, priority: Int)] = regDevices
            .map { device in
                let priority: Int
                if device.id == regActiveId { priority = 0 }
                else if device.status == .archived { priority = 4 }
                else if device.sourceKind == .activityFile { priority = 3 }
                else if device.isImportSource { priority = 2 }
                else { priority = 1 }
                return (device.id, priority)
            }
        if !cycleCandidates.contains(where: { $0.owner == regActiveId }) {
            cycleCandidates.append((regActiveId, 0))
        }
        let physiologyOwners = ([regActiveId] + regDevices.filter {
            $0.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        }.map(\.id) + [Repository.whoopSource]).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let cycleWorkouts = await repo.workoutRows(days: maxDays + 2)
        let physiologicalSteps = await DayCycleIntelligenceIntegration.compute(
            nights: scoredNights.map { night in
                DayCycleIntelligenceIntegration.Night(
                    daily: night.daily,
                    sleeps: night.cachedSleep,
                    workouts: night.workouts,
                    owner: resolvedScoreOwnerByDay[night.daily.day] ?? regActiveId)
            },
            editedRows: editedRows,
            store: store,
            candidates: cycleCandidates,
            physiologyOwners: physiologyOwners,
            workouts: cycleWorkouts,
            windowStart: windowStart,
            now: now,
            offsetSec: tzOffset,
            habitualMidsleepSec: habitualMidsleepSec,
            ticksPerStep: up.stepTicksPerStep,
            mode: dayCycleMode,
            cache: dayCycleCache,
            profile: up,
            maxHROverride: maxHR,
            effortMethod: effortMethodGlobal,
            trace: stepsTraceActive ? { self.diagnosticSink?($0, .steps) } : nil)
        // #299: `editsByStart` is built per day inside the scoring loop, not window-wide:
        // `sleepEditedDaily` folds any edited row that is not a twin of THIS day's sessions as a "manual"
        // block, so a window-wide set let one edit or nap pin totalSleepMin on every night.

        // Provenance sets for the By-Day badge and diagnostic source token: key-presence sets only (no
        // values) of imported WHOOP days (`hist`, the whole imported history) and Apple days. A WHOOP
        // export wins the dashboard merge over computed (Repository.mergeDaily), then Apple Health
        // (DailyMetricSource.vitalPriority).
        let importedWhoopDays = Set(hist.map { $0.day })
        // The whole apple-health daily history, chronological: a key-presence set for the badge and the
        // SDNN+RHR input for the Apple-Watch recovery fold (a watch-only user has daily aggregates but no
        // raw stream).
        let appleRows = ((try? await store.dailyMetrics(deviceId: Repository.appleHealthSource,
                                                        from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        let appleHealthDays = Set(appleRows.map { $0.day })

        // Recovery (Charge) test mode: gate read once; when true each night emits its Charge breakdown via
        // `recoveryTrace`, which returns the same score `recomputeRecovery` computes, so the headline is
        // unaffected.
        let recoveryTraceActive = TestCentre.active(.recovery)
        let universalTraceActive = TestCentre.active(.universal)
        let workoutsTraceActive = TestCentre.active(.workouts)
        let strictCanonicalAlias = (try? await store.isWhoop5RRSource(deviceId: regActiveId)) ?? true
        let legacySnapshots = await Self.legacyScoreSnapshots(
            store: store, computedId: computedId, from: oldestDay, to: newestDay,
            fresh: scoredNights.map { $0.daily }, ownerByDay: resolvedScoreOwnerByDay,
            nowLocalMidnight: nowLocalMidnight, now: now, offsetSec: tzOffset,
            maxDays: maxDays, strictCanonicalAlias: strictCanonicalAlias)
        var appliedLegacySnapshots: [String: LegacyScoreSnapshot] = [:]
        var paceMark = DispatchTime.now().uptimeNanoseconds
        for night in scoredNights {
            await RescoreBackgroundScheduler.paceIfBackgrounded(since: &paceMark)
            // #299: scope the edits to this day before folding. An edited row or hand-logged nap belongs to
            // the day its night ENDS on (`endTs` is stable under a bedtime edit; only the onset moves), so
            // a single edit overrides only its own night. `effectiveStartTs` (#318) is preserved.
            let dayEditedRows = Self.editedRowsForDay(editedRows, day: night.daily.day, tzOffsetSeconds: tzOffset)
            let editsByStart = Dictionary(dayEditedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
            var daily = sleepEditedDaily(night.daily, detected: night.cachedSleep, editsByStart: editsByStart,
                                         habitualMidsleepSec: habitualMidsleepSec)
            daily = DayCycleIntelligenceIntegration.applying(physiologicalSteps, to: daily)
            daily = Self.recomputeRecoveryDaily(daily, nightlySkinTempC: night.nightlySkin,
                                               baselines: baselines2, charge: chargeScoring)
            let recovery = daily.recovery
            let skinDev = daily.skinTempDevC
            // Charge term-breakdown trace (Recovery test mode only): which term moved Charge and which was
            // nil and forced the renorm. Uses RecoveryScorer.recovery verbatim, so the written score is
            // unchanged.
            if recoveryTraceActive {
                for line in recoveryTraceLines(daily, baselines2, chargeScoring) { diagnosticSink?(line, .recovery) }
            }
            let source = DaySource.classify(day: daily.day, importedWhoopDays: importedWhoopDays,
                                            appleHealthDays: appleHealthDays)
            // Shared engine/UI contract: ordered Charge drivers and the relative skin-temp marker, built
            // from the same inputs `recomputeRecovery` reads so rows cannot disagree with the headline.
            // Empty/nil pre-baseline.
            let drivers = recomputeChargeDrivers(daily, baselines2, chargeScoring)
            let skinRel = RecoveryScorer.skinTempRelative(deviationC: skinDev)
            let chargeConf = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines2.hrv)
            out.append(Computed(day: daily.day, recovery: recovery, strain: daily.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr, source: source, confidence: chargeConf,
                                drivers: drivers, skinTempRel: skinRel))
            // Per-day scoring diagnostic: one privacy-safe line per scored day in the shareable strap log:
            // day key, final total-sleep minutes (after edit substitution), matched sleep blocks, and
            // headline provenance. Counts and rounded minutes only, so reports ship proof of what was
            // computed (e.g. the "Rest repeats across days" question).
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            // #386: the banked stage split and efficiency ride beside the rollup, so totalSleepMin vs the
            // deep+rem+light sum (the identity both screens must agree on) is checkable from an export.
            // Rounded minutes only; stages=nil for unstaged or imported-total-only days.
            let effLog = daily.efficiency.map { String(format: "%.2f", $0) } ?? "nil"
            diagnosticSink?("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                            + "stages=\(Self.sleepStagesLogToken(deep: daily.deepMin, rem: daily.remMin, light: daily.lightMin)) "
                            + "eff=\(effLog) "
                            + "matched=\(night.cachedSleep.count) source=\(source.logToken)", nil)
            // #674/#1244: flag a computed day carrying a sleep total with no matched session (see
            // sleepDivergenceLogLine). Computed days only: an imported-total-only day legitimately has a
            // total without our sessions.
            let dayImported = importedWhoopDays.contains(daily.day) || appleHealthDays.contains(daily.day)
            if !dayImported, let tsm = daily.totalSleepMin, night.cachedSleep.isEmpty {
                diagnosticSink?(Self.sleepDivergenceLogLine(day: daily.day,
                                                            totalSleepMin: Int(tsm.rounded()),
                                                            editFold: dayEditedRows.count), nil)
            }
            // #195: one always-on line per scored night with the computed HRV value and window used, so
            // "HRV reads high / deep-sleep window not changing" is self-diagnosing without HRV test mode
            // (including `avgHrv=nil window=deep` when no deep sleep was detected). Counts-only; must match
            // the Kotlin line.
            let hrvLog = daily.avgHrv.map { String(format: "%.1f", $0) } ?? "nil"
            diagnosticSink?("hrv day=\(daily.day) window=\(deepHrvWindow ? "deep" : "whole") avgHrv=\(hrvLog)", nil)
            if let hrvDiagLine = night.hrvDiag {
                for line in hrvDiagLine.split(separator: "\n", omittingEmptySubsequences: true) {
                    diagnosticSink?(String(line), nil)
                }
            }
            // Universal dayOwner self-diagnostic (#814/#799): one line per scored day tagged `.universal`
            // (rides every Test Centre export, stays off the strap log in normal use). `readId` is the
            // owner the day was read and scored from, `writeActiveId` the registry active id the Collector
            // writes raw under; divergence on a day with HR rows means the dashboard and strap read
            // different namespaces. `hrRows` is the owner's night-window HR count; `provenance` says what
            // backed the day. Counts and ids only; the format is parsed by the export reader, so keep it
            // verbatim.
            if universalTraceActive {
                let owned = readOwnerByDay[daily.day]
                diagnosticSink?(Self.dayOwnerLine(
                    day: daily.day, readId: owned?.owner ?? regActiveId, writeActiveId: regActiveId,
                    hrRows: owned?.hrRows ?? 0, importedWhoop: importedWhoopDays.contains(daily.day),
                    importedApple: appleHealthDays.contains(daily.day)), .universal)
            }
            // Persist the absolute beside the deviation derived from it (#1636), from the same
            // `night.nightlySkin`, so the two cannot describe different nights.
            dailies.append(daily)
            if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            if let onset = physiologicalSteps.onsetByWakeDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day,
                                              key: DayCycleIntelligenceIntegration.onsetKey,
                                              value: Double(onset)))
            }
            // #103: persist the SpO2 candidate @82 nightly mean as "spo2_candidate" under the "-zoop" id
            // for the Blood Oxygen tile's unverified fallback (toggle on). Never to `spo2Pct`: the
            // candidate has split cross-device evidence.
            if let cand = spo2CandidateByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "spo2_candidate", value: Double(cand)))
            }
            // #1118: persist the HRV over-count flag (1/0) so the HRV card can mark an over-counted night
            // unverified. 0 is written on a clean night so a night that flips clean on re-score clears its
            // flag.
            if let oc = hrvOverCountByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "hrv_rr_overcount", value: oc ? 1.0 : 0.0))
            }
            if let v = primarySessionRHRByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session", value: v))
            }
            if let cov = primarySessionRHRCoverageByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session_valid_samples", value: Double(cov.validSamples)))
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session_duration_s", value: cov.durationSec))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // The analytics detector remains an enrichment input for real imported/manual workouts; its
            // generic bouts are not published. The opt-in Today card is the single boundary for creating a
            // visible workout, and `sport="detected"` rows are neither created nor reconciled here.
            // #1545: where the detector lost every candidate on this day, emitted before the per-bout loop
            // so it appears even when that runs zero times (the report it exists for).
            if let f = night.detectionFunnel {
                diagnosticSink?(WorkoutDetector.detectionFunnelLine(day: daily.day, funnel: f), nil)
            }
            for s in night.workouts {
                let durMin = max(0, (s.end - s.start) / 60)
                let avgBpm = Int(s.avgHR)
                // #1545: always-on, one line per detected bout naming what Effort was scored against (HRmax
                // that set the zones, its source, and strap coverage of the bout), which separate "the
                // floor is doing its job", "your HRmax is wrong" and "the sensor dropped out". Same privacy
                // class as the `sleep day=` line.
                diagnosticSink?(WorkoutDetector.boutCalibrationLine(
                    day: daily.day, durMin: durMin, hrmax: s.hrmax, hrmaxSource: s.hrmaxSource,
                    avgHRRPct: s.avgHRRPct, hrCoveragePct: s.hrCoveragePct, strain: s.strain), nil)
                // The overlap test is bare time overlap (any source), so a detected bout collapses against
                // a manual session of a different sport (the #975 "two workouts, one vanished" seam). Find
                // the collider so the trace can name its source.
                if let hit = realWorkouts.first(where: { s.start < $0.endTs && $0.startTs < s.end }) {
                    // #510: the detected bout's avgHR/calories/maxHR/strain come from the motion+HR trace
                    // that found the activity's real boundaries, often tighter than the colliding row's own
                    // (e.g. a manual entry with guessed bounds that clips the HR-rich period). Same natural
                    // key (deviceId, startTs, sport), so the upsert updates in place.
                    let backfilled = WorkoutDetector.backfillWorkout(
                        hit, avgBpm: avgBpm, peakHR: s.peakHR, caloriesKcal: s.caloriesKcal, strain: s.strain)
                    let didBackfill = backfilled != hit
                    if didBackfill {
                        // realWorkouts merges two device groups: the strap's own `deviceId` (imported and
                        // manual rows) and "apple-health". The Swift WorkoutRow carries no deviceId, so
                        // route by that split.
                        let hitDeviceId = hit.source == "apple-health" ? "apple-health" : deviceId
                        backfilledByDevice[hitDeviceId, default: []].append(backfilled)
                    }
                    if workoutsTraceActive {
                        diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                            verdict: didBackfill ? "droppedOverlapBackfilled" : "droppedOverlap",
                            durMin: durMin, avgBpm: avgBpm,
                            overlapSource: WorkoutSource.sourceLabel(hit)), .workouts)
                    }
                    continue
                }
                if workoutsTraceActive {
                    diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                        verdict: "analyticsOnly", durMin: durMin, avgBpm: avgBpm), .workouts)
                }
            }
        }

        markPostLoopPhase("score2")
        // Apple-Watch recovery fold: a watch-only user has apple-health daily aggregates (SDNN HRV +
        // resting HR) but no raw stream, so the import left `recovery: nil`. Fill that gap from the daily
        // aggregate vs the person's own baseline (`WatchRecovery`, which mirrors our Charge shape).
        // WHOOP/computed recovery must keep winning, so skip every day a strap already owns (in `out`, even
        // a cold-start nil night) or a WHOOP import covers. The result is written back onto the
        // apple-health rows and the watch-only days are appended to `out` with their honest confidence.
        let strapRecoveryDays = Set(out.map { $0.day }).union(importedWhoopDays)
        let watchScored = Self.watchRecoveries(appleRows: appleRows, strapRecoveryDays: strapRecoveryDays)
        var appleRecoveryRows: [DailyMetric] = []
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for w in watchScored {
            guard let recovery = w.recovery, let row = appleByDay[w.day] else { continue }
            appleRecoveryRows.append(row.with(recovery: recovery, skinTempDevC: row.skinTempDevC,
                                              skinTempC: row.skinTempC))
            out.append(Computed(day: w.day, recovery: recovery, strain: row.strain,
                                sleepMin: row.totalSleepMin, hrv: row.avgHrv, rhr: row.restingHr,
                                source: .appleHealth, confidence: w.confidence))
        }
        if !appleRecoveryRows.isEmpty {
            _ = try? await store.upsertDailyMetrics(appleRecoveryRows, deviceId: Repository.appleHealthSource)
        }

        markPostLoopPhase("watchFold")
        // #277 migration: days are now keyed by local calendar day, while a prior run wrote the same period
        // under UTC-day keys. Reconcile the computed ("-zoop") daily rows over the recompute window: upsert
        // the local-keyed rows first, then delete only the stale rows the run no longer produces. #521:
        // delete-then-upsert left a non-atomic gap where `repo.days.count` dipped then rose, which the
        // Today inbox announced as "New data added" on a loop; upsert-first keeps the count monotonic.
        // Computed source only; imported "my-whoop" rows are never touched.
        // Source-only Charge/Rest fold for wearable imports (Oura/Fitbit/Garmin/Health Connect, #823): an
        // import-only user has daily aggregates but no raw HR, so the import left recovery nil. Score it
        // from the daily aggregate vs their own baseline with the same `watchRecoveries` engine
        // (RecoveryScorer.recovery verbatim) and write it under the computed source. The engine returns nil
        // + calibrating until the HRV baseline is usable, so nothing is faked. Skip days already scored
        // this pass (`dailies`) or owned by a WHOOP/Apple import. The window matches the computed
        // reconcile, so the rows survive stale eviction.
        var importScoredDays = Set(dailies.map { $0.day }).union(importedWhoopDays).union(appleHealthDays)
        for source in Repository.wearableImportSources {
            let rows = ((try? await store.dailyMetrics(deviceId: source, from: oldestDay, to: newestDay)) ?? [])
                .sorted { $0.day < $1.day }
            guard !rows.isEmpty else { continue }
            let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            for w in Self.watchRecoveries(appleRows: rows, strapRecoveryDays: importScoredDays) {
                guard let recovery = w.recovery, let row = byDay[w.day] else { continue }
                let scored = row.with(recovery: recovery, skinTempDevC: row.skinTempDevC,
                                      skinTempC: row.skinTempC)
                dailies.append(scored)
                importScoredDays.insert(w.day)
                resolvedScoreOwnerByDay[w.day] = source
                if let rest = AnalyticsEngine.Rest.composite(daily: scored) {
                    restPoints.append(MetricPoint(day: w.day, key: "sleep_performance", value: rest))
                }
                out.append(Computed(day: w.day, recovery: recovery, strain: scored.strain,
                                    sleepMin: scored.totalSleepMin, hrv: scored.avgHrv, rhr: scored.restingHr,
                                    source: .computed, confidence: w.confidence))
            }
        }

        // Apply the exact snapshot only after traces and derived series were produced from current inputs.
        // A legacy snapshot must not masquerade as recomputed against today's baselines; it only protects
        // persisted R-R-derived cells from a destructive nil overwrite.
        var persistedDailies = dailies
        for index in persistedDailies.indices {
            let fresh = persistedDailies[index]
            guard let snapshot = legacySnapshots[fresh.day], fresh.avgHrv == nil,
                  (fresh.totalSleepMin ?? 0) > 0 else { continue }
            persistedDailies[index] = fresh.with(avgHrv: snapshot.avgHrv, recovery: snapshot.recovery,
                                                 respRateBpm: snapshot.respRateBpm,
                                                 avgSdnn: snapshot.avgSdnn)
            appliedLegacySnapshots[fresh.day] = snapshot
        }
        for index in out.indices {
            guard let snapshot = appliedLegacySnapshots[out[index].day] else { continue }
            out[index] = out[index].withLegacyScore(hrv: snapshot.avgHrv, recovery: snapshot.recovery)
        }

        // Persist computed scores under the "-zoop" source so the whole dashboard reads them. The
        // Repository merges these under imported "my-whoop" rows, so an import always wins; this only fills
        // days the strap covered and no import did.
        // Snapshot the persisted/merged daily history before the upsert and stale-evict (it includes
        // imported Apple Health / Health Connect resting HR that the computed-only `dailies` lacks), so the
        // Fitness Age gate cannot be undercut by this pass. 30 days back, since fitness age reads 30-day
        // baselines.
        let faPriorDaily = await repo.dailyMetrics(fromDay: Self.shiftDay(newestDay, by: -29), toDay: newestDay)

        // Score provenance is metric-specific and lives outside dayOwnership (solely a resolver override).
        // Persist scores and provenance atomically so a failed write never labels an older score with a
        // newer provider. The last row for a duplicate day wins, matching the upsert.
        var provenanceByCell: [String: ScoreInputProvenanceRow] = [:]
        for daily in persistedDailies {
            guard let source = resolvedScoreOwnerByDay[daily.day] else { continue }
            if daily.recovery != nil {
                if let snapshot = appliedLegacySnapshots[daily.day] {
                    if let oldSource = snapshot.recoverySource {
                        provenanceByCell["\(daily.day)\u{1F}recovery"] =
                            ScoreInputProvenanceRow(day: daily.day, key: "recovery", sourceId: oldSource)
                    }
                } else {
                    provenanceByCell["\(daily.day)\u{1F}recovery"] =
                        ScoreInputProvenanceRow(day: daily.day, key: "recovery", sourceId: source)
                }
            }
            if daily.strain != nil {
                provenanceByCell["\(daily.day)\u{1F}strain"] =
                    ScoreInputProvenanceRow(day: daily.day, key: "strain", sourceId: source)
            }
        }
        for point in restPoints {
            guard let source = resolvedScoreOwnerByDay[point.day] else { continue }
            provenanceByCell["\(point.day)\u{1F}\(point.key)"] =
                ScoreInputProvenanceRow(day: point.day, key: point.key, sourceId: source)
        }
        let markerKeys: [String]
        let markerPoints: [SourcedMetricPoint]
        let markerSources: [String]
        switch physiologicalSteps.markerUpdate {
        case .preserve:
            markerKeys = []; markerPoints = []; markerSources = []
        case let .replace(points, sourceIds):
            markerKeys = [DayCycleIntelligenceIntegration.onsetKey]
            markerPoints = points.map {
                SourcedMetricPoint(deviceId: $0.deviceId, point: $0.point)
            }
            markerSources = sourceIds
        }
        do {
            let dailiesByDay = Dictionary(grouping: persistedDailies, by: \.day)
            let restPointsByDay = Dictionary(grouping: restPoints, by: \.day)
            let provenanceByDay = Dictionary(grouping: provenanceByCell.values, by: \.day)
            let markerPointsByDay = Dictionary(grouping: markerPoints, by: { $0.point.day })
            let windows = preserveUnscoredHistory
                ? dailiesByDay.keys.sorted().map { ($0, $0) }
                : [(oldestDay, newestDay)]
            for (from, to) in windows {
                try await store.persistComputedScores(
                    dailyMetrics: preserveUnscoredHistory
                        ? dailiesByDay[from, default: []] : persistedDailies,
                    metricPoints: preserveUnscoredHistory
                        ? restPointsByDay[from, default: []] : restPoints,
                    provenance: preserveUnscoredHistory
                        ? provenanceByDay[from, default: []] : Array(provenanceByCell.values),
                    deviceId: computedId, from: from, to: to,
                    replaceMetricKeys: markerKeys,
                    additionalMetricPoints: preserveUnscoredHistory
                        ? markerPointsByDay[from, default: []] : markerPoints,
                    replaceMetricSourceIds: markerSources)
            }
        } catch {
            diagnosticSink?("re-score: daily persistence failed; history repair remains pending", nil)
            return
        }

        // Evict only the stale computed rows in the window (those a prior UTC-keyed run left that the
        // local-keyed run no longer produces): diff against the keys just upserted and delete each leftover
        // day individually. Removes #277's UTC/local duplicates without a delete-then-reinsert dip; a no-op
        // in steady state.
        // #1196: skip eviction on an empty pass, so a transient empty `dailies` (incomplete raw store mid
        // offload storm, or the active strap resolving to an empty id) never evicts the window.
        // `persistComputedScores` has the same guard. Must match the Android
        // `WhoopDao.replaceComputedScoreWindow` guard.
        if !preserveUnscoredHistory && !persistedDailies.isEmpty {
            let freshKeys = Set(persistedDailies.map { $0.day })
            let existingWindow = (try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? []
            for stale in existingWindow where !freshKeys.contains(stale.day) {
                _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: stale.day, to: stale.day)
            }
        }
        markPostLoopPhase("persist")
        // Fitness Age, weekly, keyed to the week's Saturday: roll the last 30 days (resting-HR/HRV
        // baselines, activity, sleep regularity) plus profile and Apple Health VO2max/body fat into
        // `FitnessAgeEngine` and upsert the age, per-factor years, inputs and VO2max estimate under
        // "-zoop". Idempotent on the Saturday key.
        let fa7 = dailies.sorted { $0.day < $1.day }.suffix(7)
        let faRHRs = fa7.compactMap { $0.restingHr }.map(Double.init)
        // The Fitness Age gate reads the persisted/merged last-7 days (what the readiness card shows), not
        // this pass's fresh `dailies`: a recompute only re-scores nights whose raw HR is still stored, so a
        // nightly wearer could see <4 RHR nights and Fitness Age never computed (Vitality needs only 3 of
        // any input, so Body Age showed). Gate on the union of pre-rewrite persisted history and fresh
        // scores (fresh wins by day). Kept separate from `fa7`. The gate and compute live in
        // `fitnessAgeRows`, shared with the manual refresh.
        var faGateByDay: [String: DailyMetric] = [:]
        for d in faPriorDaily { faGateByDay[d.day] = d }
        for d in dailies { faGateByDay[d.day] = d }
        let faGate30 = Array(faGateByDay.values.sorted { $0.day < $1.day }.suffix(30))
        let faPts = fitnessAgeRows(satKey: IntelligenceEngine.saturdayKey(onOrBefore: newestDay),
                                   days: faGate30, health: await fitnessHealthSeries())
        if !faPts.isEmpty {
            try? await store.persistMetricSeriesWithProvenance(
                points: faPts,
                provenance: Self.vo2MaxProvenance(points: faPts, waistCm: profile.waistCm),
                deviceId: computedId
            )
        }

        // Vitality / Body Age, weekly, keyed to the week's Saturday: roll the last 7 days' signals (resting
        // HR, sleep duration + regularity, HRV vs age norm, steps) into the mortality-hazard model.
        // `VitalityEngine` gates on >= 3 inputs, so a sparse week writes nothing. VO2max is omitted (it is
        // its own Fitness Age headline).
        let vNights = fa7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let vHRVs = fa7.compactMap { $0.avgHrv }
        let vSteps = fa7.compactMap { $0.steps }.map(Double.init)
        let vInputs = VitalityEngine.Inputs(
            chronoAge: Double(profile.age),
            restingHR: faRHRs.isEmpty ? nil : IntelligenceEngine.medianOf(faRHRs),
            sleepHours: vNights.isEmpty ? nil : vNights.reduce(0, +) / Double(vNights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: vNights),
            rmssd: vHRVs.isEmpty ? nil : IntelligenceEngine.medianOf(vHRVs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: vSteps.isEmpty ? nil : vSteps.reduce(0, +) / Double(vSteps.count))
        if let vRes = VitalityEngine.compute(vInputs) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            _ = try? await store.upsertMetricSeries([
                MetricPoint(day: satKey, key: "vitality", value: vRes.vitality),
                MetricPoint(day: satKey, key: "body_age", value: vRes.bodyAge),
            ], deviceId: computedId)
        }

        markPostLoopPhase("weekly")
        // Steps estimate (WHOOP 4.0), daily, for strap-only days: a 4.0 sends no step count over BLE, so
        // calibrate the strap's daily motion volume against the phone's real steps on days both exist, then
        // apply that coefficient to strap-only days (`StepsEstimateEngine`; this block only orchestrates).
        // Stored under "-zoop" as "steps_est"; idempotent; inert until calibrated or a manual `k` is set.
        // Calibration window 60 days (the weekly engines use 7) so enough both-have days accumulate.
        // Reference steps are the apple-health daily `steps`; motion is the [localMidnight, +24h) gravity
        // volume.
        let stepsCalDays = 60
        let calOldest = AnalyticsEngine.dayString(
            nowLocalMidnight - (stepsCalDays - 1) * 86_400, offsetSec: tzOffset)
        // Hoist the 60-day steps-calibration store reads off the main actor, same stall FIX 1 addressed:
        // each `await store...` would resume on the @MainActor engine (60+ read-resumes per analyzeRecent).
        // They touch only captured immutable inputs, the `WhoopStore` actor, the nonisolated `registry` and
        // static `resolveDayOwner`/`StepsEstimateEngine.dayMotionIntensity`, so the gather runs in one
        // `Task.detached(priority: .utility)` returning Sendable value types (two `[String: Double]`, the
        // updated motion cache, its log line). Fit and `profile.*` assignments stay on main. Bind
        // `deviceId` to a local so the closure captures the value, never `self`.
        let stepsFallbackId = deviceId
        // Seed the fold cache from storage on the process's first pass, so the sixty-day fold is not
        // re-paid after every relaunch. Nothing pass-global feeds the fold; see `StepsMotionCache`.
        if !stepsMotionCacheLoaded {
            stepsMotionCacheLoaded = true
            if let raw = UserDefaults.standard.string(forKey: Self.stepsMotionCacheDefaultsKey) {
                stepsMotionCache = StepsMotionCache.deserialize(raw)
                stepsMotionCachePersisted = raw
            }
        }
        let inStepsMotionCache = stepsMotionCache
        let (refStepsByDay, motionByDay, updatedStepsMotionCache, stepsMotionLogLine):
            ([String: Double], [String: Double], [String: (key: String, motion: Double)], String) =
            await Task.detached(priority: .utility) {
            // Phone reference steps per day (steps > 0). #693: read `appleDaily`, not `dailyMetrics`: the
            // Apple import writes steps to `appleDaily.steps`, so the old read was always empty and
            // calibration never advanced past "Need 3 more days".
            let appleRows = (try? await store.appleDaily(deviceId: Repository.appleHealthSource,
                                                         from: calOldest, to: newestDay)) ?? []
            var refSteps: [String: Double] = [:]
            for r in appleRows { if let s = r.steps, s > 0 { refSteps[r.day] = Double(s) } }
            // Per-day motion volume over the calibration window from the owner-resolved strap streams. Each
            // day is re-folded only when its gravity witness (a COUNT/MAX aggregate over the same index the
            // read walks) moved; a hit replaces a read capped at 200,000 rows with a single-row one. See
            // `StepsMotionCache`.
            var motion: [String: Double] = [:]
            var motionCacheLocal = inStepsMotionCache
            var motionReused = 0
            var motionFolded = 0
            var motionWindow: Set<String> = []
            for off in 0..<stepsCalDays {
                let dayMid = Self.midnightLocal(nowLocalMidnight - off * 86_400, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                let dayKey = AnalyticsEngine.dayString(dayMid, offsetSec: tzOffset)
                motionWindow.insert(dayKey)
                let owner = await Self.resolveDayOwner(day: dayKey, from: dayMid, to: dayEnd, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: stepsFallbackId)
                // A witness that could not be read is not a witness: `(0, 0)` would look like a genuinely
                // empty day and serve a stale zero. On a nil fingerprint bypass the cache both ways: fold
                // fresh, store nothing.
                let fp = try? await store.gravityFingerprint(deviceId: owner, from: dayMid, to: dayEnd)
                let key = fp.map { StepsMotionCache.cacheKey(owner: owner, gravityCount: $0.count,
                                                             gravityMaxTs: $0.maxTs) }
                let m: Double
                if let key, let cached = motionCacheLocal[dayKey], cached.key == key {
                    m = cached.motion
                    motionReused += 1
                } else {
                    // nil is a failed read; `[]` is a day that banked nothing. Collapsing both to zero
                    // would, once cached, turn a transient store error into a stale zero feeding the step
                    // estimate for the life of the process.
                    let gravRead = try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd,
                                                                   limit: 200_000)
                    m = StepsEstimateEngine.dayMotionIntensity(gravRead ?? [])
                    motionFolded += 1
                    // A zero fold from a successful read is cached, otherwise every unworn gap re-reads its
                    // stream each pass to rediscover it is empty. A zero meaning "could not look" is not
                    // cached.
                    if let key, gravRead != nil { motionCacheLocal[dayKey] = (key: key, motion: m) }
                }
                // Only a positive volume becomes a calibration/estimation input. The cache holds the fold,
                // this the filter, so `motionByDay` is unchanged and #1816's `stepsHasBankedMotion` still
                // reads its emptiness.
                if m > 0 { motion[dayKey] = m }
            }
            motionCacheLocal = motionCacheLocal.filter { motionWindow.contains($0.key) }
            let motionLog = StepsMotionCache.logLine(reused: motionReused, folded: motionFolded,
                                                     size: motionCacheLocal.count)
            return (refSteps, motion, motionCacheLocal, motionLog)
        }.value
        stepsMotionCache = updatedStepsMotionCache
        let stepsMotionPayload = StepsMotionCache.serialize(stepsMotionCache)
        if stepsMotionPayload != stepsMotionCachePersisted {
            stepsMotionCachePersisted = stepsMotionPayload
            UserDefaults.standard.set(stepsMotionPayload, forKey: Self.stepsMotionCacheDefaultsKey)
        }
        diagnosticSink?(stepsMotionLogLine, nil)
        let probeCounts = StoreProbeRecorder.take()
        diagnosticSink?(StoreProbeTally.logLine([
            (name: "dayOwner", calls: probeCounts.dayOwner.calls, seconds: probeCounts.dayOwner.seconds),
            (name: "ownerHr", calls: probeCounts.ownerHr.calls, seconds: probeCounts.ownerHr.seconds),
            (name: "gravityFp", calls: probeCounts.gravityFp.calls, seconds: probeCounts.gravityFp.seconds),
        ]), nil)
        // #1816: persist whether the strap banked any motion in the scan window, so the Today tile can tell
        // "Need N more phone-step days" (phone half missing) from "No motion synced yet" (motion half
        // missing, which no number of phone-step days fixes).
        profile.stepsHasBankedMotion = !motionByDay.isEmpty
        let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
            guard let s = refStepsByDay[day] else { return nil }
            return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
        }
        if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
            // Estimate and upsert for each recent scored day with motion but no real phone step count (days
            // the phone counted keep their real value). Runs after any timestamp-heal upstream, so motion
            // is the healed-day motion.
            var estPts: [MetricPoint] = []
            for dm in dailies where refStepsByDay[dm.day] == nil {
                guard let motion = motionByDay[dm.day],
                      let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
            }
            if !estPts.isEmpty { _ = try? await store.upsertMetricSeries(estPts, deviceId: computedId) }
            profile.stepsCalibrationCoefficient = cal.coefficient
            profile.stepsCalibrationSampleDays = cal.sampleDays
            profile.stepsCalibrationConfidence = cal.confidence
            profile.stepsCalibrationManual = cal.manual
        } else {
            // Not yet calibrated (too few overlapping phone-counted days, no manual override): classify the
            // state (#589) and persist progress so the Today tile/Settings can say how many more days are
            // needed. `status` uses the same usable-day filter as the fit. Coefficient stays 0 (the UI's
            // "not calibrated" gate); sampleDays carries the usable-day count.
            let stepsStatus = StepsEstimateEngine.status(calPoints, manualOverride: profile.stepsManualOverride)
            if case let .needsMoreDays(have, _) = stepsStatus {
                profile.stepsCalibrationCoefficient = 0
                profile.stepsCalibrationSampleDays = have
                profile.stepsCalibrationConfidence = 0
                profile.stepsCalibrationManual = false
            }
        }

        // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points,
        // fitted/manual/withheld state) and a per-day estimate line, tagged `.steps`. Reuses
        // `StepsEstimateEngine.calibrate/estimate` verbatim, so it cannot diverge from the coefficient and
        // steps_est just written.
        if stepsTraceActive {
            for line in StepsEstimateEngine.calibrationTrace(points: calPoints,
                                                             manualOverride: profile.stepsManualOverride) {
                diagnosticSink?(line, .steps)
            }
            if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                for dm in dailies where refStepsByDay[dm.day] == nil {
                    guard let motion = motionByDay[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                    diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                        + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                }
            }
        }

        markPostLoopPhase("steps")
        // Drop any freshly detected session that overlaps a night the user hand-corrected. A detected onset
        // drifts as raw data arrives, so the re-detected night would upsert as a second row (different
        // startTs, no ON CONFLICT match) and mergeDay would double-count time-in-bed. Sleep has no
        // delete-reinsert pass, so this is the idempotency guard (#318).
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        // #68: also drop any re-detected night the user deleted (a dismissedSleep tombstone), by overlap
        // rather than exact startTs because the onset drifts. Twin of Android `dismissedWindows`.
        let dismissedWindows = repo.dismissedSleepWindows()
        let skipWindows = editedWindows + dismissedWindows
        let cachedSleepKept = cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        do {
            if !cachedSleepKept.isEmpty {
                _ = try await store.upsertSleepSessions(cachedSleepKept, deviceId: computedId)
            }
        } catch {
            diagnosticSink?("re-score: sleep persistence failed; history repair remains pending", nil)
            return
        }
        // Persist per-epoch motion (H8) beside each kept session's stagesJSON, only for sessions actually
        // kept (not edited/dismissed), keyed by the detected start `analyzeDay` returned. A session whose
        // gravity would not grid stays NULL; an absent series is never a fabricated zero array.
        let keptStarts = Set(cachedSleepKept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        // Persist per-epoch band sleep_state (#175) beside each kept session's stagesJSON, so the next
        // pass's `bandSleepStateSamples` (the H7 confirm) and the display can see the strap's own scored
        // band. Kept sessions only; a session with no band samples stays NULL.
        var sleepStateByStart: [Int: [Int]] = [:]
        for night in scoredNights {
            for (start, states) in night.sessionSleepState where keptStarts.contains(start) {
                sleepStateByStart[start] = states
            }
        }
        for (start, states) in sleepStateByStart {
            _ = try? await store.persistSessionSleepState(deviceId: computedId, sessionStart: start, states: states)
        }
        markPostLoopPhase("sleepWrite")
        // Overlap-aware banked-sleep heal (#899): an unstable strap clock re-banks the same night under a
        // shifted timebase, so the upsert lands a second row beside the stale one (the (deviceId, startTs)
        // key differs and sleep has no delete-reinsert reconcile). Collapse the window's stored sessions
        // with the overlap rule, using the rows this pass banked as the bank-recency witness, and delete
        // the stale copies. Scoped to sessions whose wake day lies in the [oldestDay, newestDay] reconcile
        // window; edited rows are never dropped.
        // #1248: heal every device that banks sleep in this window, not just `computedId` (an Oura ring
        // banks its own hypnogram under its own id; un-healed ring rows were re-read as `providedSleep` and
        // re-detected every pass, ballooning one night to 14 rows). Dedup each device's rows among
        // themselves and delete under that same id, never across ids.
        // `freshStarts` goes only to the computedId sweep; other ids use longest-wins. On an Oura day the
        // pass's sessions ARE the ring's `providedSleep` rows with `startTs` copied verbatim, so ranking
        // them "fresh" outranked fuller re-serves banked mid-pass (iOS can suspend for hours) and the heal
        // deleted a 598-min night in favour of a 337-min row. `SleepSessionDedup.healWitness` is the shared
        // rule (twin of Kotlin's). Sorted for determinism.
        let healDeviceIds = Self.healDeviceIds(computedId: computedId, registeredIds: regDevices.map { $0.id })
        // Compact row shape for the #1284 heal log: stage-segment count and decoded JSON length,
        // adjudicating which copy is fuller, in the same format as `dupGenShape`. Window and shape counts
        // only, never stage content or vitals.
        func sleepShape(_ s: CachedSleepSession) -> String {
            let json = s.stagesJSON ?? ""
            let segs = json.components(separatedBy: "\"stage\"").count - 1
            return "[\(s.startTs) -> \(s.endTs)] min=\((s.endTs - s.effectiveStartTs) / 60) segs=\(segs) json=\(json.utf8.count)"
        }
        var healDropped: [CachedSleepSession] = []
        for healId in healDeviceIds {
            let storedSessions = (try? await store.sleepSessions(deviceId: healId, from: windowStart,
                                                                 to: now, limit: 4000)) ?? []
            let healable = storedSessions.filter {
                (oldestDay...newestDay).contains(AnalyticsEngine.dayString($0.endTs, offsetSec: tzOffset))
            }
            let witness = SleepSessionDedup.healWitness(for: healId, computedId: computedId, keptStarts: keptStarts)
            let sweep = SleepSessionDedup.dedupe(healable, freshStarts: witness)
            for stale in sweep.dropped {
                _ = try? await store.deleteSleepSession(deviceId: healId, startTs: stale.startTs)
                // #1284: log which copy was dropped and which survived, so the corpus can confirm the heal
                // keeps the fuller / end-correct row (the survivor the collapse resolved this stale into).
                if let survivor = sweep.kept.first(where: { SleepSessionDedup.isDuplicate($0, stale) }) {
                    diagnosticSink?("Dedup(#1284): dropped \(sleepShape(stale)) kept \(sleepShape(survivor)) - heal", nil)
                }
            }
            healDropped.append(contentsOf: sweep.dropped)
        }
        diagnosticSink?("Dedup(#899): swept \(healDeviceIds.count) device id(s), removed "
            + "\(healDropped.count) overlapping duplicate session(s).", nil)
        if !healDropped.isEmpty {
            diagnosticSink?("Dedup(#899): removed \(healDropped.count) overlapping duplicate sleep "
                + "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.", nil)
            // Re-score against the cleaned store via the #899 re-arm: this pass's days consumed the
            // read-side deduped view, which had no bank-recency witness, so its survivor can differ from
            // the heal's. One forced re-pass reconciles them. Hard-bounded: if the re-pass's own heal drops
            // rows again it does not re-arm (matches Android); the budget restores once a pass heals
            // nothing.
            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                pendingRescore = QueuedRescore.merge(pendingRescore, unconditional: true, label: "dedup-heal")
            }
        } else {
            healRearmedThisCycle = false
        }
        // #1735/#2187: never delete/reinsert legacy detected history during scoring; a disabled toggle,
        // rescoring pass, missing stream or failed insert must not erase a workout the user saw. #510:
        // still write back real (manual/imported) rows an analytics bout backfilled, one upsert per owning
        // deviceId.
        for (devId, rows) in backfilledByDevice {
            _ = try? await store.upsertWorkouts(rows, deviceId: devId)
        }

        markPostLoopPhase("sleepHeal")
        // #137: a manually started workout is scored from sparse live HR at save time (near-zero
        // calories/strain on a 5/MG); re-score under-sampled ones from the denser offloaded HR.
        // #950: score against the wearer's measured resting HR, not the hardcoded 60, so a workout's Effort
        // is comparable with its day's. The most recent scored day with one is the best estimate; nil keeps
        // the default. Use FIRST not last: `out` is newest-first (the loop counts back from today), so the
        // last match would be up to `maxDays` old.
        let measuredResting = out.first(where: { $0.rhr != nil })?.rhr.map(Double.init)
        await rescoreManualWorkouts(store: store, profile: up, restingHR: measuredResting,
                                    effortMethod: effortMethodGlobal)

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with Zoop connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        if !dailies.isEmpty || !healDropped.isEmpty { await repo.refresh() }

        markPostLoopPhase("workouts")
        // #836: record the complete raw-analysis fingerprint this run scored against, so a later non-forced
        // tick can short-circuit. Written only at the end of a completed run, so an interrupted run cannot
        // advance the watermark past unscored data.
        if !wmKey.isEmpty { UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey) }
        markPostLoopPhase("tail")
        diagnosticSink?(AnalysisPhaseTally.logLine(scope: "postLoop", postLoopPhases), nil)
        // #1538: clear the started-mark and bank what a completed pass costs on this install, so
        // `RescoreBackgroundPolicy` can tell one that finishes in a background wake from one that never
        // could (cost varies by more than an order of magnitude with history size).
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- reScoreStart) / 1_000_000_000
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: elapsed, owedToken: owedToken)
        diagnosticSink?("re-score: done — scored \(scoredNights.count) night(s) in \(Int(elapsed * 1000)) ms (#1005)", nil)
        diagnosticSink?(RescoreBackgroundScheduler.passCostLogLine(
            cpuSeconds: RescoreBackgroundScheduler.processCPUSeconds().flatMap { end in reScoreCPUStart.map { end - $0 } },
            elapsedSeconds: elapsed,
            assertionExpiries: RescoreBackgroundScheduler.assertionExpiries - reScoreExpiriesAtStart,
            backgroundedAtEnd: RescoreBackgroundScheduler.isBackgrounded), nil)
        // #1681: a pass that completes with the mark still set looks identical in a capture to one that
        // cleared it. Rare-event evidence, so always-on.
        if !settled {
            diagnosticSink?("re-score: debt NOT settled — a newer re-score was recorded while this pass "
                            + "was running, so the mark stays and another pass will run (#1681)", nil)
        }
        // New-data debt does not invalidate the repair writes that just succeeded (#2606).
        // Cancellation and persistence failures still leave the repair flags unset.
        if !Task.isCancelled { onPersisted?() }
    }

    /// UserDefaults key for the #836 idle-tick gate: the raw-analysis fingerprint the last completed
    /// `analyzeRecent` scored against. A non-forced tick with an equal fingerprint skips the rescore; any
    /// scoring-stream insert moves the fingerprint, so it self-heals.
    private static let analyzeWatermarkKey = "zoop.analyzeWatermark"

    /// Builds the universal `dayOwner` self-diagnostic line verbatim (#814/#799); the Test Centre export
    /// parser depends on the exact shape. `readId` is the owner the day was read and scored from;
    /// `writeActiveId` the registry active id the Collector writes under; divergence on a day with HR rows
    /// is the #814 split. `provenance` is `imported:whoop`/`imported:apple` when an export covers the day,
    /// else `measured` if the owner returned HR, else `none`. Pure and nonisolated. No PII.
    nonisolated static func dayOwnerLine(day: String, readId: String, writeActiveId: String,
                                         hrRows: Int, importedWhoop: Bool, importedApple: Bool) -> String {
        let provenance: String
        if importedWhoop { provenance = "imported:whoop" }
        else if importedApple { provenance = "imported:apple" }
        else if hrRows > 0 { provenance = "measured" }
        else { provenance = "none" }
        return "dayOwner day=\(day) readId=\(readId) writeActiveId=\(writeActiveId) "
            + "hrRows=\(hrRows) provenance=\(provenance)"
    }

    /// Resolves the single device that owns `day` (invariant I2). A locked override wins; otherwise devices
    /// are probed by priority (0 active strap, 1 other live straps, 2 imports, 3 activity files, 4
    /// archived; lower wins) until one has HR for the day. Returns `fallbackDeviceId` when none, preserving
    /// the legacy single-source path. A single-device install returns it without a probe.
    /// `nonisolated static` so the off-main scan loop can call it without hopping back to the main actor
    /// each iteration.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String) async -> String {
        let lockedStarted = DispatchTime.now().uptimeNanoseconds
        let lockedOwner = (try? registry.dayOwner(day))?.deviceId
        StoreProbeRecorder.record(.dayOwner, nanos: DispatchTime.now().uptimeNanoseconds &- lockedStarted)
        if let lockedOwner {
            return lockedOwner
        }
        guard !devices.isEmpty else { return fallbackDeviceId }

        // #970: the default single-WHOOP install has one device that IS the fallback id, so the owner is a
        // foregone conclusion (priority 0, or no data, both yield the fallback). Skip the per-day LIMIT-1
        // HR probe (saves ~maxDays reads per pass). The guard is deliberately `== fallbackDeviceId`: a lone
        // import device with a different id would resolve differently and must still probe.
        if devices.count == 1, devices[0].id == fallbackDeviceId {
            return fallbackDeviceId
        }

        // Probe in priority order and stop at the first candidate with data. `DayOwnerResolver.resolve`
        // takes the lowest-priority-number candidate with data, so later probes cannot change the answer
        // (the 60-day steps window with two straps would otherwise cost 120 queries per pass).
        // `DayOwnerResolverEquivalenceTests` pins this against the resolver. The probe is a scalar EXISTS,
        // not a fetched row.
        // #137: an activity-file ride (priority 3) ranks below whole-day imports (2), so a full-day WHOOP
        // import keeps a day it has HR for. Mirrors Kotlin RegistryDayOwnerSource.
        let ranked: [(id: String, priority: Int)] = devices.map { d in
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority: Int
            if d.id == activeId { priority = 0 }
            else if d.status == .archived { priority = 4 }
            else if d.sourceKind == .activityFile { priority = 3 }
            else if isImport { priority = 2 }
            else { priority = 1 }
            return (d.id, priority)
        }
        // Sort on (priority, original index): Swift's `sorted` is not stable by contract, so two non-active
        // straps sharing priority 1 could return in either order and the first-with-data probe would pick
        // either. Kotlin's `sortedBy` is stable and takes the first minimum; carrying the index makes the
        // order total and matches.
        .enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
        .map(\.element)
        for c in ranked {
            if (try? await store.hasHrInWindow(deviceId: c.id, from: from, to: to)) == true { return c.id }
        }
        return fallbackDeviceId
    }

    /// The strap family that wrote `owner`'s skin-temp rows (#938), so the nightly funnel converts the raw
    /// register on the right scale. Mapping and the `.whoop5` fallback live in
    /// `DeviceFamily.forRegistryDevice`.
    nonisolated static func skinTempFamily(forOwner owner: String, devices: [PairedDevice]) -> DeviceFamily {
        let d = devices.first(where: { $0.id == owner })
        return DeviceFamily.forRegistryDevice(model: d?.model, brand: d?.brand) ?? .whoop5
    }

    /// #1467: the skin-temp worn gate's timestamp tolerance for `owner`: 0 (exact match) for a WHOOP strap,
    /// whose HR and skin-temp are one co-sampled 1 Hz stream. An Oura ring streams them on independent
    /// clocks (dense HR, ~1/min skin-temp), so exact-second matching caught only ~40-55% of worn samples
    /// and every one of 7 real nights fell under `minSkinTempSamples`. Same registry lookup as
    /// `skinTempFamily`; separate from `DeviceFamily`, which has no Oura case (#1086).
    nonisolated static func skinTempWornToleranceSec(forOwner owner: String, devices: [PairedDevice]) -> Int {
        devices.first(where: { $0.id == owner })?.brand == "Oura"
            ? AnalyticsEngine.defaultOuraWornToleranceSec : 0
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from sparse live HR
    /// (5/MG), so calories/strain land near zero; once offloaded HR covers its window, recompute from it.
    /// Conservative and idempotent: only `manual` rows with negligible calories, and only on a genuine
    /// improvement.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile,
                                       restingHR: Double? = nil,
                                       // #1545: the recipe this pass scored its days with, threaded in
                                       // rather than re-read, so a toggle flipped mid-pass cannot score a
                                       // workout and its day by different recipes.
                                       effortMethod: StrainScorer.Method = .edwards) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        let hrMax = Double(profile.hrMax)
        var updated: [WorkoutRow] = []
        // Eligible when under-scored (negligible kcal, #137) or missing strain (a merged workout's kcal is
        // a SUM, so it never looks under-scored yet Effort stays blank). `improves` accepts a strain-only
        // gain for the latter.
        for row in rows where row.source == "manual"
            && (ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) || row.strain == nil) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax,
                                                      restingHR: restingHR,
                                                      effortMethod: effortMethod),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal, currentStrain: row.strain,
                                                allowStrainOnlyFill: true)
            else { continue }
            // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
            // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
            let kcalBeatsStored = (s.kcal ?? 0) > (row.energyKcal ?? 0) + ManualWorkoutRescore.improvementMarginKcal
            let energyKcal = kcalBeatsStored ? s.kcal : row.energyKcal
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: energyKcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes,
                steps: row.steps))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Pass 1 has no seeded skin baseline. Attach the deviation before scoring so the score,
    /// explanation, trace and persisted row all consume the same temperature. Internal for regression tests.
    static func recomputeRecoveryDaily(_ daily: DailyMetric, nightlySkinTempC: Double?,
                                       baselines: AnalyticsEngine.ProfileBaselines,
                                       charge: ChargeScoring = .standard) -> DailyMetric {
        let skinDev = recomputeSkinTempDev(nightlySkinTempC, baselines.skinTemp)
        let input = daily.with(recovery: daily.recovery, skinTempDevC: skinDev, skinTempC: nightlySkinTempC)
        return input.with(recovery: recomputeRecovery(input, baselines, charge), skinTempDevC: skinDev,
                          skinTempC: nightlySkinTempC)
    }

    /// Resolves conservative legacy snapshots before the computed-window upsert can replace them. The date
    /// loop reuses the scorer's own day/window arithmetic, keeping DST behaviour and today's shortened
    /// forward window identical to the scoring read.
    private static func legacyScoreSnapshots(
        store: WhoopStore, computedId: String, from: String, to: String,
        fresh: [DailyMetric], ownerByDay: [String: String],
        nowLocalMidnight: Int, now: Int, offsetSec: Int, maxDays: Int,
        strictCanonicalAlias: Bool
    ) async -> [String: LegacyScoreSnapshot] {
        let existing = (try? await store.dailyMetrics(deviceId: computedId, from: from, to: to)) ?? []
        let existingByDay = Dictionary(existing.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var snapshots: [String: LegacyScoreSnapshot] = [:]
        for day in fresh {
            guard day.avgHrv == nil, let old = existingByDay[day.day], let oldHrv = old.avgHrv,
                  let owner = ownerByDay[day.day] else { continue }
            var dayStart: Int?
            for offset in 0..<maxDays {
                let candidate = nowLocalMidnight - offset * 86_400
                if AnalyticsEngine.dayString(candidate, offsetSec: offsetSec) == day.day {
                    dayStart = candidate
                    break
                }
            }
            guard let dayStart else { continue }
            let readFrom = dayStart - StreamReadCap.lookbackSeconds
            let readTo = sleepReadWindowEnd(dayStart: dayStart, nowLocalMidnight: nowLocalMidnight, now: now)
            let alias = strictCanonicalAlias && owner == Repository.whoopSource
            guard (try? await store.legacyWhoop5RRWithheld(
                deviceId: owner, from: readFrom, to: readTo,
                unlabelledAliasOfWhoop5: alias)) == true else { continue }
            snapshots[day.day] = LegacyScoreSnapshot(
                avgHrv: oldHrv, recovery: old.recovery,
                respRateBpm: old.respRateBpm, avgSdnn: old.avgSdnn,
                recoverySource: try? await store.scoreInputSource(
                    deviceId: computedId, day: day.day, key: "recovery"))
        }
        return snapshots
    }

    /// Re-scores only the recovery composite for a day against a re-seeded baseline; every other field is
    /// final from pass 1. Nil until the HRV baseline is usable (>= minNightsSeed valid nights), so cold
    /// start is honest (#78).
    private static func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines,
                                          _ charge: ChargeScoring) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest composite (/100) as the sleep-quality term instead of raw
        // efficiency and fold in the night's skin-temp deviation, both from persisted daily fields (raw
        // streams are gone in pass 2).
        let restQuality = charge.sleepTerm(daily)
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC,
                                       weights: charge.weights, symptomLoad: charge.symptomLoad(daily.day))
    }

    /// The ordered "what shaped it" Charge driver list for one day (shared contract). Pure: feeds the same
    /// inputs and `restQuality` as `recomputeRecovery` into `RecoveryScorer.chargeDrivers`, so rows cannot
    /// diverge from the written Charge number. Empty when a hard input (HRV/RHR/HRV-baseline) is missing or
    /// the baseline is not yet usable.
    private func recomputeChargeDrivers(_ daily: DailyMetric,
                                        _ baselines: AnalyticsEngine.ProfileBaselines,
                                        _ charge: ChargeScoring) -> [ChargeDriver] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return []
        }
        let restQuality = charge.sleepTerm(daily)
        return RecoveryScorer.chargeDrivers(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                            respBaseline: baselines.resp, sleepPerf: restQuality,
                                            skinTempDev: daily.skinTempDevC,
                                            weights: charge.weights, symptomLoad: charge.symptomLoad(daily.day))
    }

    /// Charge term-breakdown trace lines for one day (Recovery test mode). Pure: same inputs as
    /// `recomputeRecovery` into RecoveryScorer's side-effect-free `recoveryTrace`, so it cannot diverge.
    /// Empty when a hard input is missing; only called when `TestCentre.active(.recovery)`.
    /// Built on the standard weights without the check-in symptom term; when the day is scored with
    /// personal weights or symptoms a trailing `calibrated` line says the traced score is not the persisted
    /// one.
    private func recoveryTraceLines(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines,
                                    _ charge: ChargeScoring) -> [String] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return ["charge day=\(daily.day) nilScore reason=missingInput "
                + "(hrv/rhr/hrvBaseline required)"]
        }
        let restQuality = charge.sleepTerm(daily)
        let (_, trace) = RecoveryScorer.recoveryTrace(
            hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp, sleepPerf: restQuality,
            skinTempDev: daily.skinTempDevC)
        var lines = trace.map { line in
            let body = line.hasPrefix("charge ") ? String(line.dropFirst("charge ".count)) : line
            return "charge day=\(daily.day) " + body
        }
        let load = charge.symptomLoad(daily.day)
        if charge.weights != .standard || (load ?? 0) > 0 {
            let w = charge.weights
            lines.append("charge day=\(daily.day) calibrated weights=hrv:\(w.hrv) rhr:\(w.rhr) sleep:\(w.sleep) "
                + "resp:\(w.resp) skin:\(w.skinTemp) symptomLoad=\(load ?? 0) (score above uses standard weights)")
        }
        return lines
    }

    struct WatchScoredDay: Equatable {
        let day: String
        let recovery: Double?
        let confidence: ScoreConfidence
    }

    /// Apple-Watch recovery (Charge) for apple-health days that lack a strap recovery. The watch gives
    /// daily aggregates (SDNN HRV + resting HR), not raw HR, so `analyzeRecent` never scores these days.
    /// For each day, fold the trailing SDNN + RHR history into the `WatchRecovery` engine; it stays nil +
    /// `.calibrating` until enough nights exist, so no number is fabricated.
    /// `strapRecoveryDays` (days a strap already scored) are skipped so the strap keeps winning. Pure;
    /// `appleRows` must be chronological.
    nonisolated static func watchRecoveries(appleRows: [DailyMetric],
                                strapRecoveryDays: Set<String> = []) -> [WatchScoredDay] {
        let rows = appleRows.sorted { $0.day < $1.day }
        var out: [WatchScoredDay] = []
        for (i, row) in rows.enumerated() where !strapRecoveryDays.contains(row.day) {
            let prior = rows[..<i]
            let sdnnHistory = prior.compactMap { $0.avgHrv }
            let rhrHistory = prior.compactMap { $0.restingHr.map(Double.init) }
            let res = WatchRecovery.compute(todaySDNN: row.avgHrv,
                                            todayRHR: row.restingHr,
                                            sdnnHistory: sdnnHistory,
                                            rhrHistory: rhrHistory)
            out.append(WatchScoredDay(day: row.day, recovery: res.recovery, confidence: res.confidence))
        }
        return out
    }

    /// #299: the edited / hand-logged sleep rows that belong to `day`: the ones whose edits may fold into
    /// that day's total. An edit belongs to the day its night ENDS on (`dayString(endTs)`; `endTs` is
    /// stable under a bedtime edit). Scoping per day fixes a window-wide set leaking one edit or nap onto
    /// every night, since `sleepEditedDaily` folds any row that is not a twin of the day's detected
    /// sessions as a "manual" block. Must match Android `editedRowsForDay`.
    static func editedRowsForDay(_ editedRows: [CachedSleepSession], day: String,
                                 tzOffsetSeconds: Int) -> [CachedSleepSession] {
        editedRows.filter { AnalyticsEngine.dayString($0.endTs, offsetSec: tzOffsetSeconds) == day }
    }

    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession],
                                 habitualMidsleepSec: Int?) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged nap is a userEdited row with no detected twin, so the substitution pass never
        // visits it and its minutes were dropped from Rest. Pass twinless rows through the union channel
        // (#518/#508).
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        // #525/#547: supply each block's effective onset keyed by detected startTs, plus the tz offset and
        // habitual midsleep, so the edited recompute picks the same main night the Sleep tab shows. Use the
        // user-corrected bedtime (`startTsAdjusted ?? startTs`), not the immutable detected start, or a
        // bedtime edit crossing the overnight boundary makes the seam and the Sleep tab pick different
        // blocks. Without these the seam falls back to the legacy SUM and re-includes a nap in the
        // headline.
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   offsetSec: TimeZone.current.secondsFromGMT(),
                                                                   habitualMidsleepSec: habitualMidsleepSec),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    /// Re-derives the night's skin-temperature deviation (C) against the freshly seeded baseline. Nil when
    /// no wear-gated mean exists or the baseline is not usable yet (< minNightsSeed). Rounded to 2 dp.
    /// APPROXIMATE.
    private static func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// The user's habitual midsleep (local seconds), or nil under `habitualMinDays` of history. One
    /// `HistoryBlock` per stored session (imported + computed, effective bounds so a corrected bedtime is
    /// learned, local-day key of the midpoint), deferring to `SleepStageTotals.habitualMidsleepSec`
    /// (longest block per day; naps drop out). The two sets can overlap; the learner de-dupes per day by
    /// length (#547).
    /// History block for `bandSleepStateSamples`: the prior pass's persisted v18 band sleep_state for
    /// sessions overlapping `[from, to]`, expanded to `(ts, state)` samples on the 30 s epoch grid (epoch
    /// `i` at `startTs + i*30`, matching SleepStager's grid) for the H7 re-onset confirmation. NULL when
    /// never banded; empty then, so the guard falls back to the HR bar. Only real banded states are
    /// surfaced. `nonisolated static`: touches only the `store` actor and value params.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: WhoopStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        // #899: collapse overlapping timebase-shifted duplicates before consuming band state, or a stale
        // re-banked copy feeds "asleep" epochs at old times into the H7 re-onset guard. Read-side only; the
        // store is healed post-upsert in analyzeRecent.
        let sessions = SleepSessionDedup.dedupe(
            (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                            limit: 4000)) ?? []).kept
        let stateByStart = (try? await store.sessionSleepStates(deviceId: computedId,
                                                                from: from, to: to)) ?? [:]
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = stateByStart[s.startTs], !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    /// Habitual midsleep (local seconds) and trailing per-night sleep durations (hours, chronological) from
    /// stored sessions, the longest block per local day (naps drop out). One read serves the main-night
    /// midsleep learner (#547) and the personal sleep need and regularity threaded into `analyzeDay`.
    /// Only sessions that ended before `finishedBefore` (the pass's local midnight) are learned from:
    /// tonight's session is re-banked by every sync while growing and each move changed the day-cache
    /// signature, re-scoring all 21 nights from scratch (a field log: 8 813 s and 2 345 s passes). It joins
    /// the history the day after. Internal only so a test can drive the cutoff.
    static func computeHabitualSleep(
        store: WhoopStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, finishedBefore: Int, offsetSec: Int
    ) async -> (midsleepSec: Int?, nightlyHours: [Double]) {
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        // #899: collapse overlapping timebase-shifted duplicates before the learner sees the history. A
        // stale re-banked copy lands on a different day key, so the per-day longest-block de-dup never
        // caught it and the learned midsleep drifted. This also covers an imported night and its computed
        // twin (longest capture wins).
        let merged = SleepSessionDedup.dedupe(imported + computed).kept.filter { $0.endTs < finishedBefore }
        // Longest block per local day (naps drop out), chosen by in-bed span, reused for both the midsleep
        // learner and the durations so they cannot read different histories. Durations keep TST (span x
        // efficiency), not in-bed span: need/regularity must be in the asleep-time units `tstSeconds` Rest
        // scores against, or need reads high (in-bed over-counts ~0.85 h). Efficiency is 0..1 (post v26
        // unit-heal); a nil main night falls back to 0.9.
        var longestByDay: [String: (span: Int, tstHours: Double)] = [:]
        let blocks = merged.compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            let span = end - start
            if span > (longestByDay[dayKey]?.span ?? 0) {
                let eff = s.efficiency.flatMap { (0.0 < $0 && $0 <= 1.0) ? $0 : nil } ?? 0.9
                longestByDay[dayKey] = (span, Double(span) / 3600.0 * eff)
            }
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        let midsleep = SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
        let nightlyHours = longestByDay.keys.sorted().compactMap { longestByDay[$0]?.tstHours }
        return (midsleep, nightlyHours)
    }

    nonisolated static func midnightUtc(_ ts: Int) -> Int { ts - floorMod(ts, 86_400) }

    /// Floors a unix-seconds timestamp to 00:00:00 of its local calendar day (#277); `offsetSec` is seconds
    /// east of UTC. `ts - floorMod(ts + offsetSec, 86400)` is correct for negative offsets and timestamps;
    /// offset 0 reduces to `midnightUtc`. Must match Android `midnightLocal` byte for byte.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (sign of the divisor), matching Java `Math.floorMod`. Swift's `%` takes the
    /// dividend's sign and would mis-floor negatives.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

// `internal`, not `private`: the two `with(...)` rebuilds respell every field by name, the easiest place to
// drop a new DailyMetric column, so StrandTests asserts them directly.
extension DailyMetric {
    /// Rebuild with the exact legacy R-R-derived snapshot while keeping every other freshly-scored cell.
    func with(avgHrv hrv: Double, recovery r: Double?, respRateBpm resp: Double?,
              avgSdnn sdnn: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: hrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: resp,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: sdnn, skinTempC: skinTempC,
                    sleepHrOnly: sleepHrOnly)
    }

    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?, skinTempC sa: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn, skinTempC: sa,
                    sleepHrOnly: sleepHrOnly)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn,
                    skinTempC: skinTempC, sleepHrOnly: sleepHrOnly)
    }
}
