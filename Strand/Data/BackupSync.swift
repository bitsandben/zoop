import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Backup & Sync (folder destination): writes the full `.zoopbak` snapshot (the `DataBackup` format) into a
/// user-chosen folder, on demand and as a daily on-launch catch-up. Point the folder at a
/// Drive/iCloud/Dropbox client for off-device backup; Zoop only writes a local file.
/// `BackupSync` holds only the pure filename/selection logic (no I/O, no state); the scheme
/// `zoop-backup-YYYYMMDD-HHMMSS.zoopbak`, newest-first selection and keep-N prune must match Android byte
/// for byte. Folder I/O lives in `FolderBackup`.
enum BackupSync {

    /// Supported destinations; a future Drive backend slots in behind the same logic.
    enum Destination { case folder /* , googleDrive */ }

    static let prefix = "zoop-backup-"
    static let suffix = ".zoopbak"

    // MARK: - Pure helpers (unit-tested; mirror Android BackupSync)

    /// Default staleness threshold (3 days). A successful backup older than this means the daily catch-up
    /// is not landing (lost folder bookmark, or app not launched), so it is surfaced as a warning.
    static let staleThresholdMs = 3 * 24 * 60 * 60 * 1000

    /// True when the last successful backup is older than `thresholdMs`; `lastBackupMs == 0` counts as
    /// stale. Caller supplies `nowMs` and gates on auto/folder.
    static func isBackupStale(lastBackupMs: Int, nowMs: Int, thresholdMs: Int = staleThresholdMs) -> Bool {
        nowMs - lastBackupMs >= thresholdMs
    }

    /// A fresh UTC formatter per call keeps the type trivially Sendable with no shared mutable DateFormatter.
    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.isLenient = false
        return f
    }

    /// Canonical snapshot filename for an instant (ms since epoch), in UTC.
    static func snapshotName(_ epochMs: Int) -> String {
        prefix + stampFormatter().string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0)) + suffix
    }

    /// The UTC instant (ms) in a snapshot filename, or nil if not ours.
    static func snapshotTimeMs(_ name: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let d = stampFormatter().date(from: stamp) else { return nil }
        return Int((d.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func isSnapshot(_ name: String) -> Bool { snapshotTimeMs(name) != nil }

    /// Any `.zoopbak` file, whatever its name (case-insensitive extension). The restore list uses this so
    /// hand-named backups show (#852); prune/latest stay strict on `isSnapshot`, so non-canonical names are
    /// never auto-deleted.
    static func isBackupFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(suffix)
    }

    /// An iCloud Drive file not yet downloaded appears under a placeholder name (leading dot plus `.icloud`
    /// suffix), which would fail `isBackupFile` and hide it from the restore list (#278). Returns the real
    /// name, or nil if `name` is not a placeholder.
    static func iCloudPlaceholderRealName(_ name: String) -> String? {
        let iCloudSuffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(iCloudSuffix),
              name.count > 1 + iCloudSuffix.count else { return nil }
        return String(name.dropFirst().dropLast(iCloudSuffix.count))
    }

    /// Newest snapshot by encoded time, or nil.
    static func latestSnapshot(_ names: [String]) -> String? {
        names.filter(isSnapshot).max { (snapshotTimeMs($0) ?? 0) < (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshot names newest-first; the restore list order.
    static func snapshotsNewestFirst(_ names: [String]) -> [String] {
        names.filter(isSnapshot).sorted { (snapshotTimeMs($0) ?? 0) > (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshots to delete to keep only the `keep` newest (oldest-first). Strict: only canonical snapshots
    /// are candidates.
    static func snapshotsToPrune(_ names: [String], keep: Int) -> [String] {
        let snaps = snapshotsNewestFirst(names)
        return snaps.count <= keep ? [] : Array(snaps.dropFirst(keep))
    }

    /// One restorable `.zoopbak` for the folder picker.
    struct Restorable: Equatable {
        let name: String
        /// Sort/display instant: the filename stamp if canonical, else the file's modification date. Never nil.
        let timeMs: Int
    }

    /// All `.zoopbak` files (any name) newest-first for the restore picker (#852). Non-canonical names use
    /// `fileDateMs` (0 when unknown).
    static func restorablesNewestFirst(_ names: [String],
                                       fileDateMs: (String) -> Int) -> [Restorable] {
        names.filter(isBackupFile)
            .map { Restorable(name: $0, timeMs: snapshotTimeMs($0) ?? fileDateMs($0)) }
            // Name tie-break keeps equal-time entries deterministic and identical to Kotlin's
            // `compareByDescending { timeMs }.thenBy { name }`.
            .sorted { $0.timeMs != $1.timeMs ? $0.timeMs > $1.timeMs : $0.name < $1.name }
    }
}

/// The folder destination: a security-scoped bookmark of a user-chosen folder, plus
/// write/list/restore/prune and a daily on-launch catch-up.
/// Apple gives no reliable unattended background write (a whole-DB ZIP can be 100 MB+), so the schedule is
/// a deferred catch-up: with auto on and a day passed, the next foreground launch writes one snapshot off
/// the main thread and off the launch-critical path.
enum FolderBackup {
    private static let bookmarkKey = "backupSync.folderBookmark"
    private static let autoKey = "backupSync.auto"
    private static let lastKey = "backupSync.lastMs"
    private static let keepKey = "backupSync.keepCount"
    private static let internalKey = "backupSync.useInternalFolder"   // #52 picker-free fallback

    /// Default snapshots kept by prune: 7, a week of daily rollback points.
    static let defaultKeep = 7

    /// Retention choices for the keep-count picker.
    static let keepOptions = [1, 3, 5, 7, 10, 14]

    /// Snapshots to keep; older are pruned. Unset reads back as `defaultKeep`; clamped to 1...100.
    static var keepCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: keepKey)   // 0 when never set
            return v == 0 ? defaultKeep : min(max(v, 1), 100)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: keepKey) }
    }
    private static let dayMs = 24 * 60 * 60 * 1000

    // MARK: - Persisted state

    /// Auto-backup defaults off (manual-first).
    static var autoEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var lastBackupMs: Int { UserDefaults.standard.integer(forKey: lastKey) }
    static var hasFolder: Bool { useInternalFolder || UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Opt-in fallback to Zoop's own Documents/Backups folder, visible in Files, for iOS 26 builds where
    /// the system folder picker's "Open" never enables (#52). No security-scoped bookmark is involved. An
    /// explicit external pick (`saveFolder`) turns this off.
    static var useInternalFolder: Bool {
        get { UserDefaults.standard.bool(forKey: internalKey) }
        set { UserDefaults.standard.set(newValue, forKey: internalKey) }
    }

    /// Opts into Zoop's own Files-visible backup folder and returns its URL.
    @discardableResult
    static func useNoopFolder() -> URL? {
        useInternalFolder = true
        return internalFolderURL()
    }

    /// `<sandbox>/Documents/Backups`, created on first use; nil only if Documents cannot be located.
    private static func internalFolderURL() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether a path sits in iCloud (under `Mobile Documents`). The single definition of the rule, shared
    /// with `restoreListHealth` so the screen and diagnostics cannot disagree about where backups are.
    static func isICloudPath(_ path: String) -> Bool { path.contains("Mobile Documents") }

    /// Display tail of a folder path, e.g. "Zoop > 2026". The bare last component is ambiguous (iCloud
    /// "Backups" vs the internal `Documents/Backups`) and the full path is a sandbox UUID or home
    /// directory. For iCloud paths everything through the sync root is dropped.
    static func folderTrail(path: String, maxComponents: Int = 2) -> String {
        var parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        // Slice after the sync root rather than filtering it: on macOS the tilde component would leave
        // "Mobile Documents" in the trail.
        if let i = parts.lastIndex(where: {
            $0 == "com~apple~CloudDocs" || $0.hasPrefix("iCloud~") || $0 == "Mobile Documents"
        }) { parts = Array(parts[(i + 1)...]) }
        return parts.suffix(max(1, maxComponents)).joined(separator: " › ")
    }

    /// Short label for the chosen folder, or nil. The internal fallback gets a friendly name and iCloud is
    /// named explicitly (#52), so users can tell on-device-only backups apart.
    static func folderLabel() -> String? {
        if useInternalFolder { return String(localized: "Zoop (in Files)") }
        guard let path = resolveFolder()?.path else { return nil }
        let trail = folderTrail(path: path)
        if isICloudPath(path) {
            // The iCloud Drive root has no trail; name the place rather than leave a dangling separator.
            return trail.isEmpty ? String(localized: "iCloud Drive")
                                 : String(localized: "iCloud Drive › \(trail)")
        }
        return trail.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? path) : trail
    }

    // MARK: - Security-scoped bookmark

    private static func bookmarkCreationOptions() -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static func resolveFolder() -> URL? {
        if useInternalFolder { return internalFolderURL() }   // #52: no bookmark — our own sandbox folder
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        let url = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
        // A stale bookmark still resolves; refresh it so it works next launch.
        if stale, let url { saveFolder(url) }
        return url
    }

    /// Persists a security-scoped bookmark for `url`; on macOS minting a `.withSecurityScope` bookmark
    /// needs a scoped-access bracket.
    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try? url.bookmarkData(options: bookmarkCreationOptions(),
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            useInternalFolder = false   // #52: an explicit external pick overrides the internal fallback
        }
        // #52 instrumentation: record whether scoped access opened and the bookmark minted, to tell a
        // persistence failure from a picker that never returned.
        let d = UserDefaults.standard
        d.set(scoped, forKey: "backupPicker.lastScopedOpen")
        d.set(data != nil, forKey: "backupPicker.lastBookmarkOk")
    }

    // MARK: - Backup / prune

    /// Writes one snapshot into the bookmarked folder, stamps the last-backup time, prunes to keepN.
    /// Returns true on success; the ZIP runs off the caller's thread.
    @discardableResult
    static func backupNow(checkpoint: @escaping () async -> Bool) async -> Bool {
        guard let folder = resolveFolder() else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        let dest = folder.appendingPathComponent(BackupSync.snapshotName(nowMs))
        // #1807: an oversize write still wrote the file, so it counts as success here; the interactive
        // export is where the user is told.
        switch await DataBackup.writeBackup(checkpoint: checkpoint, to: dest) {
        case .exported, .exportedOversize: break
        default:
            // Remove whatever this run left behind. Opposite of the interactive export: a file in this
            // folder would silently become `latestSnapshot` and be offered first to restore without ever
            // being read back, whereas a user-chosen location is theirs to keep.
            try? FileManager.default.removeItem(at: dest)
            return false
        }

        UserDefaults.standard.set(nowMs, forKey: lastKey)
        prune(in: folder)
        return true
    }

    /// Best-effort retention: deletes snapshots beyond `keepCount`, touching only files matching the backup scheme.
    private static func prune(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let toDelete = Set(BackupSync.snapshotsToPrune(names, keep: keepCount))
        for name in names where toDelete.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// On-launch catch-up: with auto on, a folder set, and at least a day since the last backup, write one.
    /// Call off the launch-critical path.
    static func catchUpIfDue(checkpoint: @escaping () async -> Bool) async {
        guard autoEnabled, hasFolder else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        guard nowMs - lastBackupMs >= dayMs else { return }
        await backupNow(checkpoint: checkpoint)
    }

    /// Diagnostic-only: the chosen folder's name, raw entry count and how many resolve to recognised
    /// snapshots, to separate an empty folder from a resolution problem such as undownloaded placeholders
    /// (#278). Used by `DebugDataDiagnostics`.
    static func restoreListHealth() -> (isICloud: Bool, rawEntries: Int, snapshots: Int)? {
        guard let folder = resolveFolder() else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let raw = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
        // Reports iCloud-vs-local without the user-chosen folder name (redactPii cannot scrub it). Shares
        // `isICloudPath` with the visible label so they cannot disagree.
        let isICloud = isICloudPath(folder.path)
        return (isICloud, raw, listSnapshots().count)
    }

    // MARK: - Restore from the configured folder (must-fix #1)

    /// One restorable snapshot: display name plus an absolute-time line.
    struct Snapshot: Identifiable, Hashable {
        let name: String
        let timeMs: Int
        var id: String { name }
    }

    /// Lists backups in the chosen folder newest-first for the restore picker, any `.zoopbak` name (#852).
    /// Canonical names sort by their stamp, others by modification date. Content is validated on restore.
    static func listSnapshots() -> [Snapshot] {
        guard let folder = resolveFolder() else { return [] }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let rawNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // #278: resolve undownloaded iCloud placeholders back to real names (see
        // `BackupSync.iCloudPlaceholderRealName`); `restore(snapshotNamed:)` does the same and triggers the
        // download.
        let names = rawNames.map { BackupSync.iCloudPlaceholderRealName($0) ?? $0 }
        let fileDateMs: (String) -> Int = { name in
            let onDisk = rawNames.contains(name) ? name : ("." + name + ".icloud")
            let url = folder.appendingPathComponent(onDisk)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified else { return 0 }
            return Int((modified.timeIntervalSince1970 * 1000.0).rounded())
        }
        return BackupSync.restorablesNewestFirst(names, fileDateMs: fileDateMs)
            .map { Snapshot(name: $0.name, timeMs: $0.timeMs) }
    }

    /// Restores a snapshot picked from the configured folder via `DataBackup.restore(from:)`, so all its
    /// validation and rollback applies. The screen must confirm the destructive action first.
    static func restore(snapshotNamed name: String) -> DataBackup.BackupResult {
        guard let folder = resolveFolder() else {
            return .failure("Couldn't open your backup folder - re-pick it and try again.")
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let source = folder.appendingPathComponent(name)
        var wasPlaceholder = false
        if !FileManager.default.fileExists(atPath: source.path) {
            // #278: if `name` is missing under its real name it may be an undownloaded iCloud placeholder;
            // trigger the download and wait briefly. Runs off the main thread.
            let placeholder = folder.appendingPathComponent("." + name + ".icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) {
                wasPlaceholder = true
                try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: source.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(wasPlaceholder
                ? "That backup is still downloading from iCloud - wait a moment and try again."
                : "That backup is no longer in your folder.")
        }
        return DataBackup.restore(from: source)
    }

    // MARK: - Folder picker

    #if os(macOS)
    /// Presents an `NSOpenPanel` to choose a directory and persists the bookmark.
    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for Zoop backups (for example a Google Drive or iCloud folder).")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveFolder(url)
        return url
    }
    #else
    /// Presents a folder picker and persists the bookmark. Starts in the previously chosen folder when it
    /// resolves (#1000a mitigation).
    @MainActor
    static func pickFolder() async -> URL? {
        let url = await DocumentPicker.pickFolder(startingAt: resolveFolder())
        if let url { saveFolder(url) }
        return url
    }
    #endif
}
