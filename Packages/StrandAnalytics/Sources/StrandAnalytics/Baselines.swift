import Foundation

// Personal rolling baselines per nightly metric. Two paths, both producing a `BaselineState`:
// 1. Winsorized EWMA (production, `update`/`foldHistory`): recency-weighted centre, EWMA-of-absolute-
//    deviation spread, cold-start gating, hard-outlier rejection, Winsor clamping.
// 2. Trailing-window mean/SD (`rollingMeanSD`): simple and auditable, for explainability and cross-checks.

/// Per-metric configuration for the baseline model.
public struct MetricCfg: Equatable, Sendable {
    public let minVal: Double       // physiological lower bound (hard reject below)
    public let maxVal: Double       // physiological upper bound (hard reject above)
    public let floorSpread: Double  // σ_floor: minimum dispersion
    public let halfLifeB: Double    // baseline-center half-life (nights)
    public let halfLifeS: Double    // spread half-life (nights, slower than center)

    public init(minVal: Double, maxVal: Double, floorSpread: Double,
                halfLifeB: Double, halfLifeS: Double) {
        self.minVal = minVal
        self.maxVal = maxVal
        self.floorSpread = floorSpread
        self.halfLifeB = halfLifeB
        self.halfLifeS = halfLifeS
    }
}

/// Baseline status (cold-start, trusted, stale).
public enum BaselineStatus: String, Equatable, Sendable {
    case calibrating  // fewer than MIN_NIGHTS_SEED valid nights; no score yet
    case provisional  // between seed and trust thresholds; usable, higher uncertainty
    case trusted      // at least MIN_NIGHTS_TRUST valid nights
    case stale        // usable but no update for > STALE_DAYS nights
}

/// Immutable snapshot of a personal baseline for one metric.
public struct BaselineState: Equatable, Sendable {
    /// Robust EWMA centre (the personal mean).
    public let baseline: Double
    /// EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253 to approximate Gaussian sigma.
    public let spread: Double
    /// Valid nights contributing to the state.
    public let nValid: Int
    /// Consecutive nights with no valid value.
    public let nightsSinceUpdate: Int
    /// Cold-start / staleness status.
    public let status: BaselineStatus

    public init(baseline: Double, spread: Double, nValid: Int,
                nightsSinceUpdate: Int, status: BaselineStatus) {
        self.baseline = baseline
        self.spread = spread
        self.nValid = nValid
        self.nightsSinceUpdate = nightsSinceUpdate
        self.status = status
    }

    /// Fully trusted (not calibrating or stale).
    public var trusted: Bool { status == .trusted }
    /// At least provisionally usable (nValid >= minNightsSeed).
    public var usable: Bool { status == .provisional || status == .trusted }
}

/// Three forms of deviation from a personal baseline.
public struct Deviation: Equatable, Sendable {
    /// Robust z-score: (value - baseline) / (1.253 x spread).
    public let z: Double
    /// Signed delta in physical units.
    public let delta: Double
    /// Fractional deviation: value / baseline - 1.
    public let ratio: Double
    /// True iff |z| <= 1.0.
    public let inNormalRange: Bool

    public init(z: Double, delta: Double, ratio: Double, inNormalRange: Bool) {
        self.z = z; self.delta = delta; self.ratio = ratio
        self.inNormalRange = inNormalRange
    }
}

public enum Baselines {

    // MARK: - Constants (baselines.py)

    /// Winsorization clamp: fold only within +/- winsorK x spread.
    public static let winsorK: Double = 3.0
    /// Hard-reject gate: drop the night if more than this x spread away.
    public static let hardOutlierK: Double = 5.0
    /// Minimum valid nights before provisionally trusted.
    public static let minNightsSeed: Int = 4
    /// Minimum valid nights before fully trusted.
    public static let minNightsTrust: Int = 14
    /// Missing-night count after which a baseline is marked stale.
    public static let staleDays: Int = 14
    /// Days a nightly vital may be carried forward and still be presented as the latest reading. The
    /// carry stops one missed night blanking a tile; past this age the tile must show a dash, since a
    /// silent stale number reads as a current measurement. A week covers a weekend off-strap while staying
    /// short of `staleDays`, past which the judging baseline is itself stale.
    public static let vitalCarryDays: Int = 7

    /// The freshest `(day, value)` pair still fresh enough to present as latest, or nil when the newest
    /// is older than `vitalCarryDays` relative to `todayKey`. `yyyy-MM-dd` keys compare chronologically as
    /// strings, so no calendar math is involved; `points` need only be sorted oldest to newest. Shared by
    /// every latest-vital resolver so screens cannot disagree on staleness.
    public static func freshestCarried<T>(_ points: [(day: String, value: T)],
                                          todayKey: String,
                                          carryDays: Int = vitalCarryDays) -> (day: String, value: T)? {
        guard let newest = points.last else { return nil }
        return newest.day >= cutoffKey(todayKey: todayKey, carryDays: carryDays) ? newest : nil
    }

    /// The oldest `yyyy-MM-dd` a carried vital may bear: `todayKey - carryDays`. Parse, calendar and format
    /// all pin UTC, so it never shifts under a local zone or DST. An unparseable key yields `todayKey`
    /// (fail closed: never carry).
    public static func cutoffKey(todayKey: String, carryDays: Int = vitalCarryDays) -> String {
        guard let today = dayKeyFormatter.date(from: todayKey),
              let cutoff = utcCalendar.date(byAdding: .day, value: -carryDays, to: today)
        else { return todayKey }
        return dayKeyFormatter.string(from: cutoff)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Early-life anti-anchoring (Reddit HRV report)
    // Early-life anti-anchoring. The model seeds the centre on the first valid night with spread at the
    // floor. If the first nights read artificially high (a common cold-start artefact), the seed held the
    // mean high, the hard-outlier gate then rejected the user's genuine lower nights (>5x the floor
    // spread), and the tight spread made the z-score hypersensitive, crushing Charge to 1-2 for weeks.
    // While the baseline is young:
    // - skip hard-outlier rejection (nValid below the threshold or spread still at the floor);
    // - use a faster centre half-life so it tracks reality in days;
    // - widen the effective spread for Winsor clamping so an honest lower night is not clamped flat.
    // After `earlyAdaptNights`, behaviour is the normal long-term smoothing.

    /// Valid-night count below which the baseline is young: fast centre adaptation and no hard-outlier gate.
    public static let earlyAdaptNights: Int = 8
    /// Centre half-life (nights) while young; much faster than halfLifeB so a high seed is pulled to reality within days.
    public static let earlyHalfLifeB: Double = 3.0
    /// Spread multiplier for the Winsor clamp while young.
    public static let earlySpreadInflate: Double = 2.5

    /// UserDefaults key for the manual HRV-baseline recalibration epoch (epoch seconds). 0 or absent = none.
    /// Written by the Settings "Recalibrate HRV baseline" button.
    public static let hrvBaselineEpochKey: String = "zoop.hrvBaselineEpoch"

    /// UserDefaults key for the manual recovery-baseline recalibration epoch (epoch seconds); 0 or absent
    /// = none. Resting-HR / respiration / skin-temp baselines re-anchor on this epoch, HRV on its own
    /// `hrvBaselineEpochKey`; the Settings "Recalibrate Charge baseline" button writes both
    /// (`recalibrateRecoveryBaselines`).
    public static let recoveryBaselineEpochKey: String = "zoop.recoveryBaselineEpoch"

    /// Default per-metric configurations (HRV, resting HR, respiration, skin temp, daily Effort).
    /// "strain" backs the Activity-Balance / previous-day-Effort term; bounds match `StrainScorer.maxStrain`
    /// (0-100). Its floorSpread is wider than the physiological metrics because daily training load is
    /// expected to swing hard, and a tight floor would make the z-score hypersensitive to routine variation.
    public static let metricCfg: [String: MetricCfg] = [
        "hrv": MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0,
                         halfLifeB: 14.0, halfLifeS: 21.0),
        "resting_hr": MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0,
                                halfLifeB: 14.0, halfLifeS: 21.0),
        "resp": MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5,
                          halfLifeB: 14.0, halfLifeS: 21.0),
        "skin_temp": MetricCfg(minVal: 20.0, maxVal: 42.0, floorSpread: 0.3,
                               halfLifeB: 14.0, halfLifeS: 21.0),
        "strain": MetricCfg(minVal: 0.0, maxVal: 100.0, floorSpread: 5.0,
                            halfLifeB: 14.0, halfLifeS: 21.0),

        // Readiness HRV baseline, folded in the log domain with hard-outlier rejection off (window-fold
        // mode; see `update`'s `rejectHardOutliers`). ReadinessEngine z-scores lnRMSSD because HRV is
        // right-skewed, so bounds and floor are in ln(ms), unlike the raw-ms "hrv" config. minVal/maxVal =
        // ln(8)/ln(250). floorSpread 0.08 sits just below a real wearer's night-to-night ln-HRV spread (~0.10),
        // so personal spread drives the z while an ultra-stable baseline stays floored against saturation.
        "readiness_hrv_ln": MetricCfg(minVal: 2.079, maxVal: 5.521, floorSpread: 0.08,
                                      halfLifeB: 14.0, halfLifeS: 21.0),

        // Daytime/waking configs for DaytimeStress baseline-relative mode. Unlike the nightly "resting_hr"/
        // "hrv", these fold one daytime aggregate per day into a cross-day personal baseline, so each waking
        // hour can be z-scored against how this wearer's days usually run.
        // Validated (26-day Oura-reference correlation, HR-only, r~0.6): fold that day's 10th-percentile
        // daytime HR (~65 bpm pooled) for "daytime_hr", not the day-relative calmReference's 25th percentile.
        // The high-stress cutoff is a validated fixed bpm margin
        // (`DaytimeStress.baselineRelativeHighMarginBPM`), not this floorSpread.
        // Tuning seam: minVal/maxVal/half-life and all of "daytime_rmssd" (not part of the HR-only comparison)
        // are a first pass. The RMSSD floorSpread is wider than nightly "hrv" because daytime RMSSD carries
        // posture/talking/movement noise.
        "daytime_hr": MetricCfg(minVal: 35.0, maxVal: 160.0, floorSpread: 3.0,
                                halfLifeB: 14.0, halfLifeS: 21.0),
        "daytime_rmssd": MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 7.0,
                                   halfLifeB: 14.0, halfLifeS: 21.0),
    ]

    /// Convenience accessors for the standard configs.
    public static var hrvCfg: MetricCfg { metricCfg["hrv"]! }
    public static var restingHRCfg: MetricCfg { metricCfg["resting_hr"]! }
    public static var respCfg: MetricCfg { metricCfg["resp"]! }
    /// Readiness HRV config: log domain (ln ms), hard-outlier rejection off; see `readiness_hrv_ln`.
    public static var readinessHRVLnCfg: MetricCfg { metricCfg["readiness_hrv_ln"]! }
    /// Config for the Activity-Balance / previous-day-Effort term.
    public static var strainCfg: MetricCfg { metricCfg["strain"]! }
    /// Personal daytime HR baseline config; see `daytime_hr`.
    public static var daytimeHRCfg: MetricCfg { metricCfg["daytime_hr"]! }
    /// Personal daytime RMSSD baseline config; see `daytime_rmssd`.
    public static var daytimeRMSSDCfg: MetricCfg { metricCfg["daytime_rmssd"]! }

    /// Convert a half-life in nights to an EWMA smoothing factor.
    static func lambda(halfLife: Double) -> Double {
        1.0 - pow(0.5, 1.0 / halfLife)
    }

    static func computeStatus(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && nValid >= minNightsSeed { return .stale }
        if nValid < minNightsSeed { return .calibrating }
        if nValid < minNightsTrust { return .provisional }
        return .trusted
    }

    /// Calendar days since the newest night with a usable HRV reading (#612), or nil when none or a key
    /// cannot be parsed. Distinct from `calibrationNights` (progress toward a baseline): it measures
    /// staleness so a surface can say no new nights have arrived. `dayKeys`/`nightlyHrv` are parallel;
    /// `today` is an ISO `yyyy-MM-dd` key.
    ///
    /// Also: nights the app observed in the recent window and how many carried no usable HRV, for the
    /// common case of nights arriving but mostly empty (which otherwise reads as a stuck counter at "2 of
    /// 4"). Counts only days the app has a row for, so a new install is not charged for earlier nights.
    /// Pure and TZ-free (civil-day arithmetic).
    public static func recentHrvCoverage(dayKeys: [String], nightlyHrv: [Double?], today: String,
                                         window: Int = staleDays) -> (observed: Int, missing: Int) {
        guard let t = isoEpochDay(today) else { return (0, 0) }
        var observed = 0, missing = 0
        for i in 0..<Swift.min(dayKeys.count, nightlyHrv.count) {
            guard let d = isoEpochDay(dayKeys[i]), t - d >= 0, t - d < window else { continue }
            observed += 1
            if nightlyHrv[i] == nil { missing += 1 }
        }
        return (observed, missing)
    }

    public static func nightsSinceNewestValidNight(dayKeys: [String], nightlyHrv: [Double?], today: String) -> Int? {
        var newest: String? = nil
        for i in 0..<Swift.min(dayKeys.count, nightlyHrv.count) where nightlyHrv[i] != nil {
            let k = dayKeys[i]
            if newest == nil || k > newest! { newest = k }
        }
        guard let n = newest, let a = isoEpochDay(n), let b = isoEpochDay(today) else { return nil }
        let d = b - a
        return d >= 0 ? d : nil
    }

    /// Days from the civil epoch (proleptic Gregorian, Hinnant) for an ISO `yyyy-MM-dd`, or nil if unparseable. TZ-free.
    static func isoEpochDay(_ iso: String) -> Int? {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), m >= 1, m <= 12 else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: - Winsorized EWMA update (production model)

    /// Incorporate one nightly value into the baseline state.
    /// - `state == nil`: seed the first night.
    /// - `value == nil` or out of range: skip-and-hold.
    /// - hard outlier (> hardOutlierK x spread): seen, not folded.
    /// - otherwise: Winsorized EWMA centre plus EWMA-abs-dev spread update.
    public static func update(_ state: BaselineState?, value: Double?, cfg: MetricCfg,
                              rejectHardOutliers: Bool = true) -> BaselineState {
        let lb = lambda(halfLife: cfg.halfLifeB)
        let ls = lambda(halfLife: cfg.halfLifeS)

        // First night ever.
        guard let state = state else {
            if let v = value, cfg.minVal <= v && v <= cfg.maxVal {
                return BaselineState(baseline: v, spread: cfg.floorSpread, nValid: 1,
                                     nightsSinceUpdate: 0, status: .calibrating)
            }
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 1, status: .calibrating)
        }

        // Missing night: skip-and-hold.
        guard let value = value else {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Sanity gate: physiologically implausible values skip-and-hold.
        if !(cfg.minVal <= value && value <= cfg.maxVal) {
            let m = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: m,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: m))
        }

        // Young baselines adapt faster and suspend the hard-outlier gate so genuine lower nights are not
        // discarded. Tied to the valid-night count, not spread: a long flat history is settled even though its
        // spread never lifted off the floor, and must still reject a wild one-off.
        let isYoung = state.nValid < earlyAdaptNights

        // Hard-outlier rejection, once seeded and no longer young: seen, not folded. Suspending it in early
        // life is the anti-anchoring fix.
        // `rejectHardOutliers` (default true) can be turned off for a trailing-window re-fold, where a recent
        // sustained shift lands at the window's end past the young period and rejection would discard a real
        // new normal as a string of outliers (readiness's device-swap / supplement-onset case). Winsorization
        // still damps a single freak night, and a sustained shift is followed because each night nudges the
        // centre and widens the spread. Incremental fold (reject on, RecoveryScorer) vs window fold (off,
        // Readiness); see ReadinessEngine's RD2 note.
        if rejectHardOutliers && state.nValid >= minNightsSeed && !isYoung {
            let dev = abs(value - state.baseline)
            if dev > hardOutlierK * state.spread {
                return BaselineState(baseline: state.baseline, spread: state.spread,
                                     nValid: state.nValid, nightsSinceUpdate: 0,
                                     status: computeStatus(nValid: state.nValid, nightsSinceUpdate: 0))
            }
        }

        // First real value after a placeholder seed: treat as a clean first night.
        if state.nValid == 0 {
            return BaselineState(baseline: value, spread: cfg.floorSpread, nValid: 1,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }

        // Winsorized EWMA update. While young, inflate the clamp band so an honest lower night is not clamped
        // flat, and use the faster early half-life; both relax once settled.
        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effLb = isYoung ? lambda(halfLife: earlyHalfLifeB) : lb
        let lo = state.baseline - winsorK * effSpread
        let hi = state.baseline + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let newBaseline = effLb * clamped + (1.0 - effLb) * state.baseline

        // Spread uses the unclamped value so true deviations are tracked.
        let absDev = abs(value - newBaseline)
        let newSpread = max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread)
        let newN = state.nValid + 1

        return BaselineState(baseline: newBaseline, spread: newSpread, nValid: newN,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: newN, nightsSinceUpdate: 0))
    }

    /// Replay an ordered sequence of nightly values (oldest first) to build state; nil entries are missing nights (skip-and-hold).
    public static func foldHistory(_ values: [Double?], cfg: MetricCfg,
                                   rejectHardOutliers: Bool = true) -> BaselineState {
        var state: BaselineState? = nil
        for v in values { state = update(state, value: v, cfg: cfg, rejectHardOutliers: rejectHardOutliers) }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    /// The persisted manual-recalibration epoch (epoch seconds) for the HRV baseline; 0 = none.
    public static func hrvBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: hrvBaselineEpochKey)
    }

    /// The persisted manual-recalibration epoch (epoch seconds) for the wider recovery baseline (resting HR /
    /// respiration / skin temp); 0 = none. Pass it through the day-keyed
    /// `foldHistory(_:dayKeys:cfg:baselineEpoch:)` overload like the HRV path.
    public static func recoveryBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: recoveryBaselineEpochKey)
    }

    /// Recalibrate every baseline that feeds Charge: writes `now` (epoch seconds) to both the HRV and
    /// recovery epochs so the ~4-night build-up restarts from `now`. The single source of truth behind the
    /// Settings "Recalibrate Charge baseline" button. No stored day is deleted; only the day baselines
    /// re-learn from moves.
    /// - Parameters:
    ///   - now: the anchor instant (epoch seconds); defaults to the current time.
    ///   - defaults: the store to write to (overridable for tests).
    public static func recalibrateRecoveryBaselines(now: Double = Date().timeIntervalSince1970,
                                                    defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: hrvBaselineEpochKey)
        defaults.set(now, forKey: recoveryBaselineEpochKey)
    }

    /// Diagnostic companion to the epoch-aware `foldHistory` (#731): how many nights that fold drops
    /// because they predate the recalibration epoch, plus the epoch as a `yyyy-MM-dd` key (nil when none).
    /// Needed because a user who taps "Recalibrate baseline" repeatedly keeps resetting progress (15 valid
    /// nights on file but `nValid=3`) and nothing in the log said why. Mirrors the fold's drop rule exactly
    /// (same UTC day-start parse, strict `<`).
    ///
    /// Replay of the epoch-aware fold: `dayKeys` runs parallel to `values`; a night whose day starts before
    /// `baselineEpoch` (seconds; 0 = none) is dropped entirely, not skip-and-held, so the baseline re-seeds
    /// from the first on-or-after-epoch night. With `baselineEpoch <= 0` it equals `foldHistory(_:cfg:)`;
    /// nil reads `hrvBaselineEpoch()` from UserDefaults.
    public static func epochDropDiagnostic(dayKeys: [String],
                                           baselineEpoch: Double? = nil) -> (dropped: Int, epochDay: String?) {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return (0, nil) }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let dropped = dayKeys.reduce(into: 0) { acc, key in
            if let d = fmt.date(from: key), d.timeIntervalSince1970 < epoch { acc += 1 }
        }
        return (dropped, fmt.string(from: Date(timeIntervalSince1970: epoch)))
    }

    public static func foldHistory(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                   baselineEpoch: Double? = nil) -> BaselineState {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return foldHistory(values, cfg: cfg) }

        // Day-start epoch (UTC) per "yyyy-MM-dd" key, built once.
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        var state: BaselineState? = nil
        for (i, v) in values.enumerated() {
            // Drop (not skip-and-hold) any night dated before the recalibration epoch.
            if i < dayKeys.count, let d = fmt.date(from: dayKeys[i]),
               d.timeIntervalSince1970 < epoch {
                continue
            }
            state = update(state, value: v, cfg: cfg)
        }
        if let s = state { return s }
        let seed = (cfg.minVal + cfg.maxVal) / 2.0
        return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                             nightsSinceUpdate: 0, status: .calibrating)
    }

    // MARK: - Device-era boundary (#459)

    /// The recalibration epoch (UTC start-of-day seconds) at the latest device-era boundary in a
    /// source-tagged nightly history, for `foldHistory`'s `baselineEpoch`, so a baseline cannot mix two
    /// brands' incompatible HRV scales (#459: Oura RMSSD ~120-155 ms vs WHOOP ~72-112 ms, so a straddling
    /// window reads the first WHOOP nights as suppressed, a device artifact).
    ///
    /// Contract: `sourceDays` is exactly one `(dayKey, sourceId)` per night, the day's winning source (the
    /// per-day merge winner whose value the fold uses), not one row per source. The current era is read
    /// from the newest day's brand, so an overlap day carrying two brands could let a lexically-later
    /// source masquerade as current. Any order is fine (it is sorted here).
    ///
    /// The epoch is the start of the first day of the latest contiguous single-brand era: walk newest to
    /// oldest while the brand matches. A lone off-brand day inside the era truncates it (fail-safe: drops
    /// more history, never mixes scales). Returns 0.0 (no recalibration) for a single-brand history.
    ///
    /// The brand bucket is coarse and not `DeviceFamily` (4 vs 5 share an HRV scale): every WHOOP-origin id
    /// (import, active strap, "-zoop" computed sibling, Health-Connect/Apple rows on the strap source) is
    /// one brand; each wearable-export brand (oura/fitbit/garmin) is its own. The caller assembles
    /// `sourceDays` from the original per-source reads, since brand is lost after merge.
    public static func deviceEraEpoch(_ sourceDays: [(day: String, sourceId: String)]) -> Double {
        if sourceDays.isEmpty { return 0.0 }
        // Total order by (day, sourceId): a same-day mixed-brand row must break ties deterministically (Swift's sort is not stable).
        let sorted = sourceDays.sorted { $0.day != $1.day ? $0.day < $1.day : $0.sourceId < $1.sourceId }
        let currentBrand = brandBucket(sorted.last!.sourceId)
        // No brand change anywhere means no epoch.
        if !sorted.contains(where: { brandBucket($0.sourceId) != currentBrand }) { return 0.0 }
        // Walk back over the contiguous current-brand suffix; its first day opens the current era.
        var eraStartDay = sorted.last!.day
        for entry in sorted.reversed() {
            if brandBucket(entry.sourceId) != currentBrand { break }
            eraStartDay = entry.day
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: eraStartDay)?.timeIntervalSince1970 ?? 0.0
    }

    /// Coarse HRV-scale brand for a source id (#459). Every WHOOP-origin id shares one scale; each
    /// wearable-export brand is its own. Unknown ids bucket to "whoop", so only a positively identified
    /// wearable export changes the era.
    static func brandBucket(_ sourceId: String) -> String {
        // `hasPrefix` catches both the export id ("oura-import") and the cloud id ("oura-api") as one brand.
        if sourceId.hasPrefix("oura") { return "oura" }
        if sourceId.hasPrefix("fitbit") { return "fitbit" }
        if sourceId.hasPrefix("garmin") { return "garmin" }
        // "apple-health" / "health-connect" fall through to "whoop" on purpose: their daily rows ride the strap
        // source's scale and HC's true origin is unknowable, so they must not open a false era boundary.
        return "whoop"
    }

    // MARK: - Deviation

    /// Approximate Gaussian sigma from the EWMA-abs-dev spread: 1.253 x spread (inverting
    /// E[|X-mu|] = sigma*sqrt(2/pi)), floored so callers never divide by ~0. Shared by `deviation()` and
    /// other z-scoring callers (e.g. DaytimeStress) so the conversion has one definition.
    public static func sigma(_ state: BaselineState) -> Double {
        max(1.253 * state.spread, 1e-9)
    }

    /// z / delta / ratio / in-normal-range for a value vs a baseline; z = (value - baseline) / sigma(state).
    public static func deviation(_ value: Double, state: BaselineState) -> Deviation {
        let sig = sigma(state)
        let z = (value - state.baseline) / sig
        let delta = value - state.baseline
        let ratio = state.baseline != 0 ? (value / state.baseline - 1.0) : 0.0
        return Deviation(z: z, delta: delta, ratio: ratio, inNormalRange: abs(z) <= 1.0)
    }

    // MARK: - Trailing-window mean/SD (simple, auditable)

    /// Rolling personal baseline from the trailing `window` valid nights as a plain mean and sample SD
    /// (ddof=1), without recency weighting. Implausible values (outside cfg bounds) and nils are dropped.
    /// The returned spread is stored in the Winsor EWMA's abs-dev units (SD / 1.253) so `deviation()`
    /// recovers the intended sigma.
    /// - Parameters:
    ///   - values: nightly values, oldest to newest; nils allowed.
    ///   - cfg: metric config (bounds + floor spread).
    ///   - window: trailing valid nights to use (default 30).
    public static func rollingMeanSD(_ values: [Double?], cfg: MetricCfg, window: Int = 30) -> BaselineState {
        let valid = values.compactMap { v -> Double? in
            guard let v = v, cfg.minVal <= v && v <= cfg.maxVal else { return nil }
            return v
        }
        guard !valid.isEmpty else {
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }
        let trailing = valid.suffix(window)
        let n = trailing.count
        let mean = trailing.reduce(0, +) / Double(n)

        let sd: Double
        if n >= 2 {
            var ss = 0.0
            for v in trailing { let d = v - mean; ss += d * d }
            sd = (ss / Double(n - 1)).squareRoot()
        } else {
            // Single sample: no dispersion estimate; fall back to the sigma floor.
            sd = cfg.floorSpread * 1.253
        }

        // Apply the sigma floor in sigma-space, then convert to abs-dev space.
        let sigmaFloored = max(cfg.floorSpread, sd)
        let spreadInternal = sigmaFloored / 1.253

        return BaselineState(baseline: mean, spread: spreadInternal, nValid: n,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: n, nightsSinceUpdate: 0))
    }
}
