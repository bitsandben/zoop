import Foundation
import GRDB
import WhoopProtocol

private struct RRBatchSecond: Hashable {
    let ts: Int
    let transport: Int
}

extension WhoopStore {
    /// Deterministic JSON for an event payload: sorted keys so the same payload always serializes
    /// byte-identically (natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Packs a decoded v26 PPG waveform's samples as little-endian i16 in one compact BLOB per
    /// (deviceId, ts) row. Any sample count is handled; values are truncated to Int16, matching the wire format.
    static func packPpgSamples(_ samples: [Int]) -> Data {
        var buf = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(truncatingIfNeeded: s)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return buf
    }

    /// Inverse of `packPpgSamples`. A trailing odd byte (corrupt blob) is dropped; a read never crashes on a malformed row.
    static func unpackPpgSamples(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            out.append(Int(Int16(bitPattern: u)))
            i += 2
        }
        return out
    }

    /// Packs the raw-IMU i16 columns (the 6x100 ax...gz) to a little-endian BLOB, same encoding as
    /// `packPpgSamples`. Byte-identical to Kotlin `packImuColumns`.
    static func packImuColumns(_ cols: [Int16]) -> Data {
        var buf = Data(capacity: cols.count * 2)
        for v in cols { buf.append(UInt8(truncatingIfNeeded: v)); buf.append(UInt8(truncatingIfNeeded: v >> 8)) }
        return buf
    }

    /// Inverse of `packImuColumns`; a trailing odd byte is dropped so a malformed row never crashes a read.
    static func unpackImuColumns(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out = [Int16](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { out.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))); i += 2 }
        return out
    }

    /// Rolling retention for the v27 PPG waveform table. It carries the largest per-row cost of any decoded
    /// stream (~120 B against ~30 B for a scalar row), but it is not the fastest-growing table:
    /// `rrInterval` banks ~100,000 rows/day against ~28,800 here, so this bounds the worst row, not the bulk.
    ///
    /// A newest-N-rows cap, deliberately not a time-window drop. These rows are kept so a better
    /// estimator, HRV-from-PPG or a waveform viewer can later run over the original samples (see the
    /// `ppgWaveformSample` migration note in `Database.swift`). An age cutoff would empty the table for a
    /// sporadic wearer, whose v26 seconds are spread thin over months. Newest-N bounds the bytes while
    /// leaving a full working set, the same trade as `v18AuxRetentionRows`.
    ///
    /// 604,800 = 7 x 86,400, about 70 MB per device (48 B packed blob plus row and index overhead). At
    /// ~28,800 rows/day of typical wear that holds roughly three weeks. Relaxing a cap later is cheaper
    /// than imposing one on a user with a year of history.
    public static let ppgWaveformRetentionRows = 604_800

    /// Rows to bank before sweeping `ppgWaveformSample` again, amortising the sweep (which walks up to
    /// `ppgWaveformRetentionRows` index entries) at the cost of a ~1 MB overshoot.
    ///
    /// The counter is in-memory and per store instance, and the sweep is the only retention enforcement
    /// on this table, so a store that never banks this many rows in one process lifetime never sweeps.
    /// Normal sessions cross it easily (one night's offload banks ~28,800 rows); only a store fed short
    /// bursts between app kills can drift above the cap. `v18AuxPruneEveryRows` has the same property.
    public static let ppgWaveformPruneEveryRows = 10_000

    /// Rolling retention for the v18 aux-slot table (v31). Nothing reads these rows yet, so a cap is far
    /// cheaper to relax later than to impose once users have a year of history. Without it this is the one
    /// genuinely new source of row growth in v31.
    ///
    /// 604,800 = 7 x 86,400, a week of strap-seconds, about 50 MB per device (~85 B/row), newest-first.
    /// v18 seconds are a fraction of a day, so the wall-clock span is longer. Slots older than the window
    /// are gone: a census needs weeks of records, not years.
    public static let v18AuxRetentionRows = 604_800

    /// Rows to bank before running the retention sweep again, which walks up to `v18AuxRetentionRows`
    /// index entries. The table may sit this many rows above the cap in exchange (well under 1 MB).
    public static let v18AuxPruneEveryRows = 10_000

    /// Inserts or updates a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows actually inserted
    /// per stream (0 for rows that already existed).
    ///
    /// The `synced` column (migration v5) is not written; it is unused and kept to avoid a DROP COLUMN migration.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await insert(streams, deviceId: deviceId,
                         v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                         v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                         ppgWaveformRetentionRows: WhoopStore.ppgWaveformRetentionRows,
                         ppgWaveformPruneEveryRows: WhoopStore.ppgWaveformPruneEveryRows)
    }

    /// `insert(_:deviceId:)` with the v31 aux-table cap explicit. A separate internal overload because
    /// `StoreWriting` / `BackfillStoreWriting` require the exact `insert(_:deviceId:)` signature, which a
    /// defaulted parameter would not satisfy. Lets a test prove the rolling delete with a small cap.
    ///
    /// The two v18-aux caps are required (eleven call sites pass them); the two ppg-waveform caps are defaulted.
    @discardableResult
    func insert(_ streams: Streams, deviceId: String, v18AuxRetentionRows: Int,
                v18AuxPruneEveryRows: Int,
                ppgWaveformRetentionRows: Int = WhoopStore.ppgWaveformRetentionRows,
                ppgWaveformPruneEveryRows: Int = WhoopStore.ppgWaveformPruneEveryRows) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Banked rows, accumulated across batches so the sweep does not run on every one.
        var v18Written = 0
        var ppgWaveformWritten = 0
        let result: (Int, Int, Int, Int, Int, Int, Int, Int) = try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            // One prepared statement per table instead of recompiling per row: this is the hottest write path
            // (every Collector.flush and Backfiller chunk over potentially millions of rows). Each loop is
            // guarded so empty streams compile nothing.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                    """)
                // v24: equal (ts, rrMs) beats are numbered 0, 1, ... within the batch so both survive; distinct
                // beats keep seq 0 and their own key, so re-syncing identical rows stays idempotent. The nested dict
                // is the (ts, rrMs) occurrence counter.
                //
                // v30: `ord` is the beat's position among all beats sharing this ts in the batch (emission order).
                // `seq` cannot express it. Not in the key and never changes which rows survive; it lets reads return
                // beats in heart order rather than by value, which biases RMSSD down. Batch-local: a second split
                // across two live flushes restarts at 0 and DO NOTHING keeps the first row. The historical path
                // delivers a second atomically.
                //
                // `srcChannel` carries Oura optical channels or WHOOP 5 transport provenance; WHOOP 4 and legacy rows
                // stay NULL. Like `ord` it is outside the key: keying on the label would store two observations of
                // one beat, the double-count this fixes. A newly observed canonical WHOOP 5 transport can promote the
                // existing source and order below; the read filter separates sources across the requested interval.
                let promote = try db.cachedStatement(sql: """
                    UPDATE rrInterval SET srcChannel = :source, ord = :ord
                    WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
                    AND ((:source = 5 AND (srcChannel IS NULL OR srcChannel IN (6, 7)))
                      OR (:source = 7 AND (srcChannel IS NULL OR srcChannel = 6)))
                    """)
                let promoteWhoop4History = try db.cachedStatement(sql: """
                    UPDATE rrInterval SET srcChannel = :source, ord = :ord
                    WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
                    AND :source = 8 AND srcChannel IS NULL
                    """)
                var seqByTsRr: [RRBatchSecond: [Int: Int]] = [:]
                var ordByTs: [RRBatchSecond: Int] = [:]
                for r in streams.rr {
                    // A second's native historical array is atomic: a standard packet in the same batch must not change
                    // its order or the occurrence number of an equal interval.
                    let key = RRBatchSecond(ts: r.ts,
                        transport: r.srcChannel?.isWhoop5Transport == true ? r.srcChannel!.rawValue : 0)
                    let seq = seqByTsRr[key]?[r.rrMs] ?? 0
                    seqByTsRr[key, default: [:]][r.rrMs] = seq + 1
                    let ord = ordByTs[key] ?? 0
                    ordByTs[key] = ord + 1
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs, seq, ord,
                                                 r.srcChannel?.rawValue])
                    let inserted = db.changesCount
                    rr += inserted
                    if inserted == 0, let source = r.srcChannel,
                       source == .whoop5Historical || source == .whoop5Standard {
                        // Canonical precedence is history > standard > native/legacy. The winning observation supplies its
                        // order; values, keys and Oura labels stay intact. Cache fingerprints witness both canonical-source counts.
                        try promote.execute(arguments: ["source": source.rawValue, "ord": ord,
                            "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
                    }
                    if inserted == 0, r.srcChannel == .whoop4Historical {
                        try promoteWhoop4History.execute(arguments: [
                            "source": RRSourceChannel.whoop4Historical.rawValue, "ord": ord,
                            "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
                    }
                }
                // Mark the strap's 500 ms fill beats in this batch's window. The batch's heart rate was written
                // above, so the same-second rate the rule reads is on disk. Only a batch with a 500 ms WHOOP 5 beat
                // pays for the statement.
                let fillTs = streams.rr.filter {
                    $0.rrMs == 500 && ($0.srcChannel == .whoop5Historical || $0.srcChannel == .whoop5Standard)
                }.map(\.ts)
                if let fromTs = fillTs.min(), let toTs = fillTs.max() {
                    try db.execute(sql: WhoopStore.whoop5RrFillFlagSQL,
                                   arguments: ["deviceId": deviceId, "fromTs": fromTs, "toTs": toTs])
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            // `aux1Raw`/`aux2Raw` (v31) are auxiliary thermal channels from the same v18 record. nil (WHOOP 4.0,
            // or a byte that failed the decoder's thermal gate) stores SQL NULL.
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw, aux1Raw, aux2Raw) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw, s.aux1Raw, s.aux2Raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            // `dynAccel` (v31) is the strap's own gravity-removed motion magnitude, stored beside the vector and
            // read by nothing. nil (WHOOP 4.0, or an f32 outside the decoder's [0, 8] g gate) stores SQL NULL.
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z, dynAccel) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z, s.dynAccel])
                    grav += db.changesCount
                }
            }
            // WHOOP 5 step counter: persist-only (not in the return tuple, which keeps the 8-field shape).
            // `activityClass` is the @63 enum (0=still/1=walk/2=run); nil (byte 0xFF/invalid/absent) stores SQL NULL.
            if !streams.steps.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                var insertedSteps = 0
                var insertedStepTimestamps: [Int] = []
                for s in streams.steps {
                    try stmt.execute(arguments: [deviceId, s.ts, s.counter, s.activityClass])
                    let inserted = db.changesCount
                    insertedSteps += inserted
                    if inserted > 0 { insertedStepTimestamps.append(s.ts) }
                }
                stepDataRevision.record(deviceId: deviceId, insertedTimestamps: insertedStepTimestamps)
            }
            // Band sleep_state: persist-only, the strap's own @81 high-nibble state (0 wake/1 still/2 asleep/3 up),
            // stored verbatim. Keyed by (deviceId, ts) with ON CONFLICT DO NOTHING so a re-sync is idempotent.
            // `rawByte` (v31) is the whole @81 byte; `state` stays its high nibble. nil stores SQL NULL.
            if !streams.sleepState.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO sleepStateSample (deviceId, ts, state, rawByte) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.sleepState {
                    try stmt.execute(arguments: [deviceId, s.ts, s.state, s.rawByte])
                }
            }
            // PPG-derived HR from the v26 optical buffer: persist-only, not in the 8-field return tuple (the
            // Backfiller reads it by name). ON CONFLICT DO NOTHING keeps the first estimate for a second; the
            // measured hrSample is never touched here.
            if !streams.ppgHr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgHr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm, s.conf])
                }
            }
            // Raw v26 optical PPG waveform, the samples `ppgHr` above is derived from. Persist-only, not in the
            // return tuple; ON CONFLICT DO NOTHING keeps the first-seen waveform. One BLOB per row (see
            // `packPpgSamples`), so the insert is O(records), not O(samples).
            if !streams.ppgWaveform.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex, baseCode)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgWaveform {
                    try stmt.execute(arguments: [deviceId, s.ts, WhoopStore.packPpgSamples(s.samples),
                                                 s.burstIndex, s.baseCode])
                    ppgWaveformWritten += 1
                }
            }
            // Every remaining v18 slot (v31), one compact blob per strap-second. Persist-only. A sample whose
            // slots are all absent packs to empty and is skipped, which keeps a WHOOP 4.0 offload from writing here.
            if !streams.v18Aux.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO v18AuxSample (deviceId, ts, fields) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.v18Aux {
                    let blob = V18AuxCodec.pack(s)
                    if blob.isEmpty { continue }
                    try stmt.execute(arguments: [deviceId, s.ts, blob])
                    v18Written += 1
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }

        // Retention is amortised: the delete finds the Nth-newest row by rank, walking up to
        // `v18AuxRetentionRows` index entries, so the 604,800-row cap is swept once per `v18AuxPruneEveryRows`
        // rows. That keeps newest-N exactly (a time window would not suit a sporadically-worn strap). The
        // counter is per device because the delete is.
        if v18Written > 0 {
            let banked = (v18AuxRowsSincePrune[deviceId] ?? 0) + v18Written
            v18AuxRowsSincePrune[deviceId] = banked
            // Best-effort: the rows above are already committed (the sweep is its own transaction). A throw here
            // would surface as an insert failure and make Backfiller re-send a banked chunk; leaving the budget
            // unspent just retries the sweep on the next batch.
            if banked >= v18AuxPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM v18AuxSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM v18AuxSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, v18AuxRetentionRows])
               }) != nil {
                v18AuxRowsSincePrune[deviceId] = 0
            }
        }
        // Waveform-blob retention, amortised and best-effort on the same terms as the aux sweep above (newest-N,
        // not age-based; see `ppgWaveformRetentionRows`). Own counter and own transaction, since a batch often
        // writes only one of these tables and a failed sweep must not fail an insert already committed.
        if ppgWaveformWritten > 0 {
            let banked = (ppgWaveformRowsSincePrune[deviceId] ?? 0) + ppgWaveformWritten
            ppgWaveformRowsSincePrune[deviceId] = banked
            if banked >= ppgWaveformPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM ppgWaveformSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM ppgWaveformSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, ppgWaveformRetentionRows])
               }) != nil {
                ppgWaveformRowsSincePrune[deviceId] = 0
            }
        }
        return result
    }

    // MARK: - Raw sensor CSV export (diagnostic)

    /// Long-format CSV column order. One stream's columns are filled per row; the rest stay blank.
    private static let rawCSVHeader =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
        "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    /// One assembled CSV line: the 16 columns after the `unix_s,iso_utc` prefix. `cols[0]` is the `stream`
    /// name; `cols[1...15]` are per-stream value slots, only the row's own stream non-empty.
    private struct RawCSVRow {
        let ts: Int
        var cols: [String]
        init(ts: Int) { self.ts = ts; self.cols = Array(repeating: "", count: 16) }
    }

    /// Exports the decoded per-sample sensor streams to one combined long-format CSV (header plus one row
    /// per sample, all streams interleaved and sorted by ts). On-device plain text for prototyping
    /// sleep/activity/VBT algorithms.
    ///
    /// `since` is a unix-seconds floor (caller passes now-24h); rows with `ts >= since` for `deviceId` are
    /// included. Writes a temp file and returns its URL for the share/save flow.
    public func exportRawCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        let floor = Int(since)
        let rows: [RawCSVRow] = try syncRead { db in
            var out: [RawCSVRow] = []

            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "hr"
                row.cols[1] = WhoopStore.intStr(r["bpm"])
                out.append(row)
            }
            // rr: stream=rr, rr_ms (col 4). Same-second beats use the emission-order tiebreak (bare "ORDER BY ts"
            // left their order undefined, so exports could differ between runs).
            //
            // Deliberately unfiltered by `srcChannel`, unlike the scoring read: this is the raw dump, and both
            // optical channels are real measurements that must stay inspectable against each other.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? " +
                "ORDER BY ts, ord, rrMs, seq",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "rr"
                row.cols[2] = WhoopStore.intStr(r["rrMs"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "gravity"
                row.cols[3] = WhoopStore.dblStr(r["x"])
                row.cols[4] = WhoopStore.dblStr(r["y"])
                row.cols[5] = WhoopStore.dblStr(r["z"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, counter FROM stepSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "steps"
                row.cols[6] = WhoopStore.intStr(r["counter"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "ppghr"
                row.cols[7] = WhoopStore.dblStr(r["bpm"])
                row.cols[8] = WhoopStore.dblStr(r["conf"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "spo2"
                row.cols[9] = WhoopStore.intStr(r["red"])
                row.cols[10] = WhoopStore.intStr(r["ir"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "skintemp"
                row.cols[11] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "resp"
                row.cols[12] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // band sleep_state: stream=band_sleep_state (col 15), the strap's own @81 high-nibble state, verbatim.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "band_sleep_state"
                row.cols[13] = WhoopStore.intStr(r["state"])
                out.append(row)
            }
            // event: stream=event, event_kind/event_payload (cols 16-17). Payload is free-form JSON, so it always
            // goes through the CSV-quote escaper.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "event"
                row.cols[14] = WhoopStore.csvField(r["kind"] ?? "")
                row.cols[15] = WhoopStore.csvField(r["payloadJSON"] ?? "")
                out.append(row)
            }

            // Stable by ts: ties only occur across different streams in the same second, any interleaving is fine.
            out.sort { $0.ts < $1.ts }
            return out
        }

        // Stream rows to disk through a FileHandle in ~64 KB chunks rather than building one in-memory String:
        // a busy 24 h export otherwise held tens of MB twice (String plus its UTF-8 Data copy) and could OOM.
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        let stamp = Int(Date().timeIntervalSince1970)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.zoopapp.zoop") + ".scratch",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("raw-sensors-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data((WhoopStore.rawCSVHeader + "\n").utf8))
        var buf = String()
        buf.reserveCapacity(72 * 1024)
        for row in rows {
            let isoStr = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
            buf += "\(row.ts),\(isoStr),"
            buf += row.cols.joined(separator: ",")
            buf += "\n"
            if buf.utf8.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buf.utf8))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: Data(buf.utf8)) }
        return url
    }

    private static func intStr(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Formats a Double-valued GRDB column (blank for NULL). `String(Double)` is round-trippable and locale-independent.
    private static func dblStr(_ v: Double?) -> String { v.map { String($0) } ?? "" }

    /// RFC-4180 CSV field: quoted, with embedded quotes doubled, only when the value contains a comma, quote or newline.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Bind each count to its own `let` before assembling the tuple: one tuple of inline
        // `try Int.fetchOne(...) ?? 0` expressions made the type-checker time out on some toolchains.
        try syncRead { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let battery = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skinTemp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let gravity = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
        }
    }

    public func stepCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    /// The strap's own banked band sleep_state samples in `[from, to]` for one device, ascending by ts.
    /// Each `(ts, state)` is the raw @81 high-nibble code (0 wake/1 still/2 asleep/3 up). Empty when the
    /// strap never reported it (WHOOP 4.0, or a not-yet-offloaded window).
    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [SleepStateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, state, rawByte FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // rawByte (v31) is the whole @81 byte; nil on any pre-v31 row. `state` is unchanged.
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"], rawByte: $0["rawByte"]) }
        }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    /// The remaining 5/MG v18 per-second fields (v31) in `[from, to]` for one device, ascending by ts,
    /// decoded from the compact blob by `V18AuxCodec`. Empty for a WHOOP 4.0 and for windows offloaded
    /// before v31. Instrumentation: no analytic calls this.
    public func v18AuxSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [V18AuxSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, fields FROM v18AuxSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { V18AuxCodec.unpack($0["fields"] ?? Data(), ts: $0["ts"]) }
        }
    }

    public func v18AuxCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample") ?? 0 }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    /// The raw v26 optical PPG waveform, one record per second, in `[from, to]` for one device, ascending
    /// by ts. `samples` are the raw i16 ADC counts unpacked from the on-disk BLOB. Empty when the strap
    /// never emitted v26 (the WHOOP 4.0 / v18-only common case).
    public func ppgWaveformSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [PpgWaveformSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, samples, burstIndex, baseCode FROM ppgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // baseCode is selected explicitly: this projection names its columns, so an unlisted column reads
                // back nil, the same answer a legacy row gives, and would look like the column doing nothing.
                .map { PpgWaveformSample(ts: $0["ts"],
                                         samples: WhoopStore.unpackPpgSamples($0["samples"]),
                                         burstIndex: $0["burstIndex"],
                                         baseCode: $0["baseCode"]) }
        }
    }

    public func ppgWaveformCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgWaveformSample") ?? 0 }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }

    /// Writes an R-R row the way a pre-v30 build did (`ord` NULL), the only way to construct the legacy
    /// shape and test the read-order fallback. Test-only.
    public func insertLegacyRrWithoutOrdForTest(deviceId: String, ts: Int, rrMs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord) VALUES (?, ?, ?, 0, NULL)
                ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                """, arguments: [deviceId, ts, rrMs])
        }
    }

    /// The stored `ord` values for one second, in read order. Test-only.
    public func rrOrdValuesForTest(deviceId: String, ts: Int) async throws -> [Int?] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ord FROM rrInterval WHERE deviceId = ? AND ts = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId, ts]).map { $0["ord"] }
        }
    }

    /// Every stored R-R row for a device as `(rrMs, srcChannel)`, bypassing the scoring read's channel
    /// filter, so a test can assert both channels stay on disk. Test-only.
    public func rrRowsWithChannelForTest(deviceId: String) async throws -> [(rrMs: Int, srcChannel: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT rrMs, srcChannel FROM rrInterval WHERE deviceId = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId]).map { (rrMs: $0["rrMs"], srcChannel: $0["srcChannel"]) }
        }
    }

    /// Runs the `v35-rr-future-quarantine` backfill predicate with an explicit `now` (the migration uses
    /// `strftime('%s','now')`), marking every stored R-R beat whose ts is after `nowSeconds`. Test-only.
    public func markFutureRrSuspectForTest(nowSeconds: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > ?", arguments: [nowSeconds])
        }
    }

    /// Every stored R-R row for a device as `(ts, tsSuspect)`, bypassing the scoring read's filter, so a
    /// test can assert which rows were quarantined and none deleted. Test-only.
    public func rrSuspectRowsForTest(deviceId: String) async throws -> [(ts: Int, tsSuspect: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, tsSuspect FROM rrInterval WHERE deviceId = ? ORDER BY ts ASC
                """, arguments: [deviceId]).map { (ts: $0["ts"], tsSuspect: $0["tsSuspect"]) }
        }
    }
}
