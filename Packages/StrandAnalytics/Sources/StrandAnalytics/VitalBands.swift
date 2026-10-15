import Foundation

/// Personal-baseline banding for the Health Monitor's vital tiles. In-range is judged against the user's OWN
/// trailing baseline (Winsorized EWMA from `Baselines`) once trusted (`Baselines.minNightsTrust` valid nights,
/// not stale); until then, and whenever a wear gap makes it stale, the fixed population range is the fallback.
///
/// `MetricCfg`'s physiological bounds stay an absolute outer guard but are NOT the in-range band (a normal
/// personal HRV of 35 ms would read permanently out-of-range against the 40-120 population band); they
/// only catch implausible values. APPROXIMATE, informational, not a diagnosis.
public enum VitalBands {

    public enum Band: String, Equatable, Sendable { case inRange, outOfRange, noData }

    /// How the band was judged; drives the tile's caption wording.
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

    /// |z| at or below this is in-range vs the personal baseline (about 95% of the user's normal nights);
    /// `Baselines.deviation`'s |z| <= 1 would flag a third of normal nights, too noisy for a passive tile.
    public static let sigmaK: Double = 2.0

    /// Bands a single vital `value`.
    ///
    /// - Parameters:
    ///   - value: today's value, or nil for no data.
    ///   - history: nightly values oldest to newest EXCLUDING the displayed day; nil is a missing night
    ///     (pad real wear gaps with `calendarSeries` first so staleness sees them).
    ///   - populationRange: the fixed typical-adult cold-start / stale fallback.
    ///   - cfg: nil disables the personal path (SpO2 stays population-only; an absolute floor is meaningful).
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
        // Outer plausibility guard: outside the physiological bounds is out-of-range however wide the personal spread.
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

    // MARK: - Skin temp (mixed semantics: absolute C from CSV import vs +/-C on-device deviation)

    /// A skin-temp value >= 20 C is ABSOLUTE; smaller magnitudes are a +/-C deviation. WHOOP CSV exports
    /// store absolute C while Zoop's on-device pipeline stores a deviation from the personal baseline, so a
    /// merged series is bimodal. No real wrist skin temp is below 20 C and no nightly deviation reaches 20 C.
    public static func isAbsoluteSkinTemp(_ v: Double) -> Bool { v >= 20.0 }

    /// Keeps only history entries of the SAME kind (absolute vs deviation) as `value`; others become nil so
    /// the folded baseline does not span two scales.
    public static func skinTempHistory(matching value: Double, in history: [Double?]) -> [Double?] {
        let absolute = isAbsoluteSkinTemp(value)
        return history.map { v in
            guard let v else { return nil }
            return isAbsoluteSkinTemp(v) == absolute ? v : nil
        }
    }

    /// Deviation-semantics config for on-device skin-temp rows: +/-C around the personal mean, guarded to
    /// +/-8 C. (The `skin_temp` config in `Baselines` is the absolute one for CSV rows.)
    public static let skinTempDeviationCfg = MetricCfg(
        minVal: -8.0, maxVal: 8.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0)

    // MARK: - Skin temp banding (own median, real-deviation gate)

    /// Valid same-kind nights needed before skin temp can read out of range; below this the tile never warns.
    public static let skinTempMinNights = 7
    /// Trailing calendar entries (gaps included) the personal median looks back over.
    public static let skinTempLookbackNights = 60
    /// Smallest distance from the personal median (C) that can read out of range, so a steady wrist does not flag a 0.3 C wobble.
    public static let skinTempMinDeltaC = 0.8
    /// Floor on the robust spread (C), so a near-constant history does not shrink the band to nothing.
    public static let skinTempSigmaFloorC = 0.3

    /// Bands a nightly skin temperature against the wearer's OWN recent median, not the population path:
    /// the strap's absolute reading is not population-comparable (a 4.0 is the worn ADC anchored to 33.0 C,
    /// a 5.0/MG wrist sits at 31-33 C), so a steady temperature read "Outside range" nightly. Fewer than
    /// `skinTempMinNights` matching nights is in range; otherwise out of range only when
    /// |value - median| >= max(`skinTempMinDeltaC`, `sigmaK` * sigma), sigma = max(`skinTempSigmaFloorC`,
    /// 1.4826 * MAD). Values outside the plausible bounds are still out of range.
    ///
    /// - Parameter history: nightly values oldest to newest EXCLUDING the displayed night, calendar-padded
    ///   with nil; mixed absolute/deviation entries are filtered to the value's kind.
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

    /// Illness-ward z for skin temp from recent nightly DEVIATIONS (C), or nil when none. Imported absolute
    /// nights are skipped (~33 C over a 0.3 C spread fired on every one). The smaller of recent mean and
    /// latest night is used, so one warm night alone does not fire.
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

    /// Calendar-aligns (day, value) rows keyed "yyyy-MM-dd" into a nightly series with nil for absent days,
    /// so baseline staleness sees wear gaps (else a user returning after two months is judged against an
    /// ancient "trusted" baseline). Malformed keys are dropped. Fixed UTC math, no device clock.
    public static func calendarSeries(_ rows: [(day: String, value: Double?)]) -> [Double?] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = rows.compactMap { f.date(from: $0.day) }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        // Last write wins for a duplicated day key.
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
