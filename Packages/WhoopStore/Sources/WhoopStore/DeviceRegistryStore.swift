import Foundation
import GRDB

/// Synchronous GRDB access to the device registry + day-ownership tables. Enforces invariant I1 (at most one
/// .active) inside setActive's transaction. `Sendable` because its only stored property is a GRDB
/// `DatabaseWriter`; takes `any DatabaseWriter` so it works with the store's `DatabasePool` and an in-memory `DatabaseQueue`.
public struct DeviceRegistryStore: Sendable {
    let dbQueue: any DatabaseWriter
    public init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    public func all() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pairedDevice ORDER BY addedAt ASC").map(Self.decode)
        }
    }

    /// The one query that answers "which strap is active". Shared because the WHOOP 5 R-R policy resolves a legacy
    /// `my-whoop` alias through it, and two copies could disagree about which strap a night belongs to.
    /// `LIMIT 1` with no `ORDER BY` is only safe because single-active is an invariant the writers maintain
    /// (demote every active row, then promote one).
    static let activeDeviceIdSQL = "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"

    public func activeDeviceId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: Self.activeDeviceIdSQL)
        }
    }

    public func add(_ d: PairedDevice) throws {
        try dbQueue.write { db in try Self.upsert(db, d) }
    }

    /// I1: promoting one device demotes whatever was active, atomically (single write transaction).
    public func setActive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active', lastSeenAt = ? WHERE id = ?",
                           arguments: [Int(Date().timeIntervalSince1970), id])
        }
    }

    public func archive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = ?", arguments: [id])
        }
    }

    /// Permanently removes a device's REGISTRY entry (the `pairedDevice` row and its `device` provenance row), so a
    /// stale strap can be purged instead of lingering in the archived list. Recorded SAMPLES are not touched: the
    /// caller wipes those first via `deleteAllData(deviceId:)`. Idempotent for an absent id.
    public func remove(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [id])
        }
    }

    public func rename(_ id: String, nickname: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    /// Updates the model label for an existing device (e.g. "WHOOP" to "WHOOP 4.0" once the service family is known).
    public func setModel(_ id: String, model: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET model = ? WHERE id = ?", arguments: [model, id])
        }
    }

    /// Stamps a row as seen right now. Called when a strap connects or drops, since nothing else in the BLE path writes
    /// `lastSeenAt`. Archived rows are excluded so a stray connect can't resurrect a "Removed - data kept" device.
    public func touchLastSeen(_ id: String, at ts: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET lastSeenAt = ? WHERE id = ? AND status != 'archived'",
                           arguments: [ts, id])
        }
    }

    /// Adopts (or, with nil, clears) the stable BLE identity (CBPeripheral.identifier.uuidString) for a registry row.
    public func setPeripheralId(_ id: String, peripheralId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = ?",
                           arguments: [peripheralId, id])
        }
    }

    /// Finds the registry row that has adopted a given BLE peripheral, if any, so multiple straps stay distinct.
    public func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pairedDevice WHERE peripheralId = ? LIMIT 1",
                             arguments: [peripheralId]).map(Self.decode)
        }
    }

    /// Suffix of the COMPUTED sibling every device id owns: the engine writes its derived days, detected workouts and
    /// metric series under `<deviceId>-zoop`. Spelled here so adoption can carry it along with the pairing.
    public static let computedSuffix = "-zoop"

    /// Every table whose rows are keyed by `deviceId`; the authoritative list `deleteAllData` clears. Keep it in sync
    /// with `Database.swift` (`DeviceRegistryStoreTests` asserts coverage). The `pairedDevice` registry row is NOT here.
    static let deviceScopedTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "event", "battery", "dailyMetric", "sleepSession",
        "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
        "scoreInputProvenance",
        // Device-keyed tables from later migrations. Each must be listed or "delete this device's data" leaves it behind,
        // a privacy defect for a delete-means-gone app.
        "rawBatch", "labMarker", "sleepStateSample", "liveSession",
        // v25: the Oura cloud-import raw archive.
        "ouraRaw",
        // v27: the raw v26 optical PPG waveform.
        "ppgWaveformSample",
        // v28 raw IMU capture; v31 banked v18 auxiliary fields.
        "v18AuxSample",
        // v38: hourly Apple Health step buckets (deviceId "apple-health").
        "appleStepHour",
        // v46: every lift-log table, including the child rows (liftProgramItem, liftSet). They join their parents by id,
        // not a foreign key, so omitting them would leave exercise lines and sets behind after a delete.
        "liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet",
    ]

    /// Permanently deletes every recorded sample/derived row for one device across all `deviceId`-keyed tables, in a
    /// single transaction. The `pairedDevice` registry row is left intact (archive/remove it separately).
    public func deleteAllData(deviceId: String) throws {
        try dbQueue.write { db in
            for table in Self.deviceScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [deviceId])
            }
            // Provenance also references the physical/import source separately from its computed namespace.
            try db.execute(sql: "DELETE FROM scoreInputProvenance WHERE sourceId = ?",
                           arguments: [deviceId])
        }
    }

    /// Re-points the ACTIVE Oura device from its CoreBluetooth-UUID id (`activeId`) onto its STABLE serial id
    /// (`serialId`), so a re-pair (which mints a fresh CB UUID) never orphans the ring's history.
    ///
    /// Moves only `activeId`'s data + registry row: a rename when `serialId` is new, a merge (`UPDATE OR IGNORE`,
    /// canonical wins a PK clash) when it exists from a prior pairing. Other `oura-*` rows are deliberately left
    /// alone. One transaction; idempotent. Returns true when a re-point happened; the caller then `setActive(serialId)`.
    @discardableResult
    public func adoptSerialIdentity(from activeId: String, to serialId: String) throws -> Bool {
        guard activeId != serialId else { return false }
        return try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?", arguments: [activeId]) ?? false
            else { return false }   // nothing to re-point
            let serialExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM pairedDevice WHERE id = ?", arguments: [serialId]) ?? false
            if serialExists {
                // A prior pairing already established the serial id: carry this pairing's fresh BLE identity + model onto it.
                try db.execute(sql: """
                    UPDATE pairedDevice SET
                        peripheralId = (SELECT peripheralId FROM pairedDevice WHERE id = :a),
                        model        = (SELECT model        FROM pairedDevice WHERE id = :a),
                        status = 'active',
                        lastSeenAt   = (SELECT lastSeenAt   FROM pairedDevice WHERE id = :a)
                    WHERE id = :s
                """, arguments: ["a": activeId, "s": serialId])
            } else {
                // First time this serial is seen: clone the active (provisional) row under the serial id.
                try db.execute(sql: """
                    INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
                    SELECT ?, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt
                    FROM pairedDevice WHERE id = ?
                """, arguments: [serialId, activeId])
            }
            // Move the active id's recordings onto the serial id (canonical wins a PK clash), then clear it. Both id shapes
            // are re-keyed: every strap also owns a COMPUTED sibling `<deviceId>-zoop`, and an exact-match re-key would
            // strand its scored history under an id nothing reads again.
            for (from, to) in [(activeId, serialId), (activeId + Self.computedSuffix, serialId + Self.computedSuffix)] {
                for table in Self.deviceScopedTables {
                    try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?", arguments: [to, from])
                    try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [from])
                }
            }
            // Drop only the provisional CB-UUID registry rows; other oura-* pairings stay.
            try db.execute(sql: "DELETE FROM pairedDevice WHERE id = ?", arguments: [activeId])
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [activeId])
            return true
        }
    }

    // MARK: day ownership
    public struct DayOwner: Equatable { public let deviceId: String; public let locked: Bool }

    public func setDayOwner(day: String, deviceId: String, locked: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET deviceId = excluded.deviceId, locked = excluded.locked
            """, arguments: [day, deviceId, locked ? 1 : 0])
        }
    }

    public func dayOwner(_ day: String) throws -> DayOwner? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?", arguments: [day])
            else { return nil }
            return DayOwner(deviceId: row["deviceId"], locked: (row["locked"] as Int) == 1)
        }
    }

    // MARK: mapping
    private static func upsert(_ db: Database, _ d: PairedDevice) throws {
        try db.execute(sql: """
            INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET brand=excluded.brand, model=excluded.model, nickname=excluded.nickname,
                peripheralId=excluded.peripheralId, sourceKind=excluded.sourceKind, capabilities=excluded.capabilities,
                status=excluded.status, lastSeenAt=excluded.lastSeenAt
        """, arguments: [d.id, d.brand, d.model, d.nickname, d.peripheralId, d.sourceKind.rawValue,
                         d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                         d.status.rawValue, d.addedAt, d.lastSeenAt])
    }

    private static func decode(_ row: Row) -> PairedDevice {
        // TRIM before matching: `Metric(rawValue:)` is exact, so a stored "hr, hrv" would silently drop the spaced token.
        // Writes are canonical, so spaced tokens come only from history (rows an earlier v36 migration rewrote, or a restored
        // backup). Fixing on READ self-heals every row, including later restores.
        var caps = Set(
            (row["capabilities"] as String)
                .split(separator: ",")
                .compactMap { Metric(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
        // Calibrated SpO2 % is never produced from a live WHOOP path: drop a stale registry bit so the UI doesn't advertise it.
        let brand = row["brand"] as String
        let id = row["id"] as String
        if brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            || id == "my-whoop"
            || id.hasPrefix("whoop-") {
            caps = WhoopLiveCapabilities.withoutCalibratedSpo2(caps)
        }
        return PairedDevice(id: id, brand: brand, model: row["model"], nickname: row["nickname"],
                            peripheralId: row["peripheralId"],
                            sourceKind: SourceKind(rawValue: row["sourceKind"]) ?? .liveBLE,
                            capabilities: caps, status: DeviceStatus(rawValue: row["status"]) ?? .paired,
                            addedAt: row["addedAt"], lastSeenAt: row["lastSeenAt"])
    }
}
