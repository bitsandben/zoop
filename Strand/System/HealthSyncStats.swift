import Foundation

/// What the HealthKit observer path cost this session: counts and milliseconds only, process-lifetime,
/// never persisted.
///
/// Wakes are counted separately from syncs: coalescing reduces work per wake, not the number of
/// wakes, so many wakes with few syncs means the remaining cost is the wake itself.
///
/// Lives in `Strand/` (shared target) so `StrandTests` can reach it.
@MainActor
enum HealthSyncStats {

    /// Observer notifications handled, whether or not they led to a sync.
    private(set) static var wakes = 0
    /// Wakes that ran a full sync.
    private(set) static var syncs = 0
    /// Wakes that stood down because a recent sync already covered their window.
    private(set) static var coalesced = 0
    /// Wakes that found no new samples at all (a spurious notification).
    private(set) static var emptyWakes = 0
    /// Cumulative wall time inside `sync()`, milliseconds.
    private(set) static var syncMillis = 0

    static func recordWake() { wakes += 1 }
    static func recordEmptyWake() { emptyWakes += 1 }
    static func recordCoalesced() { coalesced += 1 }
    static func recordSync(millis: Int) { syncs += 1; syncMillis += max(0, millis) }

    /// Test seam: counters are process-lifetime.
    static func reset() { wakes = 0; syncs = 0; coalesced = 0; emptyWakes = 0; syncMillis = 0 }

    /// One header line, or nothing when the observer path never ran (avoids a line of zeros in every log).
    static func summaryLines() -> [String] {
        guard wakes > 0 else { return [] }
        let avg = syncs > 0 ? syncMillis / syncs : 0
        return ["Health sync: wakes=\(wakes) synced=\(syncs) coalesced=\(coalesced) "
                + "empty=\(emptyWakes) avgSyncMs=\(avg)"]
    }
}
