import Foundation

/// Pure, deterministic encoder for ONE line of the Oura motion (0x47 motion_events) research corpus: a
/// diagnostic JSONL sidecar, NOT a datastore row. Mapping the averaged `(x, y, z)` vector to a durable
/// `gravitySample` needs an LSB-to-g scale that can only be pinned from a STILL capture, so until then the
/// vector is stored beside the incumbent and never fed to scoring. Safe to delete.
///
/// FORMAT: append-only JSONL in a FIXED key order (byte-stable). Parallels `OuraActivityDumpLine`.
public enum OuraMotionDumpLine {
    /// Bump when the record shape changes. v2 follows open_oura's `decode_motion` (orientation = b0>>5, adds
    /// motion_seconds + low_intensity, intensities masked to 0x3f).
    public static let schema = 2

    /// One JSONL record (no trailing newline; the writer adds it). `deviceId` and `iso` are app-generated, so
    /// need no JSON escaping.
    ///   - ringTs:        raw ring-clock timestamp (the dedup key; strictly increases per record).
    ///   - utc:           anchored wall-clock (unix seconds) for the record envelope.
    ///   - iso:           human-readable UTC of `utc`.
    ///   - orientation:   0...7 orientation code (byte0 >> 5).
    ///   - motionSeconds: seconds of motion in the window (byte0 & 0x1f).
    ///   - x/y/z:         averaged accel vector, signed record byte x 8 (open_oura convention).
    ///   - low/highIntensity: period intensity counts (byte4/byte5 & 0x3f); nil is JSON `null`.
    public static func encode(deviceId: String, ringTs: UInt32, utc: Int, iso: String,
                              orientation: Int, motionSeconds: Int, x: Int, y: Int, z: Int,
                              lowIntensity: Int?, highIntensity: Int?) -> String {
        let lo = lowIntensity.map(String.init) ?? "null"
        let hi = highIntensity.map(String.init) ?? "null"
        return "{\"schema\":\(schema),\"deviceId\":\"\(deviceId)\",\"ringTs\":\(ringTs),"
             + "\"utc\":\(utc),\"iso\":\"\(iso)\",\"orientation\":\(orientation),"
             + "\"motion_seconds\":\(motionSeconds),\"x\":\(x),\"y\":\(y),\"z\":\(z),"
             + "\"low_intensity\":\(lo),\"high_intensity\":\(hi)}"
    }
}
