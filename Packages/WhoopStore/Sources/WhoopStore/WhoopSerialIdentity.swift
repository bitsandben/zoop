import Foundation

/// The stable WHOOP device id derived from the strap's own serial.
///
/// Strap identity is otherwise a transient CoreBluetooth UUID, so a re-pair or factory reset forks one
/// physical strap into a second registry row and orphans its history. This mirrors the ring path
/// (`DeviceRegistryStore.adoptSerialIdentity`). Pure and store-free so both platforms can pin the
/// composition and the refusals: a blank or implausible serial must yield nil and leave the id alone,
/// because the migration moves every row onto the new id.
public enum WhoopSerialIdentity {

    /// The one place the WHOOP id namespace is spelled. `AddDeviceWizard` mints `whoop-<CB-UUID>` and
    /// `DeviceRegistryStore` classifies on the same prefix, so a serial id keeps every prefix check working.
    public static let idPrefix = "whoop"

    /// Shortest serial worth adopting. A 5.0/MG DIS serial is far longer; this rejects a truncated or placeholder read.
    public static let minSerialLength = 6

    /// The `whoop-<serial>` id for a strap serial, or nil when the serial cannot be trusted to identify it.
    ///
    /// Refuses blank input, anything under `minSerialLength`, and any character outside `[A-Z0-9-]` after
    /// upper-casing (so a descriptive DIS string never becomes an id). Upper-cased so the same strap read
    /// in either case resolves to one id.
    public static func adoptedId(serial: String?) -> String? {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let up = raw.uppercased()
        guard up.count >= minSerialLength else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard up.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(idPrefix)-\(up)"
    }

    /// Whether this pairing's id may be re-pointed onto a serial id at all.
    ///
    /// Only a provisional `whoop-<CB-UUID>` id qualifies. The legacy `my-whoop` seed is excluded: every
    /// existing single-WHOOP install is on it, ~47 code paths read the literal directly, and
    /// `WhoopBleClient.deviceId` never reassigns it. Adopting it would migrate history onto
    /// `whoop-<serial>` while new samples kept landing under `my-whoop`, a split that reads as data loss.
    public static func mayAdopt(currentId: String) -> Bool {
        currentId.hasPrefix("\(idPrefix)-")
    }

    /// True when `id` is already the serial id for `serial`: the steady state on every reconnect, and the
    /// early-out that avoids database work per connect.
    public static func isAlreadyAdopted(id: String, serial: String?) -> Bool {
        guard let target = adoptedId(serial: serial) else { return false }
        return id == target
    }

    /// What may be written to a shareable strap log. Only the serial's leading characters are logged, as
    /// `noteWhoop5VariantFromDIS` does. Never log `adoptedId`'s result directly.
    public static func logSafe(serial: String?) -> String {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "?" }
        return String(raw.uppercased().prefix(3)) + "…"
    }
}
