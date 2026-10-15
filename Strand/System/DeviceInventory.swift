import Foundation

/// One registry row, reduced to what `deviceInventoryLines` prints.
struct InventoryRow {
    let id: String
    let brand: String
    let model: String
    let status: String
    let lastSeenAt: Int
    let firmware: String?
}

/// The strap log's paired-device inventory: every registry row, which is ACTIVE, and when each was
/// last seen. Gives the id-bearing lines elsewhere (`dayOwner readId=`, the orphan check) something
/// to be cross-checked against on a multi-strap install.
///
/// Sorted ACTIVE first, then most-recently-seen, then id (stable, independent of registry order).
/// Ids can embed a BLE address; the export's redaction masks the middle octets. `nowSec` is passed in
/// so the output is pure.
func deviceInventoryLines(rows: [InventoryRow],
                          activeId: String?,
                          nowSec: Int,
                          relTime: (Double) -> String) -> [String] {
    if rows.isEmpty { return ["Devices:     none registered"] }
    let active = rows.filter { $0.status == "active" }.count
    let paired = rows.filter { $0.status == "paired" }.count
    let archived = rows.filter { $0.status == "archived" }.count
    let head = "Devices:     \(rows.count) registered (\(active) active, \(paired) paired, \(archived) archived)"
    let ordered = rows.sorted { a, b in
        let aActive = a.id == activeId, bActive = b.id == activeId
        if aActive != bActive { return aActive }
        if a.lastSeenAt != b.lastSeenAt { return a.lastSeenAt > b.lastSeenAt }
        return a.id < b.id
    }
    return [head] + ordered.map { r in
        let marker = r.id == activeId ? "ACTIVE" : r.status
        let seen = r.lastSeenAt > 0 ? relTime(Double(nowSec - r.lastSeenAt)) : "never"
        return "  device id=\(r.id) status=\(marker) brand=\(r.brand) model=\(r.model) lastSeen=\(seen)"
            + " fw=\(r.firmware ?? "unknown")"
    }
}
