import Dispatch
import Foundation
import GRDB
import WhoopProtocol

/// One downsampled heart-rate point: the bucket's start (unix seconds) and the mean bpm over it, from
/// the `GROUP BY ts/bucket` aggregate so a day chart avoids loading ~86k raw rows.
public struct HRBucket: Sendable, Equatable {
    public let ts: Int
    public let bpm: Double
    /// The lowest and highest sample in the bucket, not the mean. A Min/Max readout taken from the
    /// averaged `bpm` series describes the calmest and busiest five minutes, not the day.
    public let minBpm: Double
    public let maxBpm: Double
    /// The weakest signal confidence in this bucket: 1.0 for measured `hrSample` rows, the stored
    /// autocorrelation `conf` for PPG-derived fallback rows. Lets a chart draw weak-optical stretches distinctly.
    public let conf: Double
    /// `minBpm` and `maxBpm` are required, not defaulted: a default would let extremes silently equal the
    /// mean, a number that looks like a reading and describes something else.
    public init(ts: Int, bpm: Double, minBpm: Double, maxBpm: Double, conf: Double = 1.0) {
        self.ts = ts
        self.bpm = bpm
        self.minBpm = minBpm
        self.maxBpm = maxBpm
        self.conf = conf
    }
}

/// Aggregate HR over a time window, the result of [WhoopStore.hrWindowStats]. `avg`/`max` are nil when `n == 0`.
public struct HRWindowStats: Sendable, Equatable {
    public let n: Int
    public let avg: Double?
    public let max: Int?
    public init(n: Int, avg: Double?, max: Int?) { self.n = n; self.avg = avg; self.max = max }
}

extension WhoopStore {
    /// Shared decoder: battery events are dense (~every 8 min), so a multi-year read would otherwise allocate one per row.
    fileprivate static let eventDecoder = JSONDecoder()

    /// Raw HR samples over `[from, to]`, measured-first with PPG-derived fallback.
    ///
    /// Every measured second wins; a second with no `hrSample` row falls back to its `ppgHrSample`
    /// estimate (same anti-join as `hrBuckets`, never doubling a beat). This lets a PPG-only WHOOP 5 night
    /// clear the night-stager's HR-count gate. The REAL PPG `bpm` is rounded to the `HRSample.bpm` Int domain.
    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to,
                                 deviceId, from, to,
                                 limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    /// Standard-BLE sensor-contact readings recorded alongside generic HR samples. Rows from before this
    /// existed have no contact event and return no invented legacy values.
    public func standardHRContacts(deviceId: String, from: Int, to: Int,
                                   limit: Int) async throws -> [StandardHRContactSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, payloadJSON FROM event
                WHERE deviceId = ? AND kind = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, StandardHRMapping.contactEventKind, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    return try StandardHRMapping.contactSample(ts: row["ts"], payloadJSON: json)
                }
        }
    }

    /// Cheap change-detector for the raw HR stream: `(count, maxTs)` over `[from, to]`, computed in SQLite
    /// over the `(deviceId, ts)` index without materializing rows. `COUNT(*)` moves on any insert
    /// (including a backfilled old night), `maxTs` distinguishes fresh appends. An empty window is `(0, 0)`.
    public func hrFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            // COUNT(*) and COALESCE(MAX(ts),0) are non-null and the aggregate always returns one row; the guard is belt-and-suspenders.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Whether `deviceId` has any heart rate in the window, as a scalar EXISTS rather than a row.
    ///
    /// Checks both `hrSample` and `ppgHrSample`: a WHOOP 4.0 v25 record stores no per-second HR and lands
    /// only in `ppgHrSample`, so `hrSample` alone would stop those days from owning themselves. The
    /// union's `NOT EXISTS` de-dupe does not affect presence, and OR short-circuits.
    public func hasHrInWindow(deviceId: String, from: Int, to: Int) async throws -> Bool {
        // Counted here rather than at the call site: the resolver is `nonisolated static` with nowhere to
        // accumulate, and the steps loop runs in a detached task. Instrumentation only (`StoreProbeTally`).
        let probeStarted = DispatchTime.now().uptimeNanoseconds
        defer { StoreProbeRecorder.record(.ownerHr, nanos: DispatchTime.now().uptimeNanoseconds &- probeStarted) }
        return try syncRead { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?)
                    OR EXISTS(SELECT 1 FROM ppgHrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?)
                """, arguments: [deviceId, from, to, deviceId, from, to]) ?? false
        }
    }

    /// Per-day gravity fingerprint: `(count, maxTs)` over one device's `gravitySample` rows in a window.
    ///
    /// The witness the steps-calibration motion cache keys on. `dayStreamFingerprint` computes this pair
    /// alongside eight other streams, so a new HR row would invalidate a motion volume that cannot have
    /// changed. Same shape and index as `hrFingerprint(deviceId:from:to:)`, never a row fetch.
    public func gravityFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        // Counted for the same reason as `hasHrInWindow`.
        let probeStarted = DispatchTime.now().uptimeNanoseconds
        defer { StoreProbeRecorder.record(.gravityFp, nanos: DispatchTime.now().uptimeNanoseconds &- probeStarted) }
        return try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, from, to]) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Cross-device raw-HR fingerprint: `(count, maxTs)` over every `hrSample` row, no `deviceId` filter.
    /// The `analyzeRecent` re-score gate must see HR landing under any id (an Oura ring, an Apple Watch,
    /// a WHOOP re-added under a fresh `whoop-<uuid>`), not just the literal "my-whoop" the per-device
    /// `hrFingerprint(deviceId:from:to:)` is pinned to.
    public func hrFingerprint() async throws -> (count: Int, maxTs: Int) {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                """) else { return (0, 0) }
            let c: Int = row["c"]
            let m: Int = row["m"]
            return (c, m)
        }
    }

    /// Cross-device change detector for every raw stream that can change a daily score or sleep session.
    ///
    /// Historical offloads do not commit streams atomically (HR can land before motion/gravity), so the
    /// fingerprint covers the complete scoring input: HR keeps its count+timestamp fingerprint, the other
    /// streams use SQLite's monotonic rowid frontier, which catches old backfills without full-table
    /// COUNT scans. `v3` also witnesses authoritative WHOOP 5 RR promotions and registry-only
    /// source-policy changes; bumping the version recomputes the recent window once.
    public func analysisFingerprint() async throws -> String {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  (SELECT COUNT(*) FROM hrSample) AS hc,
                  (SELECT COALESCE(MAX(ts), 0) FROM hrSample) AS hm,
                  (SELECT COALESCE(MAX(rowid), 0) FROM ppgHrSample) AS p,
                  (SELECT COALESCE(MAX(rowid), 0) FROM rrInterval) AS r,
                  (SELECT COUNT(*) FROM rrInterval WHERE srcChannel = 5
                     AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS w5,
                  (SELECT COUNT(*) FROM rrInterval WHERE srcChannel = 7
                     AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS w7,
                  (SELECT COUNT(*) FROM rrInterval WHERE srcChannel IN (5, 6, 7)) AS w5tagged,
                  (SELECT COUNT(*) FROM rrInterval WHERE srcChannel = 8) AS w4history,
                  (SELECT COALESCE(GROUP_CONCAT(identity, ';'), '') FROM
                    (SELECT QUOTE(id) || ':' || QUOTE(brand) || ':' || QUOTE(model) || ':' || QUOTE(status) AS identity
                     FROM pairedDevice ORDER BY id)) AS registry,
                  (SELECT COALESCE(MAX(rowid), 0) FROM respSample) AS x,
                  (SELECT COALESCE(MAX(rowid), 0) FROM gravitySample) AS g,
                  (SELECT COALESCE(MAX(rowid), 0) FROM sleepStateSample) AS s,
                  (SELECT COALESCE(MAX(rowid), 0) FROM event) AS e,
                  (SELECT COALESCE(MAX(rowid), 0) FROM spo2Sample) AS o,
                  (SELECT COALESCE(MAX(rowid), 0) FROM skinTempSample) AS t,
                  (SELECT COALESCE(MAX(rowid), 0) FROM stepSample) AS z
                """) else { return "" }
            let hc: Int = row["hc"], hm: Int = row["hm"]
            let keys = ["p", "r", "x", "g", "s", "e", "o", "t", "z"]
            let tails = keys.map { key -> String in
                let frontier: Int = row[key]
                return key + String(frontier)
            }
            let historyCount: Int = row["w5"]
            let registry: String = row["registry"]
            return "v5|h\(hc):\(hm)|" + tails.joined(separator: "|")
                + "|w5\(historyCount)|w7\(row["w7"] as Int)|tagged\(row["w5tagged"] as Int)"
                + "|w4history\(row["w4history"] as Int)|registry\(registry)"
        }
    }

    /// Per-day, per-owner change detector for every scored stream that [hrFingerprint] does not witness.
    ///
    /// [analysisFingerprint] answers "did anything change anywhere"; this answers "did this night's scored
    /// input change", the question the `analyzeRecent` per-day reuse cache asks. A night scored from HR
    /// alone can gain R-R, respiration or SpO2 later with the `hrSample` `(count, maxTs)` unmoved.
    ///
    /// One statement, one index range walk per stream, no rows materialised. `COUNT(*)` is load-bearing:
    /// it moves when a backfill lands rows inside an already-covered window, which `MAX(ts)` misses.
    /// The five R-R figures share one walk (the `rr` derived table) because each needs `srcChannel` or
    /// `tsSuspect`, which the key index lacks; five sub-selects cost 44% of a warm re-score on a 54 h WHOOP 5 window.
    ///
    /// The streams are exactly those the per-day loop hands to `analyzeDay`:
    /// - `ppgHrSample`: the day's HR is measured and PPG-derived ([hrSamples]).
    /// - `rrInterval`: filtered as [rrIntervals] filters (0x6E duplicate and future-stamped beats excluded)
    ///   but without its one-Oura-channel selection, since a new row on either channel can change which is scored.
    /// - `sleepStateSample`: lands from the same v18 record as HR, so a re-offloaded record whose HR row is
    ///   dropped on conflict still adds a band row. Its letter is `b`; `s` is the version prefix.
    /// - `respSample`, `spo2Sample`, `gravitySample`, `stepSample`, `skinTempSample`, `event`.
    ///
    /// Returned as an opaque string that is only compared to itself in memory, so no cross-platform byte identity is needed.
    public func dayStreamFingerprint(deviceId: String, from: Int, to: Int) async throws -> String {
        try syncRead { db in
            // Every sub-select is COUNT/COALESCE(MAX(...), 0), so the aggregate always returns one non-null row.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  (SELECT COUNT(*) FROM ppgHrSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS pc,
                  (SELECT COALESCE(MAX(ts), 0) FROM ppgHrSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS pm,
                  rr.rc AS rc, rr.rm AS rm, rr.w5 AS w5, rr.w7 AS w7,
                  EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = :d AND srcChannel IN (5, 6, 7)) AS w5owner,
                  rr.w4h AS w4h,
                  COALESCE((SELECT QUOTE(brand) || ':' || QUOTE(model) FROM pairedDevice
                            WHERE id = :d), 'absent') AS registry,
                  (SELECT COUNT(*) FROM respSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS xc,
                  (SELECT COALESCE(MAX(ts), 0) FROM respSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS xm,
                  (SELECT COUNT(*) FROM spo2Sample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS oc,
                  (SELECT COALESCE(MAX(ts), 0) FROM spo2Sample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS om,
                  (SELECT COUNT(*) FROM gravitySample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS gc,
                  (SELECT COALESCE(MAX(ts), 0) FROM gravitySample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS gm,
                  (SELECT COUNT(*) FROM stepSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS zc,
                  (SELECT COALESCE(MAX(ts), 0) FROM stepSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS zm,
                  (SELECT COUNT(*) FROM skinTempSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS tc,
                  (SELECT COALESCE(MAX(ts), 0) FROM skinTempSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS tm,
                  (SELECT COUNT(*) FROM sleepStateSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS bc,
                  (SELECT COALESCE(MAX(ts), 0) FROM sleepStateSample WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS bm,
                  (SELECT COUNT(*) FROM event WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS ec,
                  (SELECT COALESCE(MAX(ts), 0) FROM event WHERE deviceId = :d AND ts >= :f AND ts <= :t) AS em
                FROM (SELECT
                        COUNT(CASE WHEN srcChannel IS NULL OR srcChannel <> :rrx THEN 1 END) AS rc,
                        COALESCE(MAX(CASE WHEN srcChannel IS NULL OR srcChannel <> :rrx THEN ts END), 0) AS rm,
                        COUNT(CASE WHEN srcChannel = 5 THEN 1 END) AS w5,
                        COUNT(CASE WHEN srcChannel = 7 THEN 1 END) AS w7,
                        COUNT(CASE WHEN srcChannel = :whoop4Historical THEN 1 END) AS w4h
                      FROM rrInterval WHERE deviceId = :d AND ts >= :f AND ts <= :t
                        AND (tsSuspect IS NULL OR tsSuspect <> 1)) AS rr
                """, arguments: ["d": deviceId, "f": from, "t": to,
                                 "rrx": RRSourceChannel.spo2Ibi.rawValue,
                                 "whoop4Historical": RRSourceChannel.whoop4Historical.rawValue]) else { return "" }
            let keys = ["p", "r", "x", "o", "g", "z", "t", "b", "e"]
            let parts = keys.map { key -> String in
                let count: Int = row[key + "c"], maxTs: Int = row[key + "m"]
                return "\(key)\(count):\(maxTs)"
            }
            let historyCount: Int = row["w5"]
            let registry: String = row["registry"]
            let strictRR = try Self.isWhoop5RRSource(db: db, deviceId: deviceId)
            return "s4|" + parts.joined(separator: "|") + "|w5\(historyCount)|w7\(row["w7"] as Int)"
                + "|w4h\(row["w4h"] as Int)|ownerTagged\(row["w5owner"] as Int)|registry\(registry)|rr5=\(strictRR)"
        }
    }

    /// Aggregate HR over a window: `(n, avg, max)` computed in SQLite over the same measured-and-PPG rows
    /// [hrSamples] returns, without materialising them and without a row limit. `avg`/`max` are nil when `n == 0`.
    ///
    /// Reducing a capped `hrSamples` read in Swift averaged only the first 8000 samples of any workout over
    /// ~2 h 13 m, so this aggregates the entire window.
    ///
    /// Aggregates across up to two device ids with `primaryId` winning per second. A plain `deviceId IN (...)`
    /// would double-count a second banked under both ids after a strap re-add, inflating `n` and skewing
    /// `avg` while staying plausible. `GROUP BY ts` with `MIN(pri)` keeps one row per second, and SQLite's
    /// bare-column rule takes `bpm` from the row that supplied the `MIN`. The same id for both is the single-id read.
    public func hrWindowStats(primaryId: String, secondaryId: String,
                              from: Int, to: Int) async throws -> HRWindowStats {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, AVG(bpm) AS avg, MAX(bpm) AS max FROM (
                    SELECT ts, MIN(pri), bpm FROM (
                        SELECT ts, bpm, 0 AS pri FROM hrSample
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        UNION ALL
                        SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER), 0 FROM ppgHrSample p
                        WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                          AND NOT EXISTS (SELECT 1 FROM hrSample h
                                          WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                        UNION ALL
                        SELECT ts, bpm, 1 FROM hrSample
                        WHERE deviceId = ? AND ts >= ? AND ts <= ?
                        UNION ALL
                        SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER), 1 FROM ppgHrSample p
                        WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                          AND NOT EXISTS (SELECT 1 FROM hrSample h
                                          WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                    ) GROUP BY ts
                )
                """, arguments: [primaryId, from, to, primaryId, from, to,
                                 secondaryId, from, to, secondaryId, from, to])
            else { return HRWindowStats(n: 0, avg: nil, max: nil) }
            return HRWindowStats(n: row["n"], avg: row["avg"], max: row["max"])
        }
    }

    /// Downsampled HR for charting: mean bpm per `bucketSeconds`-wide bucket over `[from, to]`, keyed by
    /// the bucket's start (floor(ts/bucket)*bucket), ascending. Aggregated in SQL so a 24h window returns
    /// ~`(to-from)/bucketSeconds` rows.
    ///
    /// Measured `hrSample` wins each second; a second with no row falls back to its `ppgHrSample` estimate
    /// (anti-join, never doubling a beat) so the chart stays continuous through PPG-heavy stretches.
    public func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket] {
        let bucket = max(1, bucketSeconds)
        return try syncRead { db in
            // MIN(conf) per bucket: measured rows are 1.0, PPG fallback rows their stored conf, so a bucket
            // touched by any weak-optical estimate reads as weak. Additive projection; the bpm aggregate is unchanged.
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS avgBpm, MIN(conf) AS minConf,
                       MIN(bpm) AS minBpm, MAX(bpm) AS maxBpm FROM (
                    SELECT ts, bpm, 1.0 AS conf FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, p.bpm, p.conf FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                GROUP BY ts / ?
                ORDER BY bucket ASC
                """, arguments: [bucket, bucket,
                                 deviceId, from, to,
                                 deviceId, from, to,
                                 bucket])
                .map { HRBucket(ts: $0["bucket"], bpm: $0["avgBpm"],
                                minBpm: $0["minBpm"], maxBpm: $0["maxBpm"],
                                conf: $0["minConf"] ?? 1.0) }
        }
    }

    /// The Oura beat channels `rrIntervals` chooses between, as a SQL list: `greenQuality` (0x80) on one
    /// side, the amplitude family `ibiAmplitude` (0x60) + `ibiBare` (0x44) on the other (one decoder, split
    /// for labelling only, so scored together). `spo2Ibi` (0x6E) is excluded outright. Mirrors the Kotlin
    /// scorable-channel set so the two scoring reads cannot drift.
    static let scorableOuraChannels = "(1, 3, 4)"

    /// R-R intervals in emission order. `ord` leads the sort: ordering by `rrMs` returns a second's beats
    /// sorted by value, which makes successive beats similar and biases RMSSD downward. Pre-v30 rows have
    /// `ord` NULL (sorted first in ASC), so an all-NULL second falls through to the old `(rrMs, seq)` order.
    /// WHOOP 5 reads one verified transport; its unlabelled legacy rows stay stored but unscored.
    ///
    /// One optical channel. An Oura ring measures the same heartbeats on more than one tag and all are
    /// stored, so an unfiltered read returned about two copies of a night, which leaves `meanNN` correct
    /// but wrecks RMSSD and SDNN (a ~200 ms nocturnal SDNN where a healthy adult asleep is 40-100 ms).
    ///
    /// The predicate excludes the one channel proven redundant (`spo2Ibi`, 0x6E) rather than whitelisting
    /// one: it is quantised to an 8 ms grid, has no quality gate and runs only during an SpO2 measurement,
    /// so scoring off it would tie HRV coverage to the SpO2 duty cycle. Outside strict WHOOP 5 policy,
    /// NULL (WHOOP 4, unlabelled legacy) is kept, and `ibiAmplitude` is kept so a ring's only beat source is never dropped.
    ///
    /// Beyond that exclusion, one Oura channel is kept per window: 0x60 and 0x80 fire together over the
    /// same nights (on one ring 0x60 covers 0.91-0.99 of the wall clock and 0x80 adds a partial copy), so
    /// the pair read 1.01-1.31 and the coverage gate refused nights with more 0x80. Which channel is
    /// complete is a property of the capture, so green is kept alone when it holds more beats than the
    /// amplitude family (`scorableOuraChannels`), the amplitude family otherwise, ties included. NULL rows
    /// and non-Oura codes are untouched.
    ///
    /// The choice is made per UTC hour, not per window: 0x60 is banked only overnight and 0x80 carries every
    /// daytime beat, so a whole-window count let a night's 0x60 outvote and drop the day's 0x80. Each hour is
    /// counted over its part of the window with the same time/suspect predicates as the outer read, before
    /// LIMIT. Same shape as the WHOOP 4 per-hour source choice below.
    ///
    /// Rows are filtered, never deleted: the 0x6E stream stays on disk as the cross-check. Every R-R
    /// consumer reads through this function so the `hrv diag` trace matches the scores.
    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
        try await rrIntervals(deviceId: deviceId, from: from, to: to, limit: limit,
                              unlabelledAliasOfWhoop5: false)
    }

    /// A canonical alias of a WHOOP 5 may hold old mixed-unit rows. Apply the unit guard when the alias
    /// has no confirmed identity; a known WHOOP 4 or another brand keeps its own read policy.
    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int,
                            unlabelledAliasOfWhoop5: Bool) async throws -> [RRInterval] {
        try syncRead { db in
            let strictWhoop5 = try Self.isWhoop5RRSource(db: db, deviceId: deviceId,
                unlabelledAliasOfWhoop5: unlabelledAliasOfWhoop5)
            // One transport for the complete requested interval. Legacy WHOOP 5 rows mix units and origins, so
            // they stay stored but cannot be spliced into a scored beat train. The subquery uses the same
            // time/suspect predicates as the outer read, before LIMIT.
            // WHOOP 4 has labelled type-47 history, type-40 realtime, standard-BLE and unlabelled legacy rows:
            // choose one source per UTC hour in provenance order so live transports are never merged.
            // Every other source takes the Oura branch (see the doc comment on `rrIntervals`).
            let strictWhoop4History: Bool
            if strictWhoop5 { strictWhoop4History = false }
            else {
                if try Self.isWhoop4RRSource(db: db, deviceId: deviceId) { strictWhoop4History = true }
                else {
                    strictWhoop4History = try Bool.fetchOne(db,
                        sql: "SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel = ?)",
                        arguments: [deviceId, RRSourceChannel.whoop4Historical.rawValue]) ?? false
                }
            }
            let whoop5SourcePredicate = """
                srcChannel = (SELECT MIN(srcChannel) FROM rrInterval
                    WHERE deviceId = :d AND ts >= :f AND ts <= :t AND srcChannel IN \(Self.scorableWhoop5Channels)
                    AND (tsSuspect IS NULL OR tsSuspect <> 1))
                """
            // The WHOOP 4 source decision is per UTC hour. Materialize one choice per hour and join that small
            // result to the beats: counting each hour from every beat made wide HRV reads quadratic.
            let sql: String
            if strictWhoop4History {
                sql = """
                    WITH whoop4HourChoice AS MATERIALIZED (
                        SELECT ts / 3600 AS hour,
                               MIN(CASE WHEN srcChannel = :whoop4Historical THEN 1
                                        WHEN srcChannel = :whoop4Realtime THEN 2
                                        WHEN srcChannel = :whoop4Standard THEN 3
                                        WHEN srcChannel IS NULL THEN 4 END) AS sourceChoice
                        FROM rrInterval
                        WHERE deviceId = :d
                          AND ts >= (:f / 3600) * 3600
                          AND ts < ((:t / 3600) + 1) * 3600
                          AND (tsSuspect IS NULL OR tsSuspect <> 1)
                          AND (srcChannel IS NULL OR srcChannel IN
                               (:whoop4Historical, :whoop4Realtime, :whoop4Standard))
                        GROUP BY ts / 3600
                    )
                    SELECT r.ts, r.rrMs, r.srcChannel, r.ord, r.seq FROM rrInterval r
                    JOIN whoop4HourChoice h ON h.hour = r.ts / 3600
                    WHERE r.deviceId = :d AND r.ts >= :f AND r.ts <= :t
                      AND (r.srcChannel IS NULL OR r.srcChannel <> :rrx)
                      AND ((r.srcChannel = :whoop4Historical AND h.sourceChoice = 1)
                           OR (r.srcChannel = :whoop4Realtime AND h.sourceChoice = 2)
                           OR (r.srcChannel = :whoop4Standard AND h.sourceChoice = 3)
                           OR (r.srcChannel IS NULL AND h.sourceChoice = 4))
                      AND (r.tsSuspect IS NULL OR r.tsSuspect <> 1)
                    ORDER BY r.ts ASC, r.ord ASC, r.rrMs ASC, r.seq ASC LIMIT :lim
                    """
            } else if strictWhoop5 {
                sql = """
                    SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                    WHERE deviceId = :d AND ts >= :f AND ts <= :t
                    AND (srcChannel IS NULL OR srcChannel <> :rrx)
                    AND \(whoop5SourcePredicate)
                    AND (tsSuspect IS NULL OR tsSuspect <> 1)   -- exclude future-stamped (#1073) and 500 ms fill (#2371) beats
                    ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :lim
                    """
            } else {
                // One Oura channel per UTC hour, counted inside the requested window. LEFT JOIN so NULL and non-Oura
                // rows pass whether or not their hour has a choice. The outer table stays unaliased so column names
                // read as in the other branches.
                sql = """
                    WITH ouraHourChoice AS MATERIALIZED (
                        SELECT ts / 3600 AS hour, SUM(srcChannel = 1) > SUM(srcChannel <> 1) AS keepGreen
                        FROM rrInterval
                        WHERE deviceId = :d AND ts >= :f AND ts <= :t AND srcChannel IN \(Self.scorableOuraChannels)
                          AND (tsSuspect IS NULL OR tsSuspect <> 1)
                        GROUP BY ts / 3600
                    )
                    SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                    LEFT JOIN ouraHourChoice h ON h.hour = rrInterval.ts / 3600
                    WHERE deviceId = :d AND ts >= :f AND ts <= :t
                    AND (srcChannel IS NULL OR srcChannel <> :rrx)
                    AND (srcChannel IS NULL OR srcChannel NOT IN \(Self.scorableOuraChannels)
                         OR (srcChannel = 1) = h.keepGreen)
                    AND (tsSuspect IS NULL OR tsSuspect <> 1)   -- exclude future-stamped (#1073) and 500 ms fill (#2371) beats
                    ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :lim
                    """
            }
            let rows = try Row.fetchAll(db, sql: sql,
                                        arguments: ["d": deviceId, "f": from, "t": to,
                                                    "rrx": RRSourceChannel.spo2Ibi.rawValue,
                                                    "whoop4Historical": RRSourceChannel.whoop4Historical.rawValue,
                                                    "whoop4Realtime": RRSourceChannel.whoop4Realtime.rawValue,
                                                    "whoop4Standard": RRSourceChannel.whoop4Standard.rawValue,
                                                    "lim": limit])
                .map { row in
                    RRInterval(ts: row["ts"], rrMs: row["rrMs"],
                               srcChannel: (row["srcChannel"] as Int?).flatMap(RRSourceChannel.init(rawValue:)),
                               ord: row["ord"] as Int?, seq: row["seq"])
                }
            // A ring record served twice is stored twice: each connection anchors on its own SyncTime, so the
            // copy lands a second or two off and misses the row key. Collapsed here so every scoring reader
            // agrees (the damage is a coverage over-count). The raw diagnostic export deliberately does not
            // come through here, so a strap log and the app can legitimately disagree on beat counts.
            return OuraRedrainCollapse.withoutRedrainedRuns(rows)
        }
    }

    /// The diagnostic read: every beat channel except the `spo2Ibi` (0x6E) duplicate, with no scoring
    /// selection, so a log count or export still carries both Oura channels as each other's cross-check.
    /// Quarantined (`tsSuspect`) beats stay excluded.
    ///
    /// This counts what was banked, not what is scored. For a WHOOP 5 it counts every stored transport
    /// rather than the single scored one, so its `rr=` sits above the scored count. It also does not
    /// collapse a record the drain served twice, so a redrained night counts duplicates here while the
    /// `hrv diag` line does not; that disagreement is the signal that a redrain happened.
    public func rawRrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                WHERE deviceId = :d AND ts >= :f AND ts <= :t
                AND (srcChannel IS NULL OR srcChannel <> :rrx)
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :lim
                """, arguments: ["d": deviceId, "f": from, "t": to,
                                 "rrx": RRSourceChannel.spo2Ibi.rawValue, "lim": limit])
                .map { row in
                    RRInterval(ts: row["ts"], rrMs: row["rrMs"],
                               srcChannel: (row["srcChannel"] as Int?).flatMap(RRSourceChannel.init(rawValue:)),
                               ord: row["ord"] as Int?, seq: row["seq"])
                }
        }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? WhoopStore.eventDecoder.decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    /// The most recent banked battery reading, with its charging bit. Separate from `batterySamples`,
    /// which drops `charging`; a stale-battery warning needs to know whether the strap was last seen on the charger.
    public func latestBattery(deviceId: String) async throws -> (ts: Int, soc: Double?, charging: Bool?)? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT ts, soc, charging FROM battery
                WHERE deviceId = ?
                ORDER BY ts DESC LIMIT 1
                """, arguments: [deviceId])
                .map { (ts: $0["ts"], soc: $0["soc"], charging: $0["charging"]) }
        }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"]) }
        }
    }

    public func spo2Samples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SpO2Sample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
        }
    }

    public func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SkinTempSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw, aux1Raw, aux2Raw FROM skinTempSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // aux1Raw/aux2Raw read back nil for pre-v31 rows and WHOOP 4.0 records (no such channels). Hydrated
                // so the carrier is a faithful view of the row; no caller reads them.
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"],
                                      aux1Raw: $0["aux1Raw"], aux2Raw: $0["aux2Raw"]) }
        }
    }

    public func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // activityClass reads back nil for pre-v19 rows and records whose @63 byte was 0xFF/invalid/absent.
                .map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
        }
    }

    public func stepSamplesPage(deviceId: String, afterExclusive: Int, endExclusive: Int,
                                limit: Int) async throws -> [StepSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts > ? AND ts < ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, afterExclusive, endExclusive, limit]).map {
                    StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"])
                }
        }
    }

    /// Last counter sample before a cycle boundary, used to attribute the first in-cycle delta correctly.
    public func stepSampleBefore(deviceId: String, before: Int) async throws -> StepSample? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts < ? ORDER BY ts DESC LIMIT 1
                """, arguments: [deviceId, before]).map {
                    StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"])
                }
        }
    }

    public func hasStepActivityClasses(deviceId: String, from: Int, to: Int) async throws -> Bool {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts < ? AND activityClass IS NOT NULL)
                """, arguments: [deviceId, from, to]) == 1
        }
    }

    public func stepTimestampCoverage(deviceId: String, from: Int, to: Int) async throws
        -> (first: Int?, last: Int?) {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(ts) AS firstTs, MAX(ts) AS lastTs FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, from, to])
            return (row?["firstTs"], row?["lastTs"])
        }
    }

    /// Bounded process-local invalidator over the UTC days touched by this window. The instance token
    /// stops a static cycle cache surviving a store reopen from reusing revisions from the old DB.
    public func stepDataRevisionSignature(deviceId: String, from: Int, to: Int) async -> String {
        "\(revisionInstanceToken):\(deviceId):\(stepDataRevision.signature(deviceId: deviceId, from: from, to: to))"
    }

    public func stepDiagnosticMotionCounts(deviceId: String, from: Int, to: Int) async throws
        -> (gravity: Int, aux: Int) {
        try syncRead { db in
            let gravity = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM gravitySample WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, from, to]) ?? 0
            let aux = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM v18AuxSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, from, to]) ?? 0
            return (gravity, aux)
        }
    }

    public func respSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RespSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    /// Which raw streams a device has any rows for in a window, answered without counting.
    ///
    /// EXISTS rather than COUNT: every table is keyed `(deviceId, ts)`, so each subquery is an index seek
    /// that stops at the first row (a 4.0 night has ~190k gravity rows). One statement, one round trip. A
    /// strap streaming HR with no motion cannot produce a staged night or an auto-detected workout.
    /// Diagnostics-export only.
    public struct StreamPresence: Sendable, Equatable {
        public let hr: Bool, rr: Bool, gravity: Bool, steps: Bool
        public init(hr: Bool, rr: Bool, gravity: Bool, steps: Bool) {
            self.hr = hr; self.rr = rr; self.gravity = gravity; self.steps = steps
        }
    }

    public func streamPresence(deviceId: String, from: Int, to: Int) async throws -> StreamPresence {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                  EXISTS(SELECT 1 FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?) AS hr,
                  EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts <= ?) AS rr,
                  EXISTS(SELECT 1 FROM gravitySample WHERE deviceId = ? AND ts >= ? AND ts <= ?) AS gravity,
                  EXISTS(SELECT 1 FROM stepSample WHERE deviceId = ? AND ts >= ? AND ts <= ?) AS steps
                """, arguments: [deviceId, from, to, deviceId, from, to,
                                 deviceId, from, to, deviceId, from, to])
            return StreamPresence(
                hr: (row?["hr"] ?? 0) != 0, rr: (row?["rr"] ?? 0) != 0,
                gravity: (row?["gravity"] ?? 0) != 0, steps: (row?["steps"] ?? 0) != 0)
        }
    }

    public func rawSampleCountsByDevice(from: Int, to: Int) async throws -> [(String, Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT deviceId, SUM(n) AS total FROM (
                    SELECT deviceId, COUNT(*) AS n FROM hrSample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                    UNION ALL
                    SELECT deviceId, COUNT(*) AS n FROM ppgHrSample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                    UNION ALL
                    SELECT deviceId, COUNT(*) AS n FROM gravitySample WHERE ts >= ? AND ts <= ? GROUP BY deviceId
                )
                GROUP BY deviceId
                """, arguments: [from, to, from, to, from, to])
            .map { row -> (String, Int) in
                // `deviceId` is NOT NULL and GROUP BY guarantees SUM(n) >= 1 per row, so both read as non-optionals.
                let d: String = row["deviceId"]
                let t: Int = row["total"]
                return (d, t)
            }
            .filter { !$0.0.isEmpty && $0.1 > 0 }
        }
    }

    public func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z, dynAccel FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // dynAccel reads back nil for pre-v31 rows and WHOOP 4.0 records. The sleep stager reads x/y/z only; this column is carried, never scored.
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"],
                                     dynAccel: $0["dynAccel"]) }
        }
    }

    /// Max HR sample timestamp for a device, or nil if there are none. The "data frontier" for the
    /// stuck-strap watchdog (advances iff the strap is logging and offloading).
    ///
    /// Coalesces measured `hrSample` with `ppgHrSample` so a PPG-only offload still advances it. Each arm
    /// is its own `SELECT MAX(ts)`, not one `MAX(ts)` over a `UNION ALL`: SQLite's MIN/MAX optimization
    /// only fires on a bare `SELECT MAX(col)`, and the compound form walked every index entry (4.3-5.8 s
    /// per call on a 3.1M-row store, against 0.01-0.07 s).
    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MAX(m) FROM (
                    SELECT (SELECT MAX(ts) FROM hrSample WHERE deviceId = ?) AS m
                    UNION ALL
                    SELECT (SELECT MAX(ts) FROM ppgHrSample WHERE deviceId = ?)
                )
                """, arguments: [deviceId, deviceId])
        }
    }

    /// Per-table row counts for every accumulating decoded stream, keyed identically to Android's
    /// `WhoopRepository.storageRowCounts` so a maintainer reads the same map from either platform.
    ///
    /// Shares `rawTableKeys` with `storageStats()` and `TimestampHeal`, so a table added to one is seen by
    /// all three. Best-effort per table: an unreadable count is omitted, not reported as zero, since zero
    /// would claim the table is empty.
    public func storageRowCounts() async throws -> [String: Int] {
        try syncRead { db in
            var out: [String: Int] = [:]
            for (key, table) in Self.rawTableKeys {
                if let n = try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") { out[key] = n }
            }
            return out
        }
    }

    /// Estimated payload bytes per decoded stream table, keyed as `storageRowCounts()` keys.
    ///
    /// Row counts cannot attribute a multi-gigabyte database because `ppgWaveformSample` stores a
    /// variable-size BLOB, so this measures the blob. Sampled, not scanned: the mean payload of up to
    /// `sampleRows` rows times the count, since a full `SUM(LENGTH(...))` is the read this diagnostic
    /// exists to avoid on a 6.5 GB store.
    ///
    /// BLOB and TEXT columns count by real length, numeric columns at a nominal 8; index pages, page
    /// slack and the WAL are excluded, so it is a payload lower bound to compare against `db_bytes`.
    /// An unreadable table is omitted (absent is not zero). `rowCounts` lets a caller that already has
    /// them skip a second `COUNT(*)` pass over every table.
    public func storageByteEstimates(sampleRows: Int = 500,
                                     rowCounts: [String: Int]? = nil) async throws -> [String: Int] {
        try syncRead { db in
            var out: [String: Int] = [:]
            for (key, table) in Self.rawTableKeys {
                let known = rowCounts?[key]
                guard let rows = known ?? (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")),
                      rows > 0
                else { continue }
                let cols = try? Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                guard let cols, !cols.isEmpty else { continue }
                // Table and column names come from the schema, never user input, so interpolation is safe.
                // `typeof()` at runtime, not the declared type, and byte length via CAST rather than LENGTH: SQLite
                // is dynamically typed (an INTEGER column can hold text) and LENGTH on text counts characters.
                let terms = cols.compactMap { c -> String? in
                    guard let name = c["name"] as String? else { return nil }
                    let q = "\"\(name)\""
                    return "(CASE WHEN \(q) IS NULL THEN 0 "
                        + "WHEN typeof(\(q)) IN ('text','blob') THEN length(CAST(\(q) AS BLOB)) "
                        + "ELSE 8 END)"
                }
                guard !terms.isEmpty else { continue }
                let sql = "SELECT AVG(n) FROM (SELECT (\(terms.joined(separator: " + "))) AS n "
                    // Clamped: SQLite reads a negative limit as no limit, which would full-scan the tables sampling avoids.
                    + "FROM \(table) LIMIT \(max(1, sampleRows)))"
                if let mean = try? Double.fetchOne(db, sql: sql), mean.isFinite, mean >= 0 {
                    out[key] = Int((mean * Double(rows)).rounded())
                }
            }
            return out
        }
    }

    /// The decoded stream tables and the key each reports under. The keys are Android's, verbatim.
    static let rawTableKeys: [(String, String)] = [
        ("hr", "hrSample"), ("rr", "rrInterval"), ("events", "event"), ("battery", "battery"),
        ("spo2", "spo2Sample"), ("skinTemp", "skinTempSample"), ("resp", "respSample"),
        ("gravity", "gravitySample"), ("steps", "stepSample"), ("ppgHr", "ppgHrSample"),
        ("sleepState", "sleepStateSample"), ("ppgWaveform", "ppgWaveformSample"),
        ("v18Aux", "v18AuxSample"),
    ]

    /// The raw outbox alone: batch count and total byteSize, without the 13-table `COUNT(*)` sweep `storageStats()` does.
    public func rawOutboxStats() async throws -> (batches: Int, bytes: Int) {
        try syncRead { try Self.rawOutbox($0) }
    }

    /// The outbox pair against an open database. Takes `db` rather than calling the other reader because
    /// `syncRead` is `dbWriter.read` and a nested read deadlocks.
    private static func rawOutbox(_ db: Database) throws -> (batches: Int, bytes: Int) {
        let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
        let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
        return (batches, bytes)
    }

    /// Aggregate storage footprint: total decoded rows, raw batch count, total raw byteSize.
    public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try syncRead { db in
            // The complete set of accumulating decoded raw streams comes from `rawTableKeys`, summed by iteration
            // (a hand-written sum under-reported). Android's `storageRowCounts` is still kept in step by hand.
            // Table names are compile-time constants, so interpolation is safe.
            var decoded = 0
            for (_, t) in Self.rawTableKeys {
                decoded += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0
            }
            let outbox = try Self.rawOutbox(db)
            return (decoded, outbox.batches, outbox.bytes)
        }
    }
}
