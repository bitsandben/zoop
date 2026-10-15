import Foundation
import WhoopStore

// Which nights the Charge baselines (HRV, resting HR, respiration, skin temp) are folded from (#2525).
// Previously they folded the whole imported vendor history plus only the current scan window's own
// nights, so the import never aged out and kept about a third of the weight for good. Rules:
// - Only nights inside a fixed calendar window (`windowDays`, back from the anchor day) count, so an
//   imported night ages out like an own one.
// - The wearer's own (Zoop-computed) nights are the baseline. Imported nights only seed it: they take
//   part while own nights alone would not yet make a trusted baseline (`handoffNights`, the model's
//   `minNightsTrust`) and drop out once they would. The two sources use different algorithms and are
//   never mixed past the cold start.
// - No state: every call decides from the nights it is given.
// Pure and database-free; the engine feeds fresh values, the dashboard the stored rows.
public enum ChargeBaselines {

    /// Calendar days of nightly history a Charge baseline reads, back from and including the anchor day.
    /// The default scan window (`analyzeRecent(maxDays: 21)`), so own nights read are the ones just scored.
    public static let windowDays: Int = 21

    /// One metric's nightly history for a Charge baseline, oldest first, ready for
    /// `Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`, plus the counts the diagnostic line reports.
    public struct History: Equatable, Sendable {
        /// `yyyy-MM-dd` keys, ascending, parallel to `values`.
        public let dayKeys: [String]
        /// Nightly values; nil is a night that exists without a value (skip-and-hold).
        public let values: [Double?]
        /// True while imported nights still take part (own nights not yet trusted and the window has an imported night).
        public let seededByImport: Bool
        /// Valid own nights on or after the epoch inside the window: the count the handoff is decided on.
        public let ownValidNights: Int
        /// Imported nights carried (0 once own nights take over).
        public let importedNights: Int

        public init(dayKeys: [String], values: [Double?], seededByImport: Bool,
                    ownValidNights: Int, importedNights: Int) {
            self.dayKeys = dayKeys
            self.values = values
            self.seededByImport = seededByImport
            self.ownValidNights = ownValidNights
            self.importedNights = importedNights
        }
    }

    /// Build one metric's Charge history from imported and own nights (#2525).
    /// - Parameters:
    ///   - imported: imported vendor nights as `(day, value)`; nil value = night covered without that
    ///     metric. A repeated day keeps its last value.
    ///   - own: Zoop-computed nights, same shape.
    ///   - anchorDay: the `yyyy-MM-dd` day the window ends on (the scoring pass's local today).
    ///   - cfg: the metric's baseline config, to count valid own nights as the fold will.
    ///   - baselineEpoch: epoch (seconds) the fold drops earlier nights by (manual recalibration or a later
    ///     device-era cut); own nights before it do not count toward the handoff.
    ///   - windowDays: see `windowDays`.
    ///   - handoffNights: valid own nights at which imported nights stop taking part.
    /// Days are filtered with civil-day arithmetic (no time zone), keeping those on or before the anchor
    /// and fewer than `windowDays` before it. An unparseable key is dropped; an unparseable anchor yields an
    /// empty history, so a baseline can only be under-stated. While seeding, an imported value wins a day
    /// both cover; an own night fills a day the import leaves open or covers without a value (so a blank
    /// imported row cannot shadow a measured night).
    public static func history(imported: [(day: String, value: Double?)],
                               own: [(day: String, value: Double?)],
                               anchorDay: String,
                               cfg: MetricCfg,
                               baselineEpoch: Double,
                               windowDays: Int = ChargeBaselines.windowDays,
                               handoffNights: Int = Baselines.minNightsTrust) -> History {
        let empty = History(dayKeys: [], values: [], seededByImport: false, ownValidNights: 0, importedNights: 0)
        guard windowDays > 0, let anchor = Baselines.isoEpochDay(anchorDay) else { return empty }
        let inWindow: (String) -> Bool = { day in
            guard let d = Baselines.isoEpochDay(day) else { return false }
            return d <= anchor && anchor - d < windowDays
        }

        var ownByDay: [String: Double?] = [:]
        for night in own where inWindow(night.day) { ownByDay[night.day] = night.value }
        let ownKeys = ownByDay.keys.sorted()
        let ownValues = ownKeys.map { ownByDay[$0]! }
        let ownValid = Baselines.foldHistory(ownValues, dayKeys: ownKeys, cfg: cfg,
                                             baselineEpoch: baselineEpoch).nValid

        var importedByDay: [String: Double?] = [:]
        for night in imported where inWindow(night.day) { importedByDay[night.day] = night.value }

        // Handed off, or nothing to seed with: own nights are the whole history.
        if ownValid >= handoffNights || importedByDay.isEmpty {
            return History(dayKeys: ownKeys, values: ownValues, seededByImport: false,
                           ownValidNights: ownValid, importedNights: 0)
        }

        // Seeding: every imported night in the window, then own nights on open days. `merged[day]` is
        // `.some(nil)` for an imported night without a value, which is open too. An own night without a value
        // still registers the day (a missing night).
        var merged = importedByDay
        for (day, value) in ownByDay {
            if let existing = merged[day], existing != nil { continue }   // an imported value wins
            merged[day] = value
        }
        let keys = merged.keys.sorted()
        return History(dayKeys: keys, values: keys.map { merged[$0]! }, seededByImport: true,
                       ownValidNights: ownValid, importedNights: importedByDay.count)
    }

    /// The Charge baselines the dashboard reads, resolved from stored daily rows with the same rule as the
    /// engine's pass-2 fold (#2525), so the "What shaped it" rows, calibration count and confidence tier
    /// describe the baseline the headline was scored against.
    public struct Resolved: Equatable, Sendable {
        public let hrvHistory: History
        public let restingHRHistory: History
        public let respHistory: History
        public let hrv: BaselineState
        public let restingHR: BaselineState
        public let resp: BaselineState

        public init(hrvHistory: History, restingHRHistory: History, respHistory: History,
                    hrv: BaselineState, restingHR: BaselineState, resp: BaselineState) {
            self.hrvHistory = hrvHistory
            self.restingHRHistory = restingHRHistory
            self.respHistory = respHistory
            self.hrv = hrv
            self.restingHR = restingHR
            self.resp = resp
        }
    }

    /// Resolve HRV, resting-HR and respiration baselines from stored rows (`imported` vendor rows, `own`
    /// Zoop-computed "-zoop" rows). HRV folds on `hrvEpoch`, the others on `recoveryEpoch`, as the engine
    /// does. The engine also cuts respiration at a device-era boundary (#459), which needs a per-night
    /// source the stored rows lack; the two agree for single-brand histories.
    public static func resolve(imported: [DailyMetric], own: [DailyMetric], anchorDay: String,
                               hrvEpoch: Double, recoveryEpoch: Double) -> Resolved {
        let hrvCfg = Baselines.hrvCfg, rhrCfg = Baselines.restingHRCfg, respCfg = Baselines.respCfg
        let hrvHistory = history(imported: imported.map { (day: $0.day, value: $0.avgHrv) },
                                 own: own.map { (day: $0.day, value: $0.avgHrv) },
                                 anchorDay: anchorDay, cfg: hrvCfg, baselineEpoch: hrvEpoch)
        let rhrHistory = history(imported: imported.map { (day: $0.day, value: $0.restingHr.map(Double.init)) },
                                 own: own.map { (day: $0.day, value: $0.restingHr.map(Double.init)) },
                                 anchorDay: anchorDay, cfg: rhrCfg, baselineEpoch: recoveryEpoch)
        let respHistory = history(imported: imported.map { (day: $0.day, value: $0.respRateBpm) },
                                  own: own.map { (day: $0.day, value: $0.respRateBpm) },
                                  anchorDay: anchorDay, cfg: respCfg, baselineEpoch: recoveryEpoch)
        return Resolved(
            hrvHistory: hrvHistory, restingHRHistory: rhrHistory, respHistory: respHistory,
            hrv: Baselines.foldHistory(hrvHistory.values, dayKeys: hrvHistory.dayKeys, cfg: hrvCfg,
                                       baselineEpoch: hrvEpoch),
            restingHR: Baselines.foldHistory(rhrHistory.values, dayKeys: rhrHistory.dayKeys, cfg: rhrCfg,
                                             baselineEpoch: recoveryEpoch),
            resp: Baselines.foldHistory(respHistory.values, dayKeys: respHistory.dayKeys, cfg: respCfg,
                                        baselineEpoch: recoveryEpoch))
    }

    /// The Recovery test-mode line naming what each Charge baseline was folded from. Per metric `own/N` is
    /// own nights alone (N valid); `seed/N+M` is N valid own nights still seeded by M imported. It reports
    /// the composition the engine decided, not why values moved.
    public static func logLine(anchorDay: String, hrv: History, restingHR: History, resp: History,
                               skin: History, windowDays: Int = ChargeBaselines.windowDays) -> String {
        let part: (History) -> String = { h in
            h.seededByImport ? "seed/\(h.ownValidNights)+\(h.importedNights)" : "own/\(h.ownValidNights)"
        }
        return "charge baseline anchor=\(anchorDay) window=\(windowDays)d hrv=\(part(hrv)) " +
            "rhr=\(part(restingHR)) resp=\(part(resp)) skin=\(part(skin))"
    }
}
