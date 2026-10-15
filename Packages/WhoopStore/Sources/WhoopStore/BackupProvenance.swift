import Foundation

/// Build provenance for exports: a `manifest.json` entry naming the build that produced a `.zoopbak`,
/// and an `APP_VERSION_CHANGED` event per in-app version transition. Pure JSON; local metadata only.

/// The `manifest.json` entry inside a `.zoopbak`. Read only to classify a file; never restored.
public enum BackupManifest {
    /// Canonical entry name inside the `.zoopbak` ZIP.
    public static let entryName = "manifest.json"

    /// Deterministic (`.sortedKeys`) JSON: `appBuild`, `appVersion`, `exportedAt` (unix ms), `platform`
    /// ("apple"/"android"), `schemaVersion`. Keys and kinds are a cross-platform contract.
    public static func json(appVersion: String, appBuild: String, platform: String,
                            schemaVersion: Int, exportedAtMs: Int64) -> String {
        let obj: [String: Any] = [
            "appVersion": appVersion,
            "appBuild": appBuild,
            "platform": platform,
            "schemaVersion": schemaVersion,
            "exportedAt": exportedAtMs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The `APP_VERSION_CHANGED` event appended on an in-app version transition.
public enum AppVersionEvent {
    /// The `event.kind` for a version transition.
    public static let kind = "APP_VERSION_CHANGED"

    /// True only when a prior version was seen and differs; a first launch records nothing.
    public static func shouldRecord(lastSeen: String?, current: String) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        return lastSeen != current
    }

    /// Deterministic (`.sortedKeys`) payload: `from`, `schemaVersion`, `to`.
    public static func payloadJson(from: String, to: String, schemaVersion: Int) -> String {
        let obj: [String: Any] = ["from": from, "to": to, "schemaVersion": schemaVersion]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
