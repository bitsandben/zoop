import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Outcome of a one-time implausible-timestamp heal. `rawRowsDeleted` counts garbage raw stream rows
    /// purged; `computedRowsDeleted` counts future or implausible computed daily-metric and sleep-session
    /// rows. `didChange` lets the caller trigger a single rescore instead of always re-running it.
    public struct TimestampHealResult: Equatable, Sendable {
        public let rawRowsDeleted: Int
        public let computedRowsDeleted: Int
        public var didChange: Bool { rawRowsDeleted > 0 || computedRowsDeleted > 0 }
        public init(rawRowsDeleted: Int, computedRowsDeleted: Int) {
            self.rawRowsDeleted = rawRowsDeleted
            self.computedRowsDeleted = computedRowsDeleted
        }
    }

    /// One-time repair of a database polluted by a bad-clock strap. Before the ingest gate, each type-47
    /// record's own timestamp was trusted verbatim, so a broken-clock WHOOP wrote rows dated to scattered
    /// far-past and future garbage; overlapping day-windows then re-attributed one polluted block to every
    /// day.
    ///
    /// Purges (a) raw stream rows whose `ts` is implausible (< MIN_PLAUSIBLE_UNIX or > now + FUTURE_MARGIN)
    /// across every time-keyed raw table, and (b) computed `dailyMetric` rows with a future or implausibly
    /// old `day` and `sleepSession` rows with a future or implausible `startTs`. The caller then runs
    /// `analyzeRecent` to recompute the real days. Idempotent.
    ///
    /// `now` and `todayLocalDayKey` are injectable for tests. Bounds come from WhoopProtocol so Swift and
    /// the Android Room cleanup reject the identical set.
    @discardableResult
    public func healImplausibleTimestamps(
        now: Int = Int(Date().timeIntervalSince1970),
        todayLocalDayKey: String = WhoopStore.localDayKey(Date())
    ) async throws -> TimestampHealResult {
        let lo = MIN_PLAUSIBLE_UNIX
        let hi = now + FUTURE_MARGIN
        return try syncWrite { db in
            // (a) Raw ts-keyed streams, all fed by the historical type-47 / EVENT / REALTIME paths the ingest gate
            // guards, so the same out-of-bounds predicate cleans them. The list is shared with the storage
            // footprint (`rawTableKeys`) so a stream added later is healed, counted and named together, never
            // one without the others. A plausible row is never touched.
            var rawDeleted = 0
            for (_, table) in WhoopStore.rawTableKeys {
                try db.execute(sql: "DELETE FROM \(table) WHERE ts < ? OR ts > ?",
                               arguments: [lo, hi])
                rawDeleted += db.changesCount
            }

            // (b) Computed rows. dailyMetric is keyed by a yyyy-MM-dd `day`, sleepSession by integer `startTs`. A
            // future-dated row is always implausible, so it goes regardless of source. The far-past floor applies
            // only to computed (`-noop`) rows: a WHOOP CSV import (bare "my-whoop") carries real dates back years,
            // and applying the floor to it purged imported history. String comparison is correct for zero-padded yyyy-MM-dd.
            let floorDayKey = WhoopStore.utcDayKey(MIN_PLAUSIBLE_UNIX)
            var computedDeleted = 0
            try db.execute(sql: "DELETE FROM dailyMetric WHERE day > ? OR (day < ? AND deviceId LIKE '%-noop')",
                           arguments: [todayLocalDayKey, floorDayKey])
            computedDeleted += db.changesCount
            try db.execute(sql: "DELETE FROM sleepSession WHERE startTs > ? OR (startTs < ? AND deviceId LIKE '%-noop')",
                           arguments: [hi, lo])
            computedDeleted += db.changesCount

            return TimestampHealResult(rawRowsDeleted: rawDeleted,
                                       computedRowsDeleted: computedDeleted)
        }
    }

    /// `yyyy-MM-dd` for `date` in the local calendar, matching how dailyMetric `day` keys are written.
    public static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `yyyy-MM-dd` for a unix second in UTC, a zone-independent sentinel for the far-past floor day.
    public static func utcDayKey(_ unix: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
