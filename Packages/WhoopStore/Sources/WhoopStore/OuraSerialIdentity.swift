import Foundation

/// What may be written to a shareable strap log for an Oura ring's serial.
///
/// Same shape as `WhoopSerialIdentity.logSafe` (3-character prefix + `…`) so masked serials read
/// identically across brands. A separate type because only the log-safety shape is shared with WHOOP,
/// not its identity model.
public enum OuraSerialIdentity {
    /// The Oura id namespace prefix, kept here so `LiveState.redactPii`'s Oura rule and `logSafe` agree
    /// without importing the brand catalog into a pure package.
    public static let idPrefix = "oura"

    /// Never log `"\(idPrefix)-\(serial)"` (or the bare serial) directly; use this.
    public static func logSafe(serial: String?) -> String {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "?" }
        return String(raw.uppercased().prefix(3)) + "…"
    }
}
