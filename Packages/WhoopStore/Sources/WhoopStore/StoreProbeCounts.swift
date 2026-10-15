import Foundation

/// Per-pass call/time counters for the per-day lookups `analyzeRecent` makes, rendered by
/// `StrandAnalytics.StoreProbeTally`.
///
/// Counted one level down from the call sites so the counts attribute themselves, without threading an
/// accumulator through a `nonisolated static` resolver and a detached task.
///
/// Drained per pass. A manual Test Centre action (`SkinTempBackfillWalker`) also calls
/// `IntelligenceEngine.resolveDayOwner`, so if run mid-pass its lookups land in that pass's line. That
/// is left as is, because suppressing counting would undercount a real concurrent pass. Read the call
/// count instead: a clean 21-day scoring plus 60-day steps pass resolves 81 owners, and many more means contamination.
///
/// Instrumentation only: nothing reads these but the diagnostic line.
public struct StoreProbeCounts: Sendable, Equatable {
    /// One probe's calls and accumulated time.
    public struct Probe: Sendable, Equatable {
        public private(set) var calls = 0

        /// Accumulated integer nanoseconds, divided to seconds once on read. The Kotlin twin sums
        /// `System.nanoTime()` deltas the same way; per-call `Double` conversion would round differently from
        /// the twin and disagree in the rendered line near a half-millisecond boundary (pinned by `StoreProbeTallyTests`).
        public private(set) var nanos: UInt64 = 0

        /// Accumulated seconds, for the renderer. One division, matching the twin.
        public var seconds: Double { Double(nanos) / 1_000_000_000 }

        /// Adds one call of `nanos` monotonic nanoseconds. Monotonic, not a `Date()` difference: these
        /// counters decide whether per-day round trips are worth batching, and a forward clock jump
        /// mid-probe would inflate that probe's total.
        mutating func record(nanos elapsed: UInt64) {
            calls += 1
            nanos &+= elapsed
        }
    }

    /// `DeviceRegistryStore.dayOwner`, the resolver's locked-override lookup, which runs on every call
    /// before any presence probe.
    public var dayOwner = Probe()
    /// `hasHrInWindow`, the day-owner resolver's per-candidate presence probe, in both the scoring and the
    /// sixty-day steps loops. Skipped entirely on a default single-strap install.
    public var ownerHr = Probe()
    /// `gravityFingerprint`, the steps loop's per-day motion witness. Steps-only.
    public var gravityFp = Probe()

    public init() {}
}

/// Process-wide recorder for `StoreProbeCounts`.
///
/// Nonisolated and lock-guarded rather than actor state, because the call sites cannot share one
/// isolation: `gravityFingerprint` and `hasHrInWindow` are `WhoopStore` actor methods, while the
/// day-owner lookup runs in `IntelligenceEngine.resolveDayOwner`, which is `nonisolated static` so the
/// day loop does not hop to the main actor on every iteration.
public enum StoreProbeRecorder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = StoreProbeCounts()

    /// Which probe a measurement belongs to.
    public enum Probe: Sendable { case dayOwner, ownerHr, gravityFp }

    /// Records one call. `elapsed` must come from a monotonic source.
    public static func record(_ probe: Probe, nanos elapsed: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        switch probe {
        case .dayOwner: counts.dayOwner.record(nanos: elapsed)
        case .ownerHr: counts.ownerHr.record(nanos: elapsed)
        case .gravityFp: counts.gravityFp.record(nanos: elapsed)
        }
    }

    /// Reads the counters and zeroes them, so a line describes one pass and never accumulates across back-to-back passes.
    public static func take() -> StoreProbeCounts {
        lock.lock()
        defer { lock.unlock() }
        let taken = counts
        counts = StoreProbeCounts()
        return taken
    }
}
