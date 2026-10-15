import Foundation

/// Per-day reuse identity for the steps-calibration motion fold in `IntelligenceEngine.analyzeRecent`.
///
/// The calibration fits one coefficient from sixty days of strap motion; re-folding all sixty every pass
/// cost a 200,000-row gravity read per day. `StepsEstimateEngine.dayMotionIntensity` is a pure fold over
/// one day's gravity stream, so the value changes exactly when that day's gravity changes and the key
/// below is the whole invalidation story. That is why this cache can PERSIST across launches (unlike the
/// day-scan cache, whose config signature shifts whenever any night moves): 32.9 s -> 3.3 s on a worn
/// 60-day library.
///
/// A derived cache only: a missing, unreadable, or older-fold payload is discarded, costing one re-fold.
/// It must NOT cross the `.zoopbak` boundary (the key is absent from the `BackupSettings` whitelist): it
/// describes gravity rows as they were on one device, and serving it elsewhere would use a key that
/// witnesses nothing.
public enum StepsMotionCache {
    /// The per-day reuse key; a cached motion volume is reused iff it is unchanged.
    ///
    /// - `owner`: the resolved owning device, so an owner flip between straps forces a re-fold.
    /// - `gravityCount` / `gravityMaxTs`: the day window's gravity witness. Deliberately not the wider
    ///   `dayStreamFingerprint`, which would let an ordinary HR offload invalidate an unchanged motion volume.
    public static func cacheKey(owner: String, gravityCount: Int, gravityMaxTs: Int) -> String {
        "\(owner)|\(gravityCount)|\(gravityMaxTs)"
    }

    /// The pass's one-line reuse readout. `folded=60` every pass means the key is moving when it should not.
    public static func logLine(reused: Int, folded: Int, size: Int) -> String {
        "analyzeRecent stepsMotion reused=\(reused)/\(reused + folded) size=\(size)"
    }

    /// Version of the FOLD that produced the persisted values; bump on any change to `dayMotionIntensity`
    /// that alters its output. `cacheKey` witnesses inputs only, so without this an old volume would survive
    /// an app update.
    public static let foldVersion = 1

    /// Renders the cache for storage. Days are sorted so an unchanged cache renders identically. One line per
    /// day, `day\tkey\tmotion` (tab-separated because the key contains `|`), under a header naming
    /// `foldVersion`; motion is written by raw bit pattern to round-trip exactly and locale-free.
    public static func serialize(_ entries: [String: (key: String, motion: Double)]) -> String {
        var out = header
        for day in entries.keys.sorted() {
            guard let e = entries[day] else { continue }
            out += "\n\(day)\t\(e.key)\t\(e.motion.bitPattern)"
        }
        return out
    }

    /// Parses a stored payload; returns empty on anything it cannot vouch for (wrong header or older
    /// `foldVersion`, malformed line, implausible count). Discards rather than salvages, since a half-trusted
    /// cache could feed a stale volume into the fit.
    public static func deserialize(_ raw: String) -> [String: (key: String, motion: Double)] {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring(header) else { return [:] }
        lines.removeFirst()
        guard lines.count <= maxEntries else { return [:] }
        var out: [String: (key: String, motion: Double)] = [:]
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty, let bits = UInt64(f[2]) else { continue }
            out[String(f[0])] = (key: String(f[1]), motion: Double(bitPattern: bits))
        }
        return out
    }

    /// Payload header; carries `foldVersion` so a fold change invalidates by failing the equality check.
    private static var header: String { "stepsMotion v\(foldVersion)" }

    /// Upper bound on entries a payload may declare (the writer prunes to the calibration window every pass).
    private static let maxEntries = 512
}
