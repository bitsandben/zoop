import Foundation

/// A device the user has paired. `id` is the `deviceId` in every sample table's `(deviceId, ts)` key,
/// so raw samples are isolated by id. The original WHOOP keeps id "my-whoop".
public struct PairedDevice: Equatable, Sendable, Identifiable {
    public let id: String                 // == deviceId in sample tables; e.g. "my-whoop", "polar-h10-1A2B"
    public var brand: String              // "WHOOP", "Polar", "Garmin", "Oura"
    public var model: String              // "WHOOP 4.0", "H10", "Forerunner 265", "Oura (import)"
    public var nickname: String?          // user-renamable; nil → show brand+model
    public var peripheralId: String?      // CBPeripheral.identifier.uuidString (iOS/Mac); nil until adopted
    public var sourceKind: SourceKind
    public var capabilities: Set<Metric>
    public var status: DeviceStatus
    public var addedAt: Int               // unix seconds
    public var lastSeenAt: Int

    public init(id: String, brand: String, model: String, nickname: String? = nil,
                peripheralId: String? = nil,
                sourceKind: SourceKind, capabilities: Set<Metric>, status: DeviceStatus,
                addedAt: Int, lastSeenAt: Int) {
        self.id = id; self.brand = brand; self.model = model; self.nickname = nickname
        self.peripheralId = peripheralId
        self.sourceKind = sourceKind; self.capabilities = capabilities; self.status = status
        self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
    }

    /// A user nickname wins; otherwise "Brand Model", collapsing to just the model when it already
    /// carries the brand ("WHOOP", not "WHOOP WHOOP").
    public var displayName: String {
        if let nickname { return nickname }
        if model.isEmpty || model == brand { return brand }
        if model.localizedCaseInsensitiveContains(brand) { return model }
        return "\(brand) \(model)"
    }

    /// True for a data-partition source (cloud API pull or file import) rather than a live device. "Make
    /// active" UI must exclude these: an import source has no live connection to take over BLE routing
    /// and day-owner priority 0.
    public var isImportSource: Bool { sourceKind == .cloudImport || sourceKind == .fileImport }
}

public enum DeviceStatus: String, Sendable, CaseIterable { case active, paired, archived }

public enum SourceKind: String, Sendable, CaseIterable {
    case liveBLE, historyBLE, cloudImport, fileImport
    /// A live FTMS (0x1826) gym machine: treadmill, bike, rower or cross-trainer. Records via the live-workout path.
    case ftms
    /// An experimental Huami-family live HR source (Amazfit / Zepp, Xiaomi Mi Band). Reads the standard
    /// 0x180D HR service when exposed, else the Huami custom HR characteristic, else reports that pairing
    /// is unsupported. Garmin uses `liveBLE`.
    case huami
    /// Apple Watch streamed via HealthKit (live observer and background delivery). Apple-only.
    case liveAppleWatch
    /// An experimental live Oura Ring (gen 3/4/5) over its own clean-room BLE protocol (OuraProtocol).
    /// Owns its own central/GATT, never the WHOOP path. Surfaces only decoded raw signals and open
    /// HRV/sleep-phase tags; Oura's encrypted scores are never read.
    case oura
    /// A GPX/TCX/FIT activity file imported under the `activity-file` device. Distinct from `fileImport`
    /// so the day-owner resolver ranks it below day-spanning imports: a 90-minute ride must not displace
    /// a full-day source. It wins only on a strap-less day.
    case activityFile
}

/// Canonical metric a source can provide. Drives capability-aware UI and the day-owner resolver.
public enum Metric: String, Sendable, CaseIterable, Codable {
    case hr, hrv, spo2, skinTemp, steps, sleep, strainLoad
}
