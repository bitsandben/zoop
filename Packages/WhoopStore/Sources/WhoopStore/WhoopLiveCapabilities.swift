import Foundation

/// Live-BLE capability set for a WHOOP strap Zoop can drive without a CSV or Health import.
///
/// Calibrated SpO₂ % is excluded: `AnalyticsEngine` nulls `spo2Pct` for every WHOOP live path
/// (`Spo2ReTrace`), since a % from raw ADC needs WHOOP's proprietary curve. Steps are 5.0/MG only over
/// BLE. Skin temp, sleep and strain stay listed because Zoop decodes and scores them on-device.
public enum WhoopLiveCapabilities {

    /// Core metrics every WHOOP generation can feed in Zoop over BLE (no calibrated SpO₂ %).
    public static let base: Set<Metric> = [.hr, .hrv, .skinTemp, .sleep, .strainLoad]

    /// True when the model label names a 5.0 or MG (wizard labels: "4.0", "5.0 MG", "WHOOP 5.0", ...).
    public static func isFiveOrMG(model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("5") || m.contains("mg")
    }

    /// Capability set for a freshly paired WHOOP with the given model label.
    public static func metrics(forModel model: String) -> Set<Metric> {
        var caps = base
        if isFiveOrMG(model: model) { caps.insert(.steps) }
        return caps
    }

    /// Comma-joined, sorted encoding used in `pairedDevice.capabilities` (matches DeviceRegistryStore).
    public static func encoded(forModel model: String) -> String {
        metrics(forModel: model).map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Drops calibrated SpO₂ from a stored set, for old registry rows that still list it.
    public static func withoutCalibratedSpo2(_ caps: Set<Metric>) -> Set<Metric> {
        caps.subtracting([.spo2])
    }

    /// SQL-safe rewrite of a comma-joined capabilities string: trims tokens and removes bare `spo2` only.
    /// An empty result is preserved as empty (the caller should not write that).
    public static func stripSpo2Token(fromEncoded encoded: String) -> String {
        encoded
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != Metric.spo2.rawValue }
            .joined(separator: ",")
    }
}
