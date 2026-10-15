import Foundation

/// Zoop's own scratch area inside the temporary directory, and the sweep that reclaims it.
///
/// Everything staged in temp lives under one owned folder and the sweep removes only what is inside
/// it. The old flat `noop-*` sweep was unsafe on macOS: the distributed build is ad-hoc re-signed
/// with no entitlements (see `project.yml`), so it is unsandboxed and `temporaryDirectory` is the
/// shared per-user folder, where the sweep deleted other processes' `noop-*` items (#2446). Owning a
/// folder means nothing outside it is ever a candidate.
enum ZoopScratch {

    /// The folder Zoop owns inside the temporary directory, named for the running bundle.
    ///
    /// Not a plain "Zoop": [purge] empties it without name matching, so the name must be one nothing else
    /// will have taken, and macOS filesystems are case-insensitive by default (`Zoop` and `noop` collide).
    /// The per-install bundle id makes a collision need another program under this app's own identifier;
    /// the fallback applies only with no bundle id (a bare command-line host).
    static var folderName: String { (Bundle.main.bundleIdentifier ?? "com.zoopapp.zoop") + ".scratch" }

    /// Zoop's scratch folder. Not created; see [directory].
    static func root(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Zoop's scratch folder, created if absent. Best-effort: a creation failure returns the URL anyway,
    /// so a caller fails on its own write.
    @discardableResult
    static func directory(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        let url = root(in: temporaryDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A URL for `name` inside Zoop's scratch folder, creating the folder first.
    static func file(_ name: String,
                     in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory(in: temporaryDirectory).appendingPathComponent(name)
    }

    /// A URL for a subdirectory `name` inside Zoop's scratch folder, creating the parent first.
    static func subdirectory(_ name: String,
                             in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory(in: temporaryDirectory).appendingPathComponent(name, isDirectory: true)
    }
    /// Legacy flat scratch prefixes Zoop itself wrote before it owned a folder. Exact prefixes, not the
    /// open `noop-`: a stranded multi-GB `noop-health-` import extraction (#590) is still reclaimed while
    /// siblings this app never created are not candidates. Only needs to cover builds that predate the
    /// owned folder; add nothing new.
    static let legacyFlatPrefixes = [
        "noop-settings-", "noop-manifest-", "noop-import-", "noop-health-", "noop-xiaomi-",
        "noop-export-", "noop-recap-", "noop-5mg-raw-", "noop-strap-log-", "noop-raw-sensors-",
        "noop-route-",
    ]

    /// Legacy flat scratch by exact name. `noop-last-crash.txt` and `noop-raw-capture-*` are absent on
    /// purpose: they live in caches/documents, never temp, and must not start being swept.
    static let legacyFlatNames = ["noop-rhythm.csv"]

    /// Whether `name` is flat scratch an earlier build of this app wrote.
    static func isLegacyFlatScratch(_ name: String) -> Bool {
        legacyFlatNames.contains(name) || legacyFlatPrefixes.contains { name.hasPrefix($0) }
    }

    /// Bytes in Zoop's scratch folder, legacy flat scratch included: counts exactly what [purge] would
    /// reclaim (the Storage screen reports it) and nothing another program wrote.
    static func sizeBytes(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                          measure: (URL) -> Int64) -> Int64 {
        var total = measure(root(in: temporaryDirectory))
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: temporaryDirectory,
                                                   includingPropertiesForKeys: nil, options: []) {
            for item in items where isLegacyFlatScratch(item.lastPathComponent) {
                total += measure(item)
            }
        }
        return total
    }

    /// Removes Zoop's scratch: everything in the owned folder plus legacy flat scratch. Keeps a 60 s
    /// in-flight guard so a running import or export isn't pulled out from under itself.
    static func purge(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-60)

        func removeIfSettled(_ item: URL) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { return }
            try? fm.removeItem(at: item)
        }

        // Inside the owned folder every entry is ours, so nothing is matched by name.
        if let mine = try? fm.contentsOfDirectory(at: root(in: temporaryDirectory),
                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: []) {
            mine.forEach(removeIfSettled)
        }
        // Outside it, only what an earlier build of this app wrote.
        if let siblings = try? fm.contentsOfDirectory(at: temporaryDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) {
            siblings.filter { isLegacyFlatScratch($0.lastPathComponent) }.forEach(removeIfSettled)
        }
    }

}
