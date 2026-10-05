import Foundation

/// On-device copy of this install's settings, kept beside the database so an update does not start
/// the app from a blank preferences file.
///
/// Apple already keeps `UserDefaults` and the WhoopStore SQLite file in the app container across an
/// update of the same install. This archive is the safety net for the preferences half: the last
/// good domain is written to Application Support, and a launch whose domain comes back empty copies
/// that file back before anything else reads a setting. It never uploads anything, and it does not
/// replace the database — that file is already durable and copying it would risk a half-written store.
enum LocalSettingsArchive {
    /// Restore a previous snapshot when the live domain has no entries. A domain that already has
    /// settings is left alone, so a newer choice is never overwritten by an older file.
    static func restoreIfEmpty(defaults: UserDefaults = .standard,
                               domain: String? = nil,
                               file: URL? = nil) {
        let domainName = domain ?? (Bundle.main.bundleIdentifier ?? "noop")
        let url = file ?? defaultFileURL()
        let current = defaults.persistentDomain(forName: domainName) ?? [:]
        guard current.isEmpty, let saved = read(url), !saved.isEmpty else { return }
        defaults.setPersistentDomain(saved, forName: domainName)
    }

    /// Write the live domain to the private snapshot. An empty domain is not written, so a failed
    /// restore cannot erase the last good file.
    static func snapshot(defaults: UserDefaults = .standard,
                         domain: String? = nil,
                         file: URL? = nil) {
        let domainName = domain ?? (Bundle.main.bundleIdentifier ?? "noop")
        let url = file ?? defaultFileURL()
        let current = defaults.persistentDomain(forName: domainName) ?? [:]
        guard !current.isEmpty else { return }
        write(current, to: url)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("noop-local-settings", isDirectory: true)
        return dir.appendingPathComponent("user-defaults.plist")
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func write(_ values: [String: Any], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
