import Foundation

/// Pure, deterministic encoder for ONE line of the Oura activity (0x50 MET) research corpus: a diagnostic
/// JSONL sidecar, NOT a datastore row. The 0x50 decode is Tier-B (a plausible third-party formula, day-scale
/// validated only), and the honest-data invariant forbids Tier-B minting a durable scoring row, so it never
/// touches `Streams`/SQLite. Never feeds scoring; safe to delete.
///
/// FORMAT: append-only JSONL (a torn write loses only the last line), hand-built in a FIXED key order so it
/// is byte-stable; `met` uses Swift's shortest round-trip `Double` description.
public enum OuraActivityDumpLine {
    /// Bump when the record shape changes.
    public static let schema = 1

    /// One JSONL record (no trailing newline; the writer adds it). `deviceId` and `iso` are app-generated, so
    /// need no JSON escaping.
    ///   - ringTs:       raw ring-clock timestamp (the dedup key; strictly increases per record).
    ///   - utc:          anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:          human-readable UTC of `utc`.
    ///   - state:        raw 0x50 state byte (semantics unconfirmed; captured verbatim).
    ///   - secPerSample: the ASSUMED per-sample cadence (60 s).
    ///   - met:          decoded per-sample MET series (Tier-B output, verbatim).
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String,
                              state: Int, secPerSample: Int, met: [Double]) -> String {
        let metStr = met.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"state\":\(state),"
             + "\"secPerSample\":\(secPerSample),\"met\":[\(metStr)]}"
    }
}
