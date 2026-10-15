import Foundation

/// How much of an `analyzeRecent` pass goes into its per-day PROBE queries, as calls and milliseconds.
/// Instrumentation only: nothing reads these counts but the log line. Each probe is measured one level
/// down (see `StoreProbeCounts`):
/// - `dayOwner`: `DeviceRegistryStore.dayOwner`, the resolver's locked-override lookup, run on every call.
/// - `ownerHr`: `hasHrInWindow`, the per-candidate presence probe; skipped on a default single-strap
///   install (#970), so only a two-strap library pays it.
/// - `gravityFp`: `gravityFingerprint`, the steps loop's per-day motion witness.
///
/// Read with `stepsMotion reused=N/M`, it shows whether the round trips are the cost of a warm pass.
public enum StoreProbeTally {
    /// Renders ordered `(name, calls, seconds)` probes as one line. Calls print beside time because a wrong
    /// count (not the expected one round trip per day) is a different bug from a slow query.
    public static func logLine(_ probes: [(name: String, calls: Int, seconds: Double)]) -> String {
        let parts = probes.map { "\($0.name)=\($0.calls)/\(millis($0.seconds))ms" }
        let total = probes.reduce(0.0) { $0 + $1.seconds }
        return "analyzeRecent storeProbes total=\(millis(total))ms "
            + (parts.isEmpty ? "(no probes)" : parts.joined(separator: " "))
    }

    /// Seconds to whole milliseconds, floored at zero. The clamp keeps Swift and Kotlin renderings of the
    /// shared strap log identical: negative or non-finite input is where their rounding differs.
    private static func millis(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
