import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SQLite3
import UniformTypeIdentifiers
import WhoopStore
import ZIPFoundation

/// Full-database export/import for device migration.
/// Export checkpoints the WAL, then wraps the single SQLite file in a ZIP written as `.zoopbak`, plus a
/// `settings.json` entry (#1000) of whitelisted profile/display settings (see `BackupSettings`). The format
/// is a standard ZIP; renaming to `.zip` works on any OS.
/// Import detects ZIP (`PK\x03\x04`) or legacy plain SQLite by magic bytes; ZIPs are extracted to a temp
/// dir and validated before the swap. Old `.sqlite` / `.noopdb` backups still work.
/// Every path is best-effort: failures return `.failure`, never crash.
enum DataBackup {
    /// Uncompressed ceiling for the SQLite entry, enforced while extracting. Measured on the decompressed
    /// stream because it is a zip-bomb guard (#1807).
    static let maxBackupSQLiteBytes: Int64 = 2_147_483_648
    private static let maxBackupSettingsBytes: Int64 = 1_048_576

    // MARK: - Result

    enum BackupResult {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Export wrote a valid backup, but the database exceeds [maxBackupSQLiteBytes], so restore needs
        /// one confirmation. Reported at export time, since restore is when the original is gone (#1807).
        case exportedOversize(URL, bytes: Int64, limit: Int64)
        /// Import succeeded; relaunch required. `sidecar` preserves the previous database for rollback.
        case imported(sidecar: URL)
        /// The user dismissed the panel; nothing happened.
        case cancelled
        /// Restore stopped only because an entry exceeds the size ceiling. Distinct from `failure` so the
        /// caller can offer to proceed: a backup the user picked is a different threat model than a hostile
        /// archive (#1807).
        case restoreTooLarge(name: String, limit: Int64)
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export

    /// Checkpoints the store and writes the live database as a `.zoopbak` to a user-chosen file.
    /// - Parameter checkpoint: flushes the WAL (pass `repo.checkpointForBackup`). Must succeed: committed
    ///   pages left in the WAL would be silently absent from the ZIP.
    @MainActor
    static func runExport(checkpoint: @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the Zoop database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no Zoop data to export yet. Import or record some first."))
        }

        // Flush the WAL so the single .sqlite is whole (no sidecar fallback in a ZIP).
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely export right now. Recent changes are still in the database's write-ahead log. Close any in-flight sync, then try again."))
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Zoop backup")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = backupContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            // NSSavePanel already confirmed replacement; clear the target.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            // Read + DEFLATE (plus the #1014 quick_check) is multi-second on big libraries; run off the main actor.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            }.value
            return exportOutcome(dest, dbURL: dbURL)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let fm = FileManager.default

        // Stage in temp, then hand to the share sheet.
        let staged = fm.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            // Off the main actor, same reason as macOS.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: staged, settingsJSON: currentSettingsJSON())
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
        return exportOutcome(dest, dbURL: dbURL)
        #endif
    }

    /// #1014: export failure when the live database itself is damaged; thrown by `writeVerifiedBackupZip`.
    private struct ExportIntegrityFailure: LocalizedError {
        let complaint: String
        var errorDescription: String? {
            String(localized: "the Zoop database failed its integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). A backup of it would not restore. Export the WHOOP-format CSV (Settings → Export data) to save what's still readable.")
        }
    }

    /// The just-written `.zoopbak` failed a post-write structural check (DB entry missing or truncated:
    /// torn write from full disk or flaky sync). Fails at write time rather than at restore (#1014).
    private struct BackupWriteIncomplete: LocalizedError {
        var errorDescription: String? {
            String(localized: "the backup file was written incompletely (its database entry is missing or truncated). Free up space or check the backup folder, then try again.")
        }
    }

    /// The written backup could not be read back to check it. Not evidence of damage; the file is left in place.
    private struct BackupWriteUnverified: LocalizedError {
        var errorDescription: String? {
            String(localized: "the backup file was written, but couldn't be read back to check it, so it has been left in place rather than deleted. Open it before you rely on it, or export again somewhere else.")
        }
    }

    /// Production export path: run a read-only `PRAGMA quick_check` on the checkpointed file before zipping
    /// (#1014), so a corrupt database fails now rather than at a restore months later.
    /// `writeBackupForTesting` bypasses it.
    /// Returns `.exported`, or `.exportedOversize` past the restore ceiling. Measured on the database, not
    /// the archive, since the cap counts the decompressed stream (#1807).
    private static func exportOutcome(_ dest: URL, dbURL: URL) -> BackupResult {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbURL.path)
        guard let bytes = (attrs?[.size] as? NSNumber)?.int64Value,
              bytes > maxBackupSQLiteBytes else { return .exported(dest) }
        return .exportedOversize(dest, bytes: bytes, limit: maxBackupSQLiteBytes)
    }

    /// Minimum size of a real database entry: SQLite's file header is exactly 100 bytes.
    static let minimumBackupEntryBytes: UInt32 = 100

    /// What a post-write check concluded about the produced file. `unverifiable` exists because the caller
    /// deletes a `torn` file, and a transient read failure must never destroy a good backup. Verification
    /// opens the ZIP's central directory (at the end of the file), so truncation fails to open (#1014).
    enum BackupWriteVerdict: Equatable { case intact, torn, unverifiable }

    /// Re-reads the `.zoopbak` just written and classifies it. Unreadable is its own answer, since the
    /// response to `torn` is destructive.
    static func verifyWrittenBackup(at url: URL) -> BackupWriteVerdict {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .unverifiable }
        guard let written = try? Archive(url: url, accessMode: .read),
              let dbEntry = written.first(where: { ($0.path as NSString).lastPathComponent == backupEntryName }),
              dbEntry.uncompressedSize >= minimumBackupEntryBytes else { return .torn }
        return .intact
    }

    /// Convenience over `verifyWrittenBackup(at:)`: whether it passed.
    static func writtenBackupIsIntact(at url: URL) -> Bool {
        verifyWrittenBackup(at: url) == .intact
    }

    private static func writeVerifiedBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
            throw ExportIntegrityFailure(complaint: complaint)
        }
        try writeBackupZip(dbURL: dbURL, to: dest, settingsJSON: settingsJSON, manifestJSON: currentManifestJSON())
        switch verifyWrittenBackup(at: dest) {
        case .intact:
            break
        case .torn:
            // Never leave a corrupt file masquerading as a good snapshot.
            try? FileManager.default.removeItem(at: dest)
            throw BackupWriteIncomplete()
        case .unverifiable:
            // Failing to read it back is not evidence against it; leave it in place.
            throw BackupWriteUnverified()
        }
    }

    /// #1410: provenance manifest (Bundle version/build, GRDB schema, export time) as JSON.
    /// Container contract of `writeBackupZip`: DB entry `zoop-backup.sqlite` FIRST (older importers stop at
    /// the first `.sqlite`), then optional `settings.json`, with deflate; entry names and order match
    /// Android so a `.zoopbak` imports on either platform. `settingsJSON == nil` writes the legacy
    /// single-entry ZIP.
    private static func currentManifestJSON() -> Data {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let json = BackupManifest.json(appVersion: version, appBuild: build, platform: "apple",
                                       schemaVersion: WhoopStoreInfo.schemaVersion,
                                       exportedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        return Data(json.utf8)
    }

    private static func writeBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?, manifestJSON: Data) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: backupEntryName, fileURL: dbURL, compressionMethod: .deflate)
        let fm = FileManager.default
        // Stage each JSON through a temp file, the same file-URL addEntry idiom as the DB entry.
        if let settingsJSON {
            let tmpJSON = ZoopScratch.file("settings-\(UUID().uuidString).json")
            try settingsJSON.write(to: tmpJSON)
            defer { try? fm.removeItem(at: tmpJSON) }
            try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON, compressionMethod: .deflate)
        }
        // #1410: manifest last and always written, even for a legacy nil-settings backup.
        let tmpManifest = ZoopScratch.file("manifest-\(UUID().uuidString).json")
        try manifestJSON.write(to: tmpManifest)
        defer { try? fm.removeItem(at: tmpManifest) }
        try archive.addEntry(with: BackupManifest.entryName, fileURL: tmpManifest, compressionMethod: .deflate)
    }

    /// This device's whitelisted settings (see `BackupSettings.whitelist`) as the `settings.json` payload,
    /// or nil if none was ever set (fresh install exports a DB-only ZIP). UserDefaults is thread-safe, so
    /// this may run off main.
    private static func currentSettingsJSON() -> Data? {
        var values = BackupSettings.snapshot(from: .standard)
        // #1361: bridge custom journal behaviours into whitelisted `journal.customBehaviors` as a
        // newline-joined name list, byte-identical to Android's `noop.journalCustomQuestions`. Definitions
        // live only in defaults (effects ride the DB); `JournalCatalogStore` is @MainActor, so decode the
        // items blob directly. Skipped when none.
        if let blob = UserDefaults.standard.data(forKey: JournalCatalogBackupKeys.items),
           let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            let customs = items.filter(\.custom).map(\.canonical)
            if !customs.isEmpty { values["journal.customBehaviors"] = customs.joined(separator: "\n") }
        }
        return BackupSettings.encode(values)
    }

    /// Backup & Sync: writes a `.zoopbak` to a specific `dest` with no save panel, via the same
    /// `writeBackupZip` as the interactive export (byte-identical). The caller owns security-scoped access
    /// to `dest`. No UI, so safe off the main actor.
    static func writeBackup(checkpoint: @escaping () async -> Bool, to dest: URL) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the Zoop database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no Zoop data to export yet."))
        }
        // Flush the WAL; a single-file ZIP has no sidecar fallback.
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely back up right now. Recent changes are still in the write-ahead log."))
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return exportOutcome(dest, dbURL: dbURL)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    /// Test seam: writes a `.zoopbak` from an explicit source database (no checkpoint, no `StorePaths`).
    /// `settings` adds the `settings.json` entry; nil writes the legacy ZIP. Production uses
    /// `writeBackup(checkpoint:to:)`.
    static func writeBackupForTesting(databaseAt dbURL: URL, to dest: URL,
                                      settings: [String: Any]? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try writeBackupZip(dbURL: dbURL, to: dest,
                           settingsJSON: settings.flatMap { BackupSettings.encode($0) },
                           manifestJSON: currentManifestJSON())
    }

    // MARK: - Import

    /// Picks a `.zoopbak` or legacy `.sqlite`, validates it, snapshots the current DB to a side file, then
    /// copies it over the live path (removing `-wal`/`-shm`). Takes effect after a relaunch.
    @MainActor
    static func runImport(allowOversize: Bool = false) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the Zoop database. \(error.localizedDescription)")) }

        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Zoop backup")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = backupContentTypes()

        guard panel.runModal() == .OK, let pickedSource = panel.url else { return .cancelled }

        let scoped = pickedSource.startAccessingSecurityScopedResource()
        defer { if scoped { pickedSource.stopAccessingSecurityScopedResource() } }
        #else
        // iOS: the document picker's asCopy gives a readable temp copy, so no security-scoped bookkeeping.
        guard let pickedSource = await DocumentPicker.importFile(backupContentTypes()) else { return .cancelled }
        #endif

        // Same hardened restore core as the folder path. Heavy synchronous file work (tens of seconds on
        // big libraries) runs off the main actor; macOS security-scoped access stays valid because this
        // function is still awaiting. Only Sendable values cross.
        return await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath, allowOversize: allowOversize)
        }.value
    }

    /// Restores a chosen backup directly, no picker (Backup & Sync folder flow; caller owns security-scoped
    /// access). Same hardened path as the picker: ZIP extraction, magic-byte check, GRDB-origin rejection,
    /// timestamped sidecar snapshot, rollback on failure.
    static func restore(from pickedSource: URL) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the Zoop database. \(error.localizedDescription)")) }
        return restore(from: pickedSource, toDatabaseAt: dbPath)
    }

    /// Hardened restore core with the database path injected for tests against a throwaway DB.
    /// `settingsDefaults` is where `settings.json` (#1000) is re-applied, injected so tests use a
    /// suite-scoped UserDefaults.
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard,
                        allowOversize: Bool = false) -> BackupResult {
        // A .zoopbak ZIP has its SQLite entry extracted to a temp dir first; legacy plain SQLite falls through.
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = ZoopScratch.subdirectory("import-\(UUID().uuidString)")
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract, allowOversize: allowOversize)
            } catch let err as BackupArchiveError {
                try? fm.removeItem(at: tmpExtract)
                // Its own case: recoverable, and only the caller can ask the user whether to proceed (#1807).
                switch err {
                case .entryTooLarge(let name):
                    return .restoreTooLarge(name: name, limit: maxBackupSQLiteBytes)
                }
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "Couldn't open the backup archive: \(error.localizedDescription)"))
            }
            guard let sqliteEntry = (try? fm.contentsOfDirectory(
                at: tmpExtract, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "sqlite" }) else {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "The backup archive doesn't contain a database file."))
            }
            source = sqliteEntry
            extractedDir = tmpExtract
        } else {
            source = pickedSource
            extractedDir = nil
        }
        defer { if let d = extractedDir { try? fm.removeItem(at: d) } }

        // Must be a real SQLite database (magic header).
        guard isSQLiteFile(at: source) else {
            return .failure(String(localized: "That file isn't a Zoop backup. It doesn't look like a SQLite database."))
        }

        // Reject backups that are not a clean GRDB backup. The magic check passes any SQLite file, so an
        // Android (Room) backup would replace the live DB and leave the migrator re-running v1 (#222); a
        // valid Mac/iOS backup always carries `grdb_migrations`.
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        let holdsData = backupTables.contains("device") || backupTables.contains("hrSample")
        if origin == .android || (origin == .unknown && holdsData) {
            return .failure(String(localized: "This isn't a Zoop backup from this app. It's missing the migration bookkeeping a Zoop backup carries (it looks like an Android backup or another app's database), and restoring it would strand your store. To move your history across platforms, export the WHOOP-format CSV on the other device (Settings → Export data) and import that here, or import your original WHOOP / Apple Health export."))
        }

        // #1014: the gates above read only the first pages, which survive a truncated or torn backup that
        // then restores as an empty store. Run `PRAGMA quick_check` read-only on the staged file before
        // touching the live DB.
        // A legacy plain SQLite still travelling with -wal/-shm siblings skips this gate (a read-only probe
        // cannot recover another WAL); the post-swap check covers it.
        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). Your current data was left untouched. Try an earlier backup file."))
        }

        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Snapshot the current DB (+ sidecars) to a timestamped side file for rollback.
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try fm.copyItem(at: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); use a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Remove the live DB and WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            do {
                try fm.copyItem(at: source, to: dbURL)
            } catch {
                // The replacement did not land: roll back to the snapshot so a failed import leaves data as
                // it was. Clear any partial copy first, since copyItem fails if the destination exists.
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    removeIfPresent(dbURL)
                    try? fm.copyItem(at: sidecar, to: dbURL)
                }
                return .failure(String(localized: "Import failed. Your existing data was kept. \(error.localizedDescription)"))
            }

            // #1014 post-swap: re-verify the landed file with a second read-only quick_check, since the
            // copy itself can tear (disk full, device sleep). Runs before legacy sidecars are laid down
            // (WAL frames are self-checksummed). On failure roll back automatically; the snapshot is kept
            // either way.
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                removeIfPresent(dbURL)
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    try? fm.copyItem(at: sidecar, to: dbURL)
                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). Your previous data was rolled back automatically and is unchanged."))
                }
                // Fresh install: removing the damaged file restores the pre-import empty state.
                return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(DatabaseIntegrity.readableComplaint(complaint))). The damaged file was removed; there was no previous data to roll back."))
            }

            // Restore sidecars only for legacy plain-SQLite backups whose WAL was not checkpointed. After
            // the integrity check; best-effort (`try?`), so rollback semantics are unchanged.
            if extractedDir == nil {
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-wal")
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-shm")
            }

            // #1000: re-apply whitelisted settings only after the DB swap landed; a failed or rolled-back
            // restore never touches them. Legacy backups have no `settings.json`. A malformed entry
            // degrades to fewer keys inside BackupSettings.decode and never fails the restore.
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                if let data = try? Data(contentsOf: settingsURL) {
                    let decoded = BackupSettings.decode(data)
                    BackupSettings.apply(decoded, to: settingsDefaults)
                    // #1361: restore custom journal behaviours. `JournalCatalogStore` is @MainActor, so
                    // write the names to the legacy `journal.customQuestions` array, clear the hidden list
                    // and drop the v2 items blob; the forced relaunch migrates them into fresh v2 items.
                    if let joined = decoded["journal.customBehaviors"] as? String {
                        let names = joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                        settingsDefaults.set(names, forKey: JournalCatalogBackupKeys.legacyCustom)
                        settingsDefaults.set([String](), forKey: JournalCatalogBackupKeys.legacyHidden)
                        settingsDefaults.removeObject(forKey: JournalCatalogBackupKeys.items)
                    }
                }
            }
            // #57 debug: record when a restore swapped the DB, to correlate with a later write stall.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
            return .imported(sidecar: sidecar)
        } catch {
            return .failure(String(localized: "Import failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    /// Canonical entry name for the SQLite inside a `.zoopbak`; matches Android so backups restore across
    /// platforms.
    private static let backupEntryName = "zoop-backup.sqlite"

    private enum BackupArchiveError: LocalizedError {
        case entryTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let name):
                return "\(name) is too large to restore safely."
            }
        }
    }

    /// Example: "Zoop-backup-2026-06-07.zoopbak"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Zoop-backup-\(f.string(from: Date())).zoopbak"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Content types for the export/import panels: `.zoopbak`, ZIP, and legacy SQLite types.
    private static func backupContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let zoopbak = UTType(filenameExtension: "zoopbak") { types.append(zoopbak) }
        types.append(.zip)
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    /// Which platform produced a backup, judged by its migrator's bookkeeping table.
    enum BackupOrigin: Equatable { case mac, android, unknown }

    /// Classifies a backup by `sqlite_master` table names: GRDB writes `grdb_migrations`, Room writes
    /// `room_master_table`. `.unknown` falls through to normal import, where the migrator decides.
    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        // This platform's marker wins when both are present (the less destructive read).
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        // Older Room layouts lack `room_master_table`; `android_metadata` plus `sqlite_sequence` also marks
        // Android.
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    /// Every table name in a SQLite file, opened read-only so it is never mutated. Empty set on failure
    /// (treated as `.unknown`).
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    /// Checks the first 4 bytes for the ZIP PK magic.
    private static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// Extracts only the canonical entries into `destDir`; unknown files are ignored and each entry is
    /// streamed through an uncompressed-size cap.
    private static func extractBackupZip(at zipURL: URL, into destDir: URL,
                                         allowOversize: Bool = false) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            let limit: Int64
            switch name {
            case backupEntryName:
                limit = allowOversize ? Int64.max : maxBackupSQLiteBytes
            case BackupSettings.entryName:
                limit = maxBackupSettingsBytes
            default:
                continue
            }
            let out = destDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var written: Int64 = 0
            _ = try archive.extract(entry) { data in
                let next = written + Int64(data.count)
                guard next <= limit else {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: out)
                    throw BackupArchiveError.entryTooLarge(name)
                }
                try handle.write(contentsOf: data)
                written = next
            }
        }
    }

    /// Checks the first 16 bytes for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" plus NUL.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Copies a legacy backup's `<source><suffix>` sidecar next to the live DB so an uncheckpointed
    /// plain-SQLite backup keeps its committed pages. Not used for ZIP imports.
    private static func restoreSidecar(from source: URL, toMainPath dbPath: String, suffix: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: source.path + suffix)
        guard fm.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: dbPath + suffix)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try? fm.copyItem(at: src, to: dst)
    }
}
