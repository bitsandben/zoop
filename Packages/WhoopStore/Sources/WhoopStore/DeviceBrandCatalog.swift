import Foundation

/// Single source of truth for recognising a wearable brand from its advertised BLE name, and the stored
/// facts that follow from the brand. Pure (no CoreBluetooth). Adding a brand is one row in `all`.
public struct DeviceBrandSpec: Sendable, Equatable {
    /// Display + stored `PairedDevice.brand` string ("Polar", "Amazfit", "Oura", ...).
    public let brand: String
    /// Lowercased, diacritic-folded advertised-name substrings identifying this brand, checked in `all` order.
    public let nameTokens: [String]
    /// The routing kind stored on the device (drives `SourceCoordinator.makeSource`).
    public let sourceKind: SourceKind
    /// The registry id prefix for a device of this brand ("huami", "oura", "garmin", "strap").
    public let idPrefix: String
    /// Whether this brand can stream live heart rate in Zoop. False for Oura, which routes to import.
    public let canStreamLiveHR: Bool
    /// True for the opt-in experimental tier; false for the shipped generic HR straps.
    public let isExperimentalTier: Bool

    public init(brand: String, nameTokens: [String], sourceKind: SourceKind, idPrefix: String,
                canStreamLiveHR: Bool, isExperimentalTier: Bool) {
        self.brand = brand
        self.nameTokens = nameTokens
        self.sourceKind = sourceKind
        self.idPrefix = idPrefix
        self.canStreamLiveHR = canStreamLiveHR
        self.isExperimentalTier = isExperimentalTier
    }
}

public enum DeviceBrandCatalog {
    /// The brand table, checked most-specific-first. Order matters only where one name could match two rows:
    /// Mi Band precedes Amazfit so a "Mi Smart Band" is not labelled Amazfit.
    public static let all: [DeviceBrandSpec] = [
        // EXPERIMENTAL tier — custom-protocol or broadcast live sources, opt-in and best-effort.
        DeviceBrandSpec(brand: "Mi Band", nameTokens: ["mi band", "miband", "smart band", "xiaomi"],
                        sourceKind: .huami, idPrefix: "huami", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Amazfit", nameTokens: ["amazfit", "zepp", "helio", "huami"],
                        sourceKind: .huami, idPrefix: "huami", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Garmin",
                        nameTokens: ["garmin", "forerunner", "fenix", "vivoactive", "venu", "instinct", "epix", "vivosmart", "hrm"],
                        sourceKind: .liveBLE, idPrefix: "garmin", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Oura", nameTokens: ["oura"],
                        sourceKind: .oura, idPrefix: "oura", canStreamLiveHR: false, isExperimentalTier: true),
        // Shipped generic HR straps — standard 0x180D broadcast, labelled for display only. All route as a
        // generic live-BLE strap; the wizard picks these through the "Heart-rate strap" type.
        DeviceBrandSpec(brand: "Polar", nameTokens: ["polar"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Wahoo", nameTokens: ["wahoo", "tickr"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Coospo", nameTokens: ["coospo"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Scosche", nameTokens: ["scosche", "rhythm"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Magene", nameTokens: ["magene"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
    ]

    /// The brand whose advertised name matches, or nil. Matching is diacritic-folded and lowercased, in `all` order.
    public static func spec(forAdvertisedName name: String) -> DeviceBrandSpec? {
        let n = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return all.first { spec in spec.nameTokens.contains { n.contains($0) } }
    }

    /// The row for a known brand string ("Amazfit", ...), or nil.
    public static func spec(forBrand brand: String) -> DeviceBrandSpec? {
        all.first { $0.brand == brand }
    }

    /// True when a registry deviceId belongs to an Oura ring, resolved from its "<idPrefix>-" prefix against
    /// this table (never an ad-hoc "oura" literal).
    public static func isOura(_ deviceId: String) -> Bool {
        all.first { deviceId.hasPrefix($0.idPrefix + "-") }?.sourceKind == .oura
    }
}
