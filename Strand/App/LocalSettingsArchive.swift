import Foundation

/// On-device copy of this install's settings, kept beside the database so an update does not start from
/// blank preferences. The last good `UserDefaults` domain is written to Application Support and copied
/// back at launch when the domain comes back empty. Never uploaded; the database is not copied (a
/// half-written store is a risk).
enum LocalSettingsArchive {
    /// Restore a previous snapshot only when the live domain is empty, so a newer choice is never overwritten.
    static func restoreIfEmpty(defaults: UserDefaults = .standard,
                               domain: String? = nil,
                               file: URL? = nil) {
        let domainName = domain ?? (Bundle.main.bundleIdentifier ?? "noop")
        let url = file ?? defaultFileURL()
        let current = defaults.persistentDomain(forName: domainName) ?? [:]
        guard current.isEmpty, let saved = read(url), !saved.isEmpty else { return }
        defaults.setPersistentDomain(saved, forName: domainName)
    }

    /// Write the live domain to the private snapshot. An empty domain is skipped so a failed restore cannot
    /// erase the last good file.
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
