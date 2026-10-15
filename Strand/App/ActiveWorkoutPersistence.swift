import Foundation
import WhoopProtocol

/// Durable persistence for an in-flight manual workout, so an iOS kill mid-session does not lose it.
/// A small `Codable` snapshot is written to `UserDefaults` on start and each captured sample, and read
/// back on launch. Encode/decode is pure so the round-trip is unit-testable. GPS fixes are banked
/// separately by `ActiveRouteStore`.
enum ActiveWorkoutPersistence {

    /// The durable shape of an in-flight manual workout; enough to rebuild `AppModel.ActiveWorkout` on relaunch.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds.
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrain: Double
        var pausedAtSec: Int? = nil
        var pausedDurationSec: Int? = nil
    }

    /// The `UserDefaults` key holding the JSON-encoded `Snapshot`.
    static let defaultsKey = "zoop.activeWorkout"

    /// Encode a snapshot to JSON; nil on failure so the caller can no-op.
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot, bound-checking the untrusted persisted values. Nil for garbage, empty input or an
    /// implausible start time.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop out-of-range HR samples (1...300 bpm, ts > 0); never trust the blob.
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrain: raw.liveStrain.isFinite ? max(0, raw.liveStrain) : 0,
            pausedAtSec: raw.pausedAtSec.flatMap { $0 > 0 ? $0 : nil },
            pausedDurationSec: raw.pausedDurationSec.map { max(0, $0) },
        )
    }

    /// Persist (overwrite) the snapshot.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Read back the persisted snapshot, or nil if none or corrupt.
    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Clear the snapshot when a session ends (saved or discarded).
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
