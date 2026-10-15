import Foundation

/// Which registry device a live BLE link's samples belong to.
///
/// Split out of `BLEManager` because it is the part that files rows under the wrong device when wrong,
/// and unlike CoreBluetooth it is testable. `BLEManager` held one `deviceId` meaning both "the active
/// device" and "where these bytes came from"; once a ring could be active, a WHOOP connection filed its
/// samples (including strap-only `stepSample` and `gravitySample`) under the ring's id.
public enum SourceIdentity {

    /// The device id this connection's samples should be stored under, or nil to leave the current id alone.
    ///
    /// Conservative: returns an id only when a registry row is both matched by peripheral and a WHOOP.
    ///   - `address` nil or unmatched gives nil (the legacy single-WHOOP row before it adopts a `peripheralId`).
    ///   - A matched non-WHOOP row gives nil, since re-pointing the strap's id at it is the bug being prevented.
    ///   - A matched row already current gives nil, so the common path does no write.
    ///
    /// Matching is case-insensitive: Apple stores an uppercase `CBPeripheral` UUID string and Android an
    /// uppercase MAC, but neither is guaranteed and older rows may carry either.
    public static func resolve(address: String?, rows: [PairedDevice], currentId: String) -> String? {
        // Blank, not merely empty, to match Kotlin's `isNullOrBlank`; a bare `isEmpty` could match a stored blank.
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let row = rows.first(where: {
            guard let pid = $0.peripheralId else { return false }
            return pid.caseInsensitiveCompare(address) == .orderedSame
        }) else { return nil }
        guard isWhoop(row), row.id != currentId else { return nil }
        return row.id
    }

    /// A device is a WHOOP when it is the seeded legacy row or its brand says so. Matches
    /// `SourceCoordinator.isWhoop` on both platforms.
    public static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop" || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
