import Foundation
import GRDB
import WhoopProtocol

/// Persistence library: decoded streams are durable; raw frames are a transient, compressed, prunable
/// outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// The store schema-version marker, bumped per migration and recorded in the backup manifest. It is
    /// platform-scoped: Android reports its Room version independently and the numbers need not match.
    public static let schemaVersion = 18
}

/// Serializes `DatabasePool` creation and migration so two concurrent opens of the same file never
/// run their GRDB migrators at once.
///
/// `WhoopStore(path:)` is opened from more than one place (the BLEManager's backfill store and
/// MetricsRepository), and a cold background relaunch after an update that adds a migration can fire
/// both at once. Both would apply migration N and the loser's bookkeeping `INSERT` would fail with
/// `UNIQUE constraint failed: grdb_migrations.identifier`, deferring the offload.
///
/// `openAndMigrate` is actor-isolated and synchronous, so the actor runs one open+migrate to completion
/// before the next. Opens are rare and a migrated DB migrates nothing, so the gate is free. Each
/// caller still gets its own pool.
private actor StoreOpenGate {
    static let shared = StoreOpenGate()

    func openAndMigrate(path: String, configuration config: Configuration) throws -> DatabasePool {
        // Self-heal a foreign DB left by a bad cross-platform restore: an Android (Room) backup that slipped
        // past the import guard replaces our file with one that has our tables but no `grdb_migrations`
        // bookkeeping, so the migrator re-runs v1 and crashes with `table "device" already exists` on every
        // open. Quarantine it before opening so we start fresh. A normal GRDB backup is left untouched.
        WhoopStore.quarantineIncompatibleDatabase(at: path)
        let pool = try DatabasePool(path: path, configuration: config)
        try WhoopStore.makeMigrator().migrate(pool)
        return pool
    }
}

/// WhoopStore is an `actor`: its public API is `async` and all GRDB work runs on the actor's serial
/// executor rather than the caller's (the main actor).
///
/// The connection is a WAL `DatabasePool`: reads run concurrently with the backfill's bulk writes. A
/// `DatabaseQueue` serialized every read behind a multi-thousand-row import and froze Today for
/// seconds. The pool keeps a single writer (read-modify-write inside one `.write` stays atomic) and
/// serves reads from WAL snapshots, so only committed data is ever seen.
public actor WhoopStore {

    /// PPG waveform rows banked since its retention sweep last ran, per device (the sweep is per device,
    /// so a shared counter would let one strap spend another's budget). Separate from the v18 aux counter
    /// because the caps differ and a batch commonly writes one table and not the other. See `StreamStore`.
    var ppgWaveformRowsSincePrune: [String: Int] = [:]

    /// v18 aux rows banked since the retention sweep last ran, per device. See `StreamStore`.
    var v18AuxRowsSincePrune: [String: Int] = [:]
    var stepDataRevision = StepDataRevisionIndex()
    let revisionInstanceToken = UUID().uuidString
    let dbWriter: any DatabaseWriter

    /// Read-only handle to the underlying GRDB writer for the synchronous `DeviceRegistryStore`.
    /// `nonisolated` because a `DatabasePool` is `Sendable` and manages its own concurrency.
    public nonisolated var registryWriter: any DatabaseWriter { dbWriter }

    private init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try WhoopStore.makeMigrator().migrate(dbWriter)
    }

    /// Stores an already-open, already-migrated writer without re-running the migrator: `StoreOpenGate`
    /// already migrated it under the process-wide lock, and a second run could race a sibling opener and fail.
    private init(preMigrated dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Opens (creating if needed) a database at `path` and runs migrations. A `DatabasePool` enables WAL,
    /// plus a 5-second busy timeout so two handles to the same file (BLEManager + MetricsRepository)
    /// don't deadlock on write contention. Open+migrate runs through `StoreOpenGate`.
    public init(path: String) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // `DatabasePool` enables WAL itself, so there is no explicit `PRAGMA journal_mode = WAL`. Bulk-write
            // tuning: NORMAL is the recommended WAL pairing (only an OS crash or power loss can lose the last
            // transaction); a bigger page cache, mmap and in-memory temp tables speed import/backfill writes.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -16000")     // ~16 MB page cache
            try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB memory-mapped I/O
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        config.busyMode = .timeout(5)
        let pool = try await StoreOpenGate.shared.openAndMigrate(path: path, configuration: config)
        self.init(preMigrated: pool)
    }

    /// Moves aside a database file that has our data tables but no GRDB migration bookkeeping, the
    /// signature of a foreign (Android/Room) DB dropped over ours by a bad restore. Opening it would make
    /// the migrator re-run v1 and throw `table "device" already exists` forever. It moves to a
    /// `.incompatible-<ts>` sidecar so the next open creates a clean store. A valid GRDB DB and a
    /// fresh/empty file are untouched. Best-effort and silent.
    static func quarantineIncompatibleDatabase(at path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let names: Set<String>
        do {
            // Read-only probe of sqlite_master; a raw queue does not run migrations.
            let probe = try DatabaseQueue(path: path)
            names = try probe.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }
        } catch {
            return // unreadable/locked → let the real open + migrator deal with it
        }
        let isForeign = !names.contains("grdb_migrations")
            && (names.contains("device") || names.contains("hrSample"))
        guard isForeign else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let quarantine = "\(path).incompatible-\(stamp)"
        try? fm.removeItem(atPath: quarantine)
        do { try fm.moveItem(atPath: path, toPath: quarantine) } catch { return }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
    }

    /// An in-memory store (migrations applied). For tests.
    ///
    /// Backed by a `DatabaseQueue`, since GRDB has no in-memory `DatabasePool` (a pool needs a real file
    /// for WAL snapshots). API-identical; tests that need real read/write concurrency open a file-backed pool.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbWriter: try DatabaseQueue())
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync overloads @_disfavoredOverload, so an async context would otherwise pick the
    // async ones. These non-async wrappers always select the synchronous API, which blocks on the actor's
    // serial executor (off the main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: - Maintenance

    /// Fully checkpoints the WAL into the main database file and truncates the -wal file, so a file-level
    /// backup of `whoop.sqlite` carries all committed data. Runs outside a transaction (`wal_checkpoint`
    /// requires it). Throws on a hard SQLite error so callers can fall back to a plain copy.
    public func checkpointWAL() async throws {
        try checkpointWALImpl()
    }

    /// Appends one app-level event (e.g. `APP_VERSION_CHANGED`) onto the event table. Idempotent on the
    /// `(deviceId, ts, kind)` primary key.
    public func recordEvent(deviceId: String, ts: Int, kind: String, payloadJSON: String) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceId, ts, kind) DO NOTHING
                """, arguments: [deviceId, ts, kind, payloadJSON])
        }
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen.
    private func checkpointWALImpl() throws {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Permanently deletes every recorded sample and derived row for one device across all
    /// `deviceId`-keyed tables in one GRDB transaction. Wraps the synchronous `DeviceRegistryStore.deleteAllData`
    /// so the multi-table write runs on the actor's executor, off the main thread (it froze the UI on a
    /// large dataset). The `pairedDevice` registry row is left intact.
    public func deleteAllData(deviceId: String) async throws {
        try deleteAllDataImpl(deviceId: deviceId)
    }

    /// Non-async so the synchronous `DeviceRegistryStore.deleteAllData` is called directly, over the same GRDB writer the store owns.
    private func deleteAllDataImpl(deviceId: String) throws {
        try DeviceRegistryStore(dbQueue: dbWriter).deleteAllData(deviceId: deviceId)
    }

    /// Total on-disk size of the database (main file plus `-wal`/`-shm`) in bytes, or nil for an
    /// in-memory store. Under the `DatabasePool` the `-wal` can stay non-zero while a reader holds a
    /// snapshot, so the total can read a little high right after a checkpoint.
    public func databaseFileSizeBytes() async -> Int64? {
        let base = dbWriter.path
        guard base != ":memory:", !base.isEmpty else { return nil }
        let fm = FileManager.default
        var total: Int64 = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            let path = base + suffix
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
                found = true
            }
        }
        return found ? total : nil
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() async throws -> Set<String> {
        try syncRead { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try syncRead { db in
            try db.primaryKey(table).columns
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try syncRead { db in
            try db.columns(in: table).map(\.name)
        }
    }

    /// True when `column` is nullable with no SQL DEFAULT; nil when the column does not exist. Migration
    /// tests use it to prove an added column is additive: NOT NULL or a DEFAULT would turn "the strap
    /// never reported this" into a fabricated value.
    public func columnIsNullableWithoutDefaultForTest(table: String, column: String) async throws -> Bool? {
        try syncRead { db in
            guard let c = try db.columns(in: table).first(where: { $0.name == column }) else { return nil }
            return !c.isNotNull && c.defaultValueSQL == nil
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try syncRead { db in
            try Set(db.indexes(on: table).map(\.name))
        }
    }
}

/// Compact process-local cache witness keyed by owner and UTC day. Cycle windows move with `now`, so
/// keying on their exact end would invalidate an unchanged active cycle every second. Per-day
/// revisions stay stable until a row in that day lands. Size is proportional to owners x UTC days
/// that receive new step rows.
struct StepDataRevisionIndex {
    private static let utcDaySeconds = 86_400
    private var nextRevision = 0
    private var byOwnerDay: [OwnerDay: Int] = [:]

    private struct OwnerDay: Hashable {
        let owner: String
        let day: Int
    }

    mutating func record(deviceId: String, insertedTimestamps: [Int]) {
        guard !insertedTimestamps.isEmpty else { return }
        nextRevision += 1
        for timestamp in insertedTimestamps {
            byOwnerDay[OwnerDay(owner: deviceId, day: timestamp.floorDividing(by: Self.utcDaySeconds))]
                = nextRevision
        }
    }

    func signature(deviceId: String, from: Int, to: Int) -> String {
        guard to > from else { return "" }
        let first = from.floorDividing(by: Self.utcDaySeconds)
        let last = (to - 1).floorDividing(by: Self.utcDaySeconds)
        return (first...last).map { day in
            "\(day):\(byOwnerDay[OwnerDay(owner: deviceId, day: day), default: 0])"
        }.joined(separator: ",")
    }
}

private extension Int {
    func floorDividing(by divisor: Int) -> Int {
        let quotient = self / divisor
        let remainder = self % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }
}
