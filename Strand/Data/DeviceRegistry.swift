import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore`. The UI observes it for the
// paired-device list and active device; `deviceId` comes from `activeDeviceId` ("my-whoop" by default,
// seeded by migration v15). Failures are non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id; "my-whoop" until the first `reload()` or if the registry is unreadable.
    @Published private(set) var activeDeviceId: String = "my-whoop"

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Loads the device list and active id. On error the published values are left untouched.
    func reload() {
        guard let rows = try? store.all() else { return }
        devices = rows
        if let active = rows.first(where: { $0.status == .active })?.id {
            activeDeviceId = active
        }
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s. Best-effort: a store failure leaves
    // published state untouched.

    /// Adds or upserts a paired device.
    func add(_ device: PairedDevice) {
        try? store.add(device)
        reload()
    }

    /// Makes `id` the single active device (the store demotes the previous one in the same transaction);
    /// changing `activeDeviceId` drives the `SourceCoordinator`.
    func setActive(_ id: String) {
        try? store.setActive(id)
        reload()
    }

    /// Re-points the active Oura device from its transient CoreBluetooth-UUID id to its stable
    /// `oura-<serial>` id (#771), folding only the active row's data and registry. Returns true if it
    /// re-pointed so the caller can `setActive(serialId)`.
    @discardableResult
    func adoptSerialIdentity(from activeId: String, to serialId: String) -> Bool {
        let moved = (try? store.adoptSerialIdentity(from: activeId, to: serialId)) ?? false
        if moved { reload() }
        return moved
    }

    /// Archives a device: Zoop stops connecting but keeps its data. `activeDeviceId` is left as-is; the
    /// caller picks the next active device via `setActive`.
    func archive(_ id: String) {
        try? store.archive(id)
        reload()
    }

    /// Renames a device; nil/empty clears the nickname.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil)
        reload()
    }

    /// Permanently deletes every recorded row for a device across all deviceId-keyed tables (the registry
    /// row stays; see `archive`).
    /// Goes through the `WhoopStore` actor so the 16+-table delete runs off the main thread. Awaits it
    /// before `reload()`.
    func deleteDeviceData(_ id: String, store: WhoopStore) async {
        guard ImuSessionFileStore.shared.deleteDevice(id) else { return }
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        reload()
    }

    /// Permanently forgets a device: wipes its data and removes its registry entry, so a stale strap leaves
    /// the Devices list (#1193). Same off-main wipe as `deleteDeviceData`; if the wipe fails the registry
    /// row stays, so recordings are never orphaned.
    func forget(_ id: String, store: WhoopStore) async {
        guard ImuSessionFileStore.shared.deleteDevice(id) else { return }
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        try? self.store.remove(id)
        reload()
    }

    /// Adopts (or clears) the stable BLE identity (CBPeripheral identifier) so a connected peripheral maps
    /// back to its registry row.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        try? store.setPeripheralId(id, peripheralId: peripheralId)
        reload()
    }

    /// Stamps a device as seen now, on a real connect or disconnect only (not per packet) (#1527).
    func touchLastSeen(_ id: String, at ts: Int = Int(Date().timeIntervalSince1970)) {
        try? store.touchLastSeen(id, at: ts)
        reload()
    }

    /// Finds the paired device that adopted a BLE peripheral. Plain read, no reload.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Updates the model label for a device.
    func setModel(_ id: String, model: String) {
        try? store.setModel(id, model: model)
        reload()
    }
}
