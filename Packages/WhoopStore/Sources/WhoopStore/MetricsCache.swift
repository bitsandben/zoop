import Foundation
import GRDB

// MARK: - Offline cache of computed metrics
// A local cache so History = union(phone-collected raw streams, derived metrics). `DailyMetric` and `CachedSleepSession`
// are populated by sync/recompute and read by `MetricsRepository` for the view layer.

/// One cached sleep session. Natural key (deviceId, startTs). `stagesJSON` is the verbatim JSON array of stage
/// segments ([{start,end,stage}]), stored as a string so the cache stays agnostic about the staging shape.
public struct CachedSleepSession: Equatable, Codable {
    public let startTs: Int          // unix seconds
    public let endTs: Int            // unix seconds
    public let efficiency: Double?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let stagesJSON: String?
    /// True once the user has hand-corrected this session's bounds; recompute/import upserts then preserve its
    /// `endTs`/`stagesJSON` (see `upsertSleepSessions`).
    public let userEdited: Bool
    /// The user's hand-corrected sleep ONSET, or nil. `startTs` remains the immutable detected key; display and
    /// re-staging use `effectiveStartTs`.
    public let startTsAdjusted: Int?
    /// The onset to display / stage from: the user's correction if present, else the detected `startTs`.
    public var effectiveStartTs: Int { startTsAdjusted ?? startTs }
    /// True when this night was staged on SPARSE motion coverage (`SleepStager.isGravitySparse`), which can
    /// UNDER-detect (a real ~8h night collapsing to ~1h). The UI captions "sleep may be incomplete" from it. nil for
    /// imported nights and pre-migration rows (unknown, not flagged); set per session to the DAY's value.
    public let stagingSparse: Bool?
    /// Which device's row this is, when the read that produced it knew. Optional and defaulted: many call sites build
    /// sessions by hand and don't know it, and claiming a device a session was never read from would be worse than
    /// absent. Readers treat nil as "ask the store", so provenance is a shortcut, never a wrong answer. Missing keys
    /// decode to nil.
    ///
    /// The WRITE never reads it: `upsertSleepSessions` takes its device as a separate argument, so this cannot route a
    /// row into another device's namespace.
    public let deviceId: String?
    public init(startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?,
                avgHrv: Double?, stagesJSON: String?, userEdited: Bool = false,
                startTsAdjusted: Int? = nil, stagingSparse: Bool? = nil,
                deviceId: String? = nil) {
        self.startTs = startTs; self.endTs = endTs
        self.efficiency = efficiency; self.restingHr = restingHr
        self.avgHrv = avgHrv; self.stagesJSON = stagesJSON
        self.userEdited = userEdited
        self.startTsAdjusted = startTsAdjusted
        self.deviceId = deviceId
        self.stagingSparse = stagingSparse
    }

    /// A copy re-keyed to `newStartTs`, every other field (including the stage segments) unchanged. Used to set the
    /// session PK to the rounded 0x49 onset (the stable per-night anchor).
    public func withStartTs(_ newStartTs: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: newStartTs, endTs: endTs, efficiency: efficiency, restingHr: restingHr,
                           avgHrv: avgHrv, stagesJSON: stagesJSON, userEdited: userEdited,
                           startTsAdjusted: startTsAdjusted, stagingSparse: stagingSparse,
                           // Carried: a re-keyed session is the same row from the same device.
                           deviceId: deviceId)
    }
}

/// One cached daily-metrics row. Natural key (deviceId, day).
public struct DailyMetric: Equatable, Codable {
    public let day: String           // YYYY-MM-DD
    public let totalSleepMin: Double?
    public let efficiency: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let lightMin: Double?
    public let disturbances: Int?
    public let restingHr: Int?
    public let avgHrv: Double?
    public let recovery: Double?
    public let strain: Double?
    public let exerciseCount: Int?
    // In-sleep signal aggregates (v7 columns). All nullable.
    public let spo2Pct: Double?        // mean SpO2 (%) during sleep
    public let skinTempDevC: Double?   // skin-temperature deviation (°C) from baseline
    public let respRateBpm: Double?    // mean respiration rate (breaths/min) during sleep
    // On-device daily activity totals (v11 columns, APPROXIMATE estimates). Both nullable.
    public let steps: Int?             // daily/file step total from the cumulative @57 counter or activity import
    public let activeKcalEst: Double?  // whole-day HR-only calorie estimate (kcal)
    // WHOOP 4.0 raw SpO2 PPG ADC means over detected sleep (v23 columns). RAW red/IR optical channels, NOT a calibrated
    // blood-oxygen % (that needs WHOOP's proprietary curve). Nullable and on-device only.
    public let spo2Red: Int?           // mean raw red PPG ADC during detected sleep
    public let spo2Ir: Int?            // mean raw IR PPG ADC during detected sleep
    /// Nightly SDNN (ms): the Task Force 5-min SDNN INDEX (mean of per-5-min-segment SDNN, ddof=1), the broad-variability
    /// twin of `avgHrv` (RMSSD). The 5-min index is stored rather than whole-night SD, which is dominated by slow HR drift
    /// across stages (reads 2-3x high) and is not comparable to a watch's SDNN. v31 column, nullable: on-device nights use
    /// `HRVAnalyzer.sdnnIndex`; Apple rows mirror their own SDNN; Oura/other imports stay nil.
    public let avgSdnn: Double?
    /// Nightly ABSOLUTE skin temperature (C): the wear-gated mean over detected sleep that `skinTempDevC` is derived FROM
    /// (a febrile night reads as a small delta but a clear fever in absolute terms). v40 column, nullable: earlier nights
    /// stay nil until a re-score. Unlike `skinTempDevC`, which is bimodal (CSV/Apple imports write an absolute wrist C into it;
    /// `SkinTempDisplay.isAbsoluteSkinTemp` separates them by magnitude), this is always absolute and only the strap pipeline
    /// writes it.
    public let skinTempC: Double?
    /// True when every session that night was staged from heart rate alone.
    public let sleepHrOnly: Bool?
    public init(day: String, totalSleepMin: Double?, efficiency: Double?, deepMin: Double?,
                remMin: Double?, lightMin: Double?, disturbances: Int?, restingHr: Int?,
                avgHrv: Double?, recovery: Double?, strain: Double?, exerciseCount: Int?,
                spo2Pct: Double? = nil, skinTempDevC: Double? = nil, respRateBpm: Double? = nil,
                steps: Int? = nil, activeKcalEst: Double? = nil,
                spo2Red: Int? = nil, spo2Ir: Int? = nil, avgSdnn: Double? = nil,
                skinTempC: Double? = nil,
                sleepHrOnly: Bool? = nil) {
        self.day = day; self.totalSleepMin = totalSleepMin; self.efficiency = efficiency
        self.deepMin = deepMin; self.remMin = remMin; self.lightMin = lightMin
        self.disturbances = disturbances; self.restingHr = restingHr; self.avgHrv = avgHrv
        self.recovery = recovery; self.strain = strain; self.exerciseCount = exerciseCount
        self.spo2Pct = spo2Pct; self.skinTempDevC = skinTempDevC; self.respRateBpm = respRateBpm
        self.steps = steps; self.activeKcalEst = activeKcalEst
        self.spo2Red = spo2Red; self.spo2Ir = spo2Ir; self.avgSdnn = avgSdnn
        self.skinTempC = skinTempC
        self.sleepHrOnly = sleepHrOnly
    }

    /// The freshest STRICTLY-PRIOR day carrying at least one overnight vital (HRV / resting HR / respiratory), or nil.
    /// Independent of `recovery`, so a night with null recovery but real HRV/RHR is still a source. It only supplies the
    /// FALLBACK: call sites read today-first (`displayDay?.field ?? vitalsDay?.field`). `days` is oldest to newest.
    ///
    /// `todayKey` must be the future-clock-safe "today" key; the `$0.day < todayKey` bound (yyyy-MM-dd compares
    /// lexicographically) keeps today's still-forming row and any bad-clock future row out.
    public nonisolated static func lastVitalsDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { ($0.avgHrv != nil || $0.restingHr != nil || $0.respRateBpm != nil) && $0.day < todayKey })
    }

    /// PER-FIELD twin of `lastVitalsDay` for SpO2: the freshest strictly-prior day with a non-nil `spo2Pct`. The vitals
    /// predicate can land on a row whose `spo2Pct` is nil (the on-device engine banks only raw `spo2Red`/`spo2Ir`) while an
    /// older imported row holds a real reading. Same future-clock guard; `days` is oldest to newest.
    public nonisolated static func lastSpo2Day(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.spo2Pct != nil && $0.day < todayKey })
    }

    /// PER-FIELD twin of `lastVitalsDay` for skin-temperature deviation. See `lastSpo2Day`.
    public nonisolated static func lastSkinTempDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.skinTempDevC != nil && $0.day < todayKey })
    }

    /// The freshest strictly-prior row carrying EITHER skin-temp number, so a surface can lead with the absolute and fall
    /// back to the deviation from ONE night. Selecting on (X or Y) is safe here because the caller reads both fields off
    /// that same row and lets `SkinTempDisplay.leadReading` pick, so an absolute is never paired with another night's deviation.
    public nonisolated static func lastSkinTempReadingDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { ($0.skinTempC != nil || $0.skinTempDevC != nil) && $0.day < todayKey })
    }

    /// PER-FIELD HRV carry: the freshest strictly-prior row that actually holds an `avgHrv`. `lastVitalsDay` ORs across
    /// HRV / resting HR / respiratory, so it can land on a respiratory-only row and render "-" beside a tile showing a real
    /// number from another row.
    ///
    /// Deliberately not staleness-bounded (unlike `Repository.lastRespDay`): an old HRV/RHR carry is disclosed, since call
    /// sites stamp the row's date and `carriedCaption` relabels a weeks-old one. Same future-clock guard; `days` is oldest
    /// to newest.
    public nonisolated static func lastHrvDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.avgHrv != nil && $0.day < todayKey })
    }

    /// PER-FIELD resting-HR carry: twin of `lastHrvDay`, same OR-predicate cause and same unbounded-by-design carry.
    public nonisolated static func lastRestingHrDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        days.last(where: { $0.restingHr != nil && $0.day < todayKey })
    }
}

extension WhoopStore {

    // MARK: - Upserts (idempotent by natural key; latest server value wins on conflict)

    /// Upserts cached sleep sessions. Natural key (deviceId, startTs). Returns rows changed.
    ///
    /// A non-user-edited candidate whose stage timeline is LESS complete than what is stored for the same key is dropped
    /// whole: a later, shorter decode (reconnect, resumed drain) must not overwrite a fuller one, or `stagesJSON` and
    /// `efficiency`/`endTs` would disagree. `HypnogramCoverage`'s 0/1/2 richness rank (none / holed / covers-its-span) is
    /// the scale `SleepMerge` uses for display; applying it at WRITE time protects every caller.
    @discardableResult
    public func upsertSleepSessions(_ sessions: [CachedSleepSession], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for s in sessions {
                if !s.userEdited, let existing = try Self.storedSleepSession(db, deviceId: deviceId, startTs: s.startTs),
                   !existing.userEdited {
                    let candidate = CachedSleepSession(startTs: s.startTs, endTs: s.endTs, efficiency: nil,
                                                       restingHr: nil, avgHrv: nil, stagesJSON: s.stagesJSON)
                    if SleepMerge.richness(candidate) < SleepMerge.richness(existing) {
                        continue   // a less-complete re-serve of this night must never clobber the stored one
                    }
                }
                try db.execute(sql: """
                    INSERT INTO sleepSession
                        (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                         userEdited, startTsAdjusted, stagingSparse)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        -- A user-corrected night keeps its hand-set bed/wake times and stage breakdown;
                        -- a recompute/import refresh (this path) updates only the derived vitals. The
                        -- `userEdited` flag is preserved, never cleared here, so a later strap re-sync
                        -- can't revert a correction (the dedicated edit path is `applySleepEdit`).
                        endTs = CASE WHEN sleepSession.userEdited THEN sleepSession.endTs ELSE excluded.endTs END,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = CASE WHEN sleepSession.userEdited THEN sleepSession.stagesJSON ELSE excluded.stagesJSON END,
                        startTsAdjusted = CASE WHEN sleepSession.userEdited THEN sleepSession.startTsAdjusted ELSE excluded.startTsAdjusted END,
                        userEdited = sleepSession.userEdited,
                        -- Derived from the day's motion coverage, so a recompute always refreshes it.
                        stagingSparse = excluded.stagingSparse
                    """, arguments: [deviceId, s.startTs, s.endTs, s.efficiency,
                                     s.restingHr, s.avgHrv, s.stagesJSON, s.userEdited, s.startTsAdjusted,
                                     s.stagingSparse])
                n += db.changesCount
            }
            return n
        }
    }

    /// The stored row at (deviceId, startTs), or nil: the completeness check before an overwrite. Only the fields that
    /// check needs are read.
    private static func storedSleepSession(_ db: Database, deviceId: String, startTs: Int) throws -> CachedSleepSession? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT endTs, stagesJSON, userEdited FROM sleepSession WHERE deviceId = ? AND startTs = ?
            """, arguments: [deviceId, startTs]) else { return nil }
        return CachedSleepSession(startTs: startTs, endTs: row["endTs"], efficiency: nil, restingHr: nil,
                                  avgHrv: nil, stagesJSON: row["stagesJSON"], userEdited: row["userEdited"],
                                  deviceId: deviceId)
    }

    /// Hand-corrects a sleep session's bed (onset) and/or wake (end) time and sets `userEdited = 1`, so later
    /// recompute/import upserts preserve the bounds. Keyed by the immutable detected key (deviceId, `detectedStartTs`); the
    /// corrected onset goes in `startTsAdjusted`. A non-nil `stagesJSON` replaces the stored breakdown (the caller
    /// re-derives it); nil keeps it. Returns rows changed (0 if no such session).
    @discardableResult
    public func applySleepEdit(deviceId: String, detectedStartTs: Int, newStartTs: Int, newEndTs: Int,
                               stagesJSON: String? = nil) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET startTsAdjusted = ?, endTs = ?, stagesJSON = COALESCE(?, stagesJSON), userEdited = 1
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [newStartTs, newEndTs, stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    /// Deletes ONE sleep session (the delete half of `applySleepEdit`), so the day recomputes without a misread night.
    /// Returns rows deleted. The durable "user deleted this night" tombstone lives in the Repository layer
    /// (`dismissedSleepSpans`); this only removes the row.
    @discardableResult
    public func deleteSleepSession(deviceId: String, startTs: Int) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                           arguments: [deviceId, startTs])
            return db.changesCount
        }
    }

    /// Manually ADDS a sleep session the detector missed, typically a daytime nap. Inserts a NEW row at the chosen
    /// `startTs` flagged `userEdited = 1`, so the post-sync overlap guard preserves it. `startTsAdjusted` stays nil (the
    /// chosen onset IS the onset). `stagesJSON` is staged by the caller from raw (or a single "awake" block until raw lands).
    ///
    /// `ON CONFLICT(deviceId, startTs) DO NOTHING` keeps it purely additive. Returns rows inserted (0 if one exists).
    @discardableResult
    public func insertManualSleepSession(deviceId: String, startTs: Int, endTs: Int,
                                         efficiency: Double?, stagesJSON: String?) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                     userEdited, startTsAdjusted)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, 1, NULL)
                ON CONFLICT(deviceId, startTs) DO NOTHING
                """, arguments: [deviceId, startTs, endTs, efficiency, stagesJSON])
            return db.changesCount
        }
    }

    /// Replaces ONLY the stage breakdown of an already user-edited night, leaving the corrected bounds and `userEdited`
    /// untouched. The post-sync self-heal calls it when raw streams finally arrive for a night edited BEFORE they did (its
    /// stages were fabricated by `SleepWindowReclip`). Scoped to `userEdited = 1` rows. Returns rows changed.
    @discardableResult
    public func updateSleepStages(deviceId: String, detectedStartTs: Int, stagesJSON: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET stagesJSON = ?
                WHERE deviceId = ? AND startTs = ? AND userEdited = 1
                """, arguments: [stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    // MARK: - Per-epoch sleep analytics (v18: motionJSON / sleepStateJSON)
    //
    // Banked on the EXISTING sleepSession row beside `stagesJSON`, not on CachedSleepSession: they are written/read through
    // targeted methods so the common read path stays lean and recompute/import/edit upserts (which don't name these
    // columns) preserve them. An absent signal is SQL NULL and reads back as `nil`, never a fabricated zero array.

    /// Persists the SleepStager's per-epoch motion magnitudes for one session as a compact JSON array on the same 30 s
    /// grid as `stagesJSON`, keyed by (deviceId, startTs). An EMPTY array clears the column to NULL. Returns rows changed.
    @discardableResult
    public func persistSessionMotion(deviceId: String, sessionStart: Int, motionEpochs: [Double]) async throws -> Int {
        let json = motionEpochs.isEmpty ? nil : Self.encodeDoubleArray(motionEpochs)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession SET motionJSON = ?
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    /// The persisted per-epoch motion magnitudes, or nil when NULL / no such session / unparseable. Keyed by detected startTs.
    public func sessionMotion(deviceId: String, sessionStart: Int) async throws -> [Double]? {
        try syncRead { db in
            let json = try String.fetchOne(db, sql: """
                SELECT motionJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, sessionStart])
            return json.flatMap(Self.decodeDoubleArray)
        }
    }

    /// Persists the decoded v18 band sleep_state per epoch (`(sb>>4)&3`) as a compact JSON array of ints, keyed by
    /// (deviceId, startTs). EMPTY clears to NULL. Returns rows changed.
    @discardableResult
    public func persistSessionSleepState(deviceId: String, sessionStart: Int, states: [Int]) async throws -> Int {
        let json = states.isEmpty ? nil : Self.encodeIntArray(states)
        return try syncWrite { db in
            try db.execute(sql: """
                UPDATE sleepSession SET sleepStateJSON = ?
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    /// The persisted band sleep_state per epoch, or nil when unset / unparseable. Keyed by detected startTs.
    public func sessionSleepState(deviceId: String, sessionStart: Int) async throws -> [Int]? {
        try syncRead { db in
            let json = try String.fetchOne(db, sql: """
                SELECT sleepStateJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?
                """, arguments: [deviceId, sessionStart])
            return json.flatMap(Self.decodeIntArray)
        }
    }

    /// One device's session BOUNDS in a window, as `startTs -> endTs`, in a single lean read. Deliberately not
    /// `sleepSessions(...)`, which also pulls the `stagesJSON` blob. (deviceId, startTs) is the PK, so the dictionary loses
    /// nothing. Unpaged on purpose: the window bounds the result and a page limit could silently drop rows.
    public func sleepSessionBounds(deviceId: String, from: Int, to: Int) async throws -> [Int: Int] {
        try syncRead { db in
            var out: [Int: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT startTs, endTs FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                """, arguments: [deviceId, from, to])
            for row in rows { out[row["startTs"]] = row["endTs"] }
            return out
        }
    }

    /// Batched `sessionMotion`: the persisted motion series for each of `sessionStarts` that HAS one, in a single query,
    /// keyed by startTs. NULL/absent/empty starts are omitted. The `IN (...)` list is de-duplicated and chunked below
    /// SQLite's bound-parameter ceiling.
    public func sessionMotions(deviceId: String, sessionStarts: [Int]) async throws -> [Int: [Double]] {
        guard !sessionStarts.isEmpty else { return [:] }
        return try syncRead { db in
            var out: [Int: [Double]] = [:]
            let uniq = Array(Set(sessionStarts))
            var lo = 0
            while lo < uniq.count {
                let chunk = Array(uniq[lo ..< min(lo + Self.inClauseChunk, uniq.count)])
                lo += Self.inClauseChunk
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [deviceId]
                args.append(contentsOf: chunk)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT startTs, motionJSON FROM sleepSession
                    WHERE deviceId = ? AND startTs IN (\(placeholders)) AND motionJSON IS NOT NULL
                    """, arguments: StatementArguments(args))
                for row in rows {
                    let startTs: Int = row["startTs"]
                    guard let json: String = row["motionJSON"],
                          let arr = Self.decodeDoubleArray(json), !arr.isEmpty else { continue }
                    out[startTs] = arr
                }
            }
            return out
        }
    }

    /// Batched `sessionSleepState` over a RANGE: every session in `[from, to]` (by startTs) with banked band sleep_state, in
    /// one query, keyed by startTs. NULL/absent columns are omitted.
    public func sessionSleepStates(deviceId: String, from: Int, to: Int) async throws -> [Int: [Int]] {
        try syncRead { db in
            var out: [Int: [Int]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT startTs, sleepStateJSON FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ? AND sleepStateJSON IS NOT NULL
                """, arguments: [deviceId, from, to])
            for row in rows {
                let startTs: Int = row["startTs"]
                guard let json: String = row["sleepStateJSON"],
                      let arr = Self.decodeIntArray(json), !arr.isEmpty else { continue }
                out[startTs] = arr
            }
            return out
        }
    }

    /// SQLite caps bound `?` parameters per statement (999 on the system SQLite iOS ships). Chunk `IN (...)` lists under
    /// it, leaving room for the leading `deviceId` bind.
    static let inClauseChunk = 900

    /// Compact JSON encoders/decoders for the per-epoch series: a bare `[Double]`/`[Int]` array, no pretty-printing, so the
    /// column stays small and round-trips byte-for-byte with Android.
    static func encodeDoubleArray(_ xs: [Double]) -> String? {
        (try? JSONEncoder().encode(xs)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func decodeDoubleArray(_ json: String) -> [Double]? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
    }
    static func encodeIntArray(_ xs: [Int]) -> String? {
        (try? JSONEncoder().encode(xs)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func decodeIntArray(_ json: String) -> [Int]? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode([Int].self, from: $0) }
    }

    /// Upserts cached daily metrics. Natural key (deviceId, day). Returns rows changed.
    @discardableResult
    public func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String) async throws -> Int {
        try syncWrite { db in
            try Self.upsertDailyMetrics(days, deviceId: deviceId, in: db)
        }
    }

    /// Transaction-sharing primitive used by computed-score persistence, so cache writes and score+provenance writes cannot drift.
    static func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String, in db: Database) throws -> Int {
        var n = 0
        for d in days {
            try db.execute(sql: """
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                     disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                     spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                     spo2Red, spo2Ir, avgSdnn, skinTempC, sleepHrOnly)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day) DO UPDATE SET
                    totalSleepMin = excluded.totalSleepMin,
                    efficiency = excluded.efficiency,
                    deepMin = excluded.deepMin,
                    remMin = excluded.remMin,
                    lightMin = excluded.lightMin,
                    disturbances = excluded.disturbances,
                    restingHr = excluded.restingHr,
                    avgHrv = excluded.avgHrv,
                    recovery = excluded.recovery,
                    strain = excluded.strain,
                    exerciseCount = excluded.exerciseCount,
                    spo2Pct = excluded.spo2Pct,
                    skinTempDevC = excluded.skinTempDevC,
                    respRateBpm = excluded.respRateBpm,
                    steps = excluded.steps,
                    activeKcalEst = excluded.activeKcalEst,
                    spo2Red = excluded.spo2Red,
                    spo2Ir = excluded.spo2Ir,
                    avgSdnn = excluded.avgSdnn,
                    skinTempC = excluded.skinTempC,
                    sleepHrOnly = excluded.sleepHrOnly
                """, arguments: [deviceId, d.day, d.totalSleepMin, d.efficiency, d.deepMin,
                                 d.remMin, d.lightMin, d.disturbances, d.restingHr, d.avgHrv,
                                 d.recovery, d.strain, d.exerciseCount,
                                 d.spo2Pct, d.skinTempDevC, d.respRateBpm,
                                 d.steps, d.activeKcalEst,
                                 d.spo2Red, d.spo2Ir, d.avgSdnn, d.skinTempC, d.sleepHrOnly])
            n += db.changesCount
        }
        return n
    }

    /// Deletes a source's cached daily rows whose day-key is in [from, to] (inclusive; yyyy-MM-dd lexicographic is
    /// chronological). Used by the local-day re-bucketing migration to drop computed ("-zoop") UTC-keyed rows before
    /// re-upserting local-keyed ones. Source-scoped: imported rows are untouched. Returns rows deleted.
    @discardableResult
    public func deleteDailyMetrics(deviceId: String, from: String, to: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, from, to])
            return db.changesCount
        }
    }

    /// FILL-ONLY write of `skinTempC` for nights the backfill re-derived an absolute for: a single-column UPDATE of an
    /// existing row, only when that column is currently NULL. Never an upsert (it must not touch `skinTempDevC` or clobber a
    /// concurrent scoring write). Returns rows filled.
    @discardableResult
    public func fillSkinTempC(deviceId: String, day: String, skinTempC: Double) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE dailyMetric
                SET skinTempC = ?
                WHERE deviceId = ? AND day = ? AND skinTempC IS NULL
                """, arguments: [skinTempC, deviceId, day])
            return db.changesCount
        }
    }

    // MARK: - Reads

    /// Cached sleep sessions overlapping [from, to] (by startTs), oldest first.
    public func sleepSessions(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [CachedSleepSession] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
                       startTsAdjusted, stagingSparse FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    CachedSleepSession(startTs: $0["startTs"], endTs: $0["endTs"],
                                       efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                                       avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"],
                                       userEdited: $0["userEdited"], startTsAdjusted: $0["startTsAdjusted"],
                                       stagingSparse: $0["stagingSparse"],
                                       // The read knows the device it queried, so every block carries it.
                                       deviceId: deviceId)
                }
        }
    }

    /// Cached daily metrics for days in [from, to] (lexicographic YYYY-MM-DD compare), oldest first.
    public func dailyMetrics(deviceId: String, from: String, to: String) async throws -> [DailyMetric] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                       restingHr, avgHrv, recovery, strain, exerciseCount,
                       spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                       spo2Red, spo2Ir, avgSdnn, skinTempC, sleepHrOnly FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, from, to])
                .map {
                    DailyMetric(day: $0["day"], totalSleepMin: $0["totalSleepMin"],
                                efficiency: $0["efficiency"], deepMin: $0["deepMin"],
                                remMin: $0["remMin"], lightMin: $0["lightMin"],
                                disturbances: $0["disturbances"], restingHr: $0["restingHr"],
                                avgHrv: $0["avgHrv"], recovery: $0["recovery"],
                                strain: $0["strain"], exerciseCount: $0["exerciseCount"],
                                spo2Pct: $0["spo2Pct"], skinTempDevC: $0["skinTempDevC"],
                                respRateBpm: $0["respRateBpm"],
                                steps: $0["steps"], activeKcalEst: $0["activeKcalEst"],
                                spo2Red: $0["spo2Red"], spo2Ir: $0["spo2Ir"], avgSdnn: $0["avgSdnn"],
                                skinTempC: $0["skinTempC"],
                                sleepHrOnly: $0["sleepHrOnly"])
                }
        }
    }
}
