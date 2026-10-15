import Foundation
import GRDB

// MARK: - v22 store: Live Sessions
// GRDB CRUD over `liveSession`, the durable record behind the Live Sessions look-back summary and streak.
// Idempotent upsert keyed by (deviceId, startTs).

/// One Live Session record. Natural key (deviceId, startTs). `endTs` is nil while in progress; the two cue
/// counts are the push nudges / ease-offs the coach sent.
public struct LiveSessionRow: Equatable, Codable {
    public let startTs: Int              // unix seconds — session start (the key)
    public let endTs: Int?               // unix seconds — nil while in progress
    public let chargeAtStart: Double?    // 0...100 recovery Charge at start; nil if unknown
    public let floorBpm: Double          // guarded band, floor
    public let ceilingBpm: Double        // guarded band, ceiling
    public let inBandSec: Double
    public let belowSec: Double
    public let aboveSec: Double
    public let pushCount: Int            // "give more" cues sent
    public let easeCount: Int            // "ease off" cues sent
    public let hrSource: String          // "whoop" | "strap" | "power" etc.

    public init(startTs: Int, endTs: Int?, chargeAtStart: Double?, floorBpm: Double, ceilingBpm: Double,
                inBandSec: Double, belowSec: Double, aboveSec: Double, pushCount: Int, easeCount: Int,
                hrSource: String) {
        self.startTs = startTs; self.endTs = endTs; self.chargeAtStart = chargeAtStart
        self.floorBpm = floorBpm; self.ceilingBpm = ceilingBpm
        self.inBandSec = inBandSec; self.belowSec = belowSec; self.aboveSec = aboveSec
        self.pushCount = pushCount; self.easeCount = easeCount; self.hrSource = hrSource
    }
}

extension WhoopStore {

    /// Upserts one Live Session (called at start with endTs nil, and again at end with final totals). Returns rows changed.
    ///
    /// The `WHERE excluded.endTs IS NOT NULL OR liveSession.endTs IS NULL` guard stops a late start-write from
    /// overwriting an already-ended row: start and end persist as independent, unordered tasks.
    @discardableResult
    public func upsertLiveSession(_ r: LiveSessionRow, deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO liveSession
                    (deviceId, startTs, endTs, chargeAtStart, floorBpm, ceilingBpm,
                     inBandSec, belowSec, aboveSec, pushCount, easeCount, hrSource)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET
                    endTs = excluded.endTs,
                    chargeAtStart = excluded.chargeAtStart,
                    floorBpm = excluded.floorBpm,
                    ceilingBpm = excluded.ceilingBpm,
                    inBandSec = excluded.inBandSec,
                    belowSec = excluded.belowSec,
                    aboveSec = excluded.aboveSec,
                    pushCount = excluded.pushCount,
                    easeCount = excluded.easeCount,
                    hrSource = excluded.hrSource
                WHERE excluded.endTs IS NOT NULL OR liveSession.endTs IS NULL
                """, arguments: [deviceId, r.startTs, r.endTs, r.chargeAtStart, r.floorBpm, r.ceilingBpm,
                                 r.inBandSec, r.belowSec, r.aboveSec, r.pushCount, r.easeCount, r.hrSource])
            return db.changesCount
        }
    }

    /// The most recent sessions, newest by startTs first.
    public func recentLiveSessions(deviceId: String, limit: Int) async throws -> [LiveSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, chargeAtStart, floorBpm, ceilingBpm, inBandSec, belowSec, aboveSec,
                       pushCount, easeCount, hrSource FROM liveSession
                WHERE deviceId = ?
                ORDER BY startTs DESC LIMIT ?
                """, arguments: [deviceId, limit])
                .map {
                    LiveSessionRow(startTs: $0["startTs"], endTs: $0["endTs"],
                                   chargeAtStart: $0["chargeAtStart"], floorBpm: $0["floorBpm"],
                                   ceilingBpm: $0["ceilingBpm"], inBandSec: $0["inBandSec"],
                                   belowSec: $0["belowSec"], aboveSec: $0["aboveSec"],
                                   pushCount: $0["pushCount"], easeCount: $0["easeCount"],
                                   hrSource: $0["hrSource"])
                }
        }
    }
}
