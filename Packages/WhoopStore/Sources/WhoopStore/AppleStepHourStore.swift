import Foundation
import GRDB

// MARK: - v38 store: hourly Apple Health step counts
// Idempotent upsert keyed by (deviceId, ts). `appleDaily.steps` gives the day total; this table records
// which HOURS had data, so the UI can show when the iPhone was off or left behind.

extension WhoopStore {

    /// Upserts hourly step counts, idempotent by (deviceId, ts). Returns rows changed.
    @discardableResult
    public func upsertAppleStepHours(_ rows: [(ts: Int, steps: Int)], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO appleStepHour (deviceId, ts, steps)
                    VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET
                        steps = excluded.steps
                    """, arguments: [deviceId, r.ts, r.steps])
                n += db.changesCount
            }
            return n
        }
    }

    /// Hourly step counts for a device over `[fromTs, toTs]` inclusive, oldest hour first.
    public func appleStepHours(deviceId: String, fromTs: Int, toTs: Int) async throws -> [(ts: Int, steps: Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, steps FROM appleStepHour
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC
                """, arguments: [deviceId, fromTs, toTs])
                .map { (ts: $0["ts"], steps: $0["steps"]) }
        }
    }
}
