import Foundation

/// Pure, deterministic encoder for ONE line of the Oura real_steps_features (0x7E/0x7F) research corpus: a
/// diagnostic JSONL sidecar, NOT a datastore row. The decode is Tier-B (a cited third-party unpack formula,
/// not validated against a known step count), so it never touches `Streams`/SQLite. These are movement
/// features, not step counts (no field is a count), so nothing here may be turned into steps. Safe to delete.
public enum OuraRealStepsDumpLine {
    /// Bump when the record shape changes.
    public static let schema = 1

    /// One JSONL record (no trailing newline; the writer adds it). `deviceId`, `iso` and `tag` are app-generated,
    /// so need no JSON escaping.
    ///   - tag:    "0x7e" or "0x7f" (which half of the paired record this is).
    ///   - ringTs: raw ring-clock timestamp (the dedup key; strictly increases per record).
    ///   - utc:    anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:    human-readable UTC of `utc`.
    ///   - fields: the 14 decoded fields this record contributed, verbatim, in the source's own order.
    public static func encode(deviceId: String, tag: String, ringTs: UInt32, utc: Int, iso: String,
                              fields: [Int]) -> String {
        let fieldsStr = fields.map { String($0) }.joined(separator: ",")
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"tag\":\"\(tag)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"fields\":[\(fieldsStr)]}"
    }
}
