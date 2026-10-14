import Foundation

/// Personal-baseline banding for the Health Monitor's vital tiles.
///
/// In-range is judged against the user's OWN trailing baseline (the Winsorized EWMA
/// the rest of `Baselines` builds) once that baseline is trusted — `Baselines.minNightsTrust`
/// (14) valid nights and not stale. Until then, and again whenever a wear gap makes the
/// baseline stale, the fixed population range is the fallback.
///
/// `MetricCfg`'s physiological bounds stay an absolute outer guard either way. They are
/// deliberately NOT used as the in-range band: doing so would resurrect the exact false
/// positive this fixes — a perfectly normal personal HRV of 35 ms reading permanently
/// out-of-range against the 40–120 population band. The bounds only catch values that are
/// implausible for any human (e.g. an HRV of 300 ms), which no personal spread should excuse.
///
/// APPROXIMATE — informational, not a diagnosis.
public enum VitalBands {

    public enum Band: String, Equatable, Sendable { case inRange, outOfRange, noData }

    /// How the band was judged — drives the tile's caption wording.
    public enum Basis: String, Equatable, Sendable { case personal, population }

    public struct Result: Equatable, Sendable {
        public let band: Band
        public let basis: Basis
        /// Valid nights backing the personal baseline (0 when none).
        public let nights: Int
        public init(band: Band, basis: Basis, nights: Int) {
            self.band = band
            self.basis = basis
            self.nights = nights
        }
    }

    /// |z| at or below this is in-range vs the personal baseline — about 95% of the user's
    /// own normal nights. `Baselines.deviation`'s own `inNormalRange` (|z| <= 1) would flag
    /// roughly a third of normal nights, which is far too noisy for a passive at-a-glance tile.
    public static let sigmaK: Double = 2.0

    /// Band a single vital `value`.
    ///
    /// - Parameters:
    ///   - value: today's value, or nil for no data.
    ///   - history: nightly values oldest→newest EXCLUDING the displayed day. A nil entry is
    ///     a missing night; use `calendarSeries` first to pad real wear gaps so staleness sees them.
    ///   - populationRange: the fixed typical-adult range used as the cold-start / stale fallback.
    ///   - cfg: nil disables the personal path entirely (SpO2 stays population-only — there is
    ///     no SpO2 `MetricCfg` and an absolute floor is meaningful regardless of personal history).
    public static func band(value: Double?,
                            history: [Double?],
                            populationRange: ClosedRange<Double>,
                            cfg: MetricCfg?) -> Result {
        guard let value else { return Result(band: .noData, basis: .population, nights: 0) }
        guard let cfg else {
            return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                          basis: .population, nights: 0)
        }
        let state = Baselines.foldHistory(history, cfg: cfg)
        // Absolute-plausibility outer guard: a value outside the physiological bounds is
        // out-of-range no matter how wide the personal spread happens to be.
        guard cfg.minVal <= value && value <= cfg.maxVal else {
            return Result(band: .outOfRange, basis: .population, nights: state.nValid)
        }
        if state.trusted {   // >= 14 valid nights and not stale
            let z = Baselines.deviation(value, state: state).z
            return Result(band: abs(z) <= sigmaK ? .inRange : .outOfRange,
                          basis: .personal, nights: state.nValid)
        }
        return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                      basis: .population, nights: state.nValid)
    }

    // MARK: - Skin temp (mixed semantics: absolute °C from CSV import vs ±°C on-device deviation)

    /// A skin-temp value >= 20 °C is read as an ABSOLUTE skin temperature; smaller magnitudes
    /// are read as a ±°C deviation. The WHOOP CSV export stores absolute °C in its skin-temp
    /// column while Zoop's on-device pipeline stores a deviation from the personal baseline, so
    /// a merged series is bimodal. The displayed value picks which kind its history keeps.
    /// Heuristic but physically safe: no real wrist skin temp is below 20 °C, and no real
    /// nightly deviation reaches ±20 °C.
    public static func isAbsoluteSkinTemp(_ v: Double) -> Bool { v >= 20.0 }

    /// Keep only history entries of the SAME kind (absolute vs deviation) as the displayed
    /// `value`; entries of the other kind become nil (missing nights) so the baseline that
    /// `band` folds isn't computed across two incompatible scales.
    public static func skinTempHistory(matching value: Double, in history: [Double?]) -> [Double?] {
        let absolute = isAbsoluteSkinTemp(value)
        return history.map { v in
            guard let v else { return nil }
            return isAbsoluteSkinTemp(v) == absolute ? v : nil
        }
    }

    /// Deviation-semantics config for on-device skin-temp rows: ±°C around the personal mean,
    /// guarded to a physically sane ±8 °C. (The standard `skin_temp` config in `Baselines`
    /// is the ABSOLUTE-°C one, used for CSV-imported rows.)
    public static let skinTempDeviationCfg = MetricCfg(
        minVal: -8.0, maxVal: 8.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0)

    // MARK: - Skin temp banding (own median, real-deviation gate)

    /// Valid nights of the SAME kind (absolute vs deviation) needed before skin temp can read out of
    /// range. Below this the tile never warns.
    public static let skinTempMinNights = 7
    /// Trailing calendar entries (nights, gaps included) the personal median looks back over, so a
    /// baseline from months ago never judges tonight.
    public static let skinTempLookbackNights = 60
    /// Smallest distance from the personal median (°C) that can read out of range, however steady the
    /// history is. A rock-steady wrist would otherwise flag a 0.3 °C wobble.
    public static let skinTempMinDeltaC = 0.8
    /// Floor on the robust spread (°C), so a near-constant history doesn't shrink the band to nothing.
    public static let skinTempSigmaFloorC = 0.3

    /// Band a nightly skin temperature against the wearer's OWN recent median.
    ///
    /// Skin temp does not use `band(value:history:populationRange:cfg:)`. That path fell back to a fixed
    /// 33–36 °C population range until 14 trusted nights existed, and the strap's absolute reading is not
    /// a population-comparable number: a WHOOP 4.0 absolute is the device's worn ADC anchored to 33.0 °C,
    /// and a 5.0/MG wrist commonly sits at 31–33 °C. A perfectly steady temperature therefore read
    /// "Outside range" night after night. Here:
    /// - fewer than `skinTempMinNights` matching nights in the lookback → in range (no warning);
    /// - otherwise out of range only when |value − median| ≥ max(`skinTempMinDeltaC`, `sigmaK` · σ),
    ///   with σ = max(`skinTempSigmaFloorC`, 1.4826 · MAD) over the trailing matching nights.
    /// Values outside the physically plausible bounds are still out of range.
    ///
    /// - Parameter history: nightly values oldest→newest EXCLUDING the displayed night, calendar-padded
    ///   with nil for unworn nights; mixed absolute/deviation entries are filtered to the value's kind.
    public static func skinTempBand(value: Double?, history: [Double?]) -> Result {
        guard let value else { return Result(band: .noData, basis: .population, nights: 0) }
        let absolute = isAbsoluteSkinTemp(value)
        let cfg = absolute ? Baselines.metricCfg["skin_temp"]! : skinTempDeviationCfg
        let nights = skinTempHistory(matching: value, in: Array(history.suffix(skinTempLookbackNights)))
            .compactMap { $0 }
            .filter { cfg.minVal <= $0 && $0 <= cfg.maxVal }
        guard cfg.minVal <= value && value <= cfg.maxVal else {
            return Result(band: .outOfRange, basis: .population, nights: nights.count)
        }
        guard nights.count >= skinTempMinNights else {
            return Result(band: .inRange, basis: .population, nights: nights.count)
        }
        let center = median(nights)
        let mad = median(nights.map { abs($0 - center) })
        let sigma = max(skinTempSigmaFloorC, 1.4826 * mad)
        let threshold = max(skinTempMinDeltaC, sigmaK * sigma)
        return Result(band: abs(value - center) >= threshold ? .outOfRange : .inRange,
                      basis: .personal, nights: nights.count)
    }

    /// Illness-ward z for the skin-temp signal from recent nightly DEVIATIONS (°C), or nil when there is
    /// no deviation to read. Imported nights store an ABSOLUTE °C in the same column; those are skipped,
    /// since dividing ~33 °C by a 0.3 °C spread raised the skin signal on every imported night. The
    /// smaller of the recent mean and the latest night is used, so one warm night alone does not fire.
    public static func skinTempIllnessZ(recent: [Double?], latest: Double?) -> Double? {
        guard let latest, !isAbsoluteSkinTemp(latest) else { return nil }
        let devs = recent.compactMap { $0 }.filter { !isAbsoluteSkinTemp($0) }
        guard !devs.isEmpty else { return nil }
        let mean = devs.reduce(0, +) / Double(devs.count)
        return min(mean, latest) / skinTempDeviationCfg.floorSpread
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    // MARK: - Calendar padding

    /// Calendar-align (day, value) rows keyed "yyyy-MM-dd" into a nightly series with nil for
    /// every absent day, so the baseline's staleness logic actually sees wear gaps. Stored rows
    /// simply skip days the strap wasn't worn; without padding, a user returning after two months
    /// would be banded against an ancient still-"trusted" baseline. Malformed day keys are dropped.
    /// Pure: fixed UTC math over the day keys only (no device clock).
    public static func calendarSeries(_ rows: [(day: String, value: Double?)]) -> [Double?] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = rows.compactMap { f.date(from: $0.day) }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        // Last write wins for a duplicated day key, matching the dictionary the Kotlin port builds.
        var byDay: [String: Double?] = [:]
        for r in rows where f.date(from: r.day) != nil { byDay[r.day] = r.value }
        var out: [Double?] = []
        var d = first
        while d <= last {
            out.append(byDay[f.string(from: d)] ?? nil)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
