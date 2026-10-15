import Foundation

/// Pure, deterministic encoder for ONE line of the Oura RAW capture: a diagnostic JSONL sidecar holding the
/// undecoded TLV bytes exactly as received, NOT a datastore row. It lets a hole in the decoded sidecars be
/// attributed offline: present here but missing there is a decode drop; absent in both is ring-side. Never
/// scored; safe to delete.
///
/// SCOPE: the history-drain record path only (not the high-frequency live-HR push). Auth/secure frames are
/// consumed before the tap, so no crypto lands here.
///
/// FORMAT: one received TLV notification per line, FIXED key order (byte-stable); `hex` is the raw bytes as
/// contiguous lowercase hex.
public enum OuraRawDumpLine {
    /// Bump when the record shape changes.
    public static let schema = 1

    /// One JSONL record (no trailing newline; the writer adds it). `deviceId` and `iso` are app-generated, so
    /// need no JSON escaping.
    ///   - utc:   wall-clock arrival time (unix seconds) of the notification.
    ///   - iso:   human-readable UTC of `utc`.
    ///   - bytes: raw TLV notification bytes, hex-encoded verbatim (one or more packed `2+len` records).
    public static func encode(deviceId: String, utc: Int, iso: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"utc\":\(utc),"
             + "\"iso\":\"\(iso)\",\"hex\":\"\(hex)\"}"
    }
}
