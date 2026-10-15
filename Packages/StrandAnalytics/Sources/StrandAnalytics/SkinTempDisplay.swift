import Foundation

/// How to present the bimodal `skinTempDevC` / `skin_temp` field.
///
/// CSV / Health imports store absolute wrist °C (~30–35); the live BLE pipeline stores a signed
/// deviation from the personal baseline (±°C). `VitalBands.isAbsoluteSkinTemp` (v ≥ 20) tells them
/// apart. Pure; localization of titles stays in the app layer.
public enum SkinTempDisplay {

    public enum Kind: String, Sendable, Equatable {
        /// Absolute wrist temperature (°C scale, typically ~30–35 worn).
        case absolute
        /// Signed deviation from the personal nightly baseline (±°C).
        case deviation
    }

    public static func kind(of value: Double) -> Kind {
        VitalBands.isAbsoluteSkinTemp(value) ? .absolute : .deviation
    }

    /// The one kind a MIXED series must be reduced to before any aggregate is taken.
    ///
    /// Imports write absolute °C and the pipeline writes a deviation into the same field, so a window can
    /// hold both; a min/max/mean/delta across both is arithmetic on two scales and looks plausible. The
    /// newest entry decides (as `VitalSignsSummary` does for its sparkline); older entries of the other
    /// kind drop out rather than being converted, since conversion needs a baseline an import-only
    /// install lacks.
    ///
    /// - Parameter values: the window's values, ascending by day.
    /// - Returns: the kind to keep, or nil for an empty window.
    public static func dominantKind(valuesAscendingByDay values: [Double]) -> Kind? {
        values.last.map(kind(of:))
    }

    /// A resolved reading: the number to show and the scale it is on.
    public struct Reading: Sendable, Equatable {
        public let value: Double
        public let kind: Kind
        public init(value: Double, kind: Kind) { self.value = value; self.kind = kind }
    }

    /// Which of a night's two skin-temp numbers a surface should LEAD with.
    ///
    /// The absolute wins whenever the night measured one, because a deviation without an anchor is
    /// unreadable ("+0.9" is a fever or a warm bedroom). The deviation is the fallback and keeps its Δ
    /// unit. Two real cases: nights scored before `skinTempC` shipped have only a deviation, and a
    /// CALIBRATING night has an absolute from night one but no deviation until the baseline is usable.
    ///
    /// `prefer` is the user's Settings choice (default `.absolute`); it picks which number is tried first,
    /// the other remains the fallback, and the unit always names the scale shown. Both values must come
    /// from the SAME row (see `DailyMetric.lastSkinTempReadingDay`).
    public static func leadReading(absC: Double?, devC: Double?, prefer: Kind = .absolute) -> Reading? {
        let first = prefer == .absolute ? absC : devC
        if let f = first { return Reading(value: f, kind: prefer) }
        let other = prefer == .absolute ? devC : absC
        let otherKind: Kind = prefer == .absolute ? .deviation : .absolute
        if let o = other { return Reading(value: o, kind: otherKind) }
        return nil
    }

    /// Formats whichever number `leadReading` chose, with the unit for THAT scale.
    public static func formatReading(_ reading: Reading, fahrenheit: Bool, decimals: Int = 1) -> String {
        let n = numberString(reading.value, kind: reading.kind, fahrenheit: fahrenheit, decimals: decimals)
        return "\(n) \(unitSymbol(kind: reading.kind, fahrenheit: fahrenheit))"
    }

    /// Trailing unit chip: `"°C"` / `"°F"` for absolute, `"Δ°C"` / `"Δ°F"` for deviation.
    public static func unitSymbol(kind: Kind, fahrenheit: Bool) -> String {
        let base = fahrenheit ? "°F" : "°C"
        return kind == .absolute ? base : "Δ\(base)"
    }

    /// Format the **number only** (no unit suffix). Deviations are always signed (`+0.1` / `-0.1`);
    /// absolute readings are unsigned. Applies °F conversion when `fahrenheit` is true
    /// (full C→F for absolute, ×9/5 only for deviation).
    public static func numberString(
        _ value: Double,
        kind: Kind,
        fahrenheit: Bool,
        decimals: Int = 1
    ) -> String {
        let display: Double
        if fahrenheit {
            display = kind == .absolute
                ? (value * 9.0 / 5.0 + 32.0)
                : (value * 9.0 / 5.0)
        } else {
            display = value
        }
        if kind == .absolute {
            return String(format: "%.\(decimals)f", display)
        }
        let signed = String(format: "%+.\(decimals)f", display)
        // A deviation that rounds to zero must not keep its sign (`%+` prints "-0.0" for (-0.05, 0)), which
        // reads as a fault rather than "no change".
        if Double(signed.dropFirst()) == 0 { return String(signed.dropFirst()) }
        return signed
    }

    /// Full `"34.2 °C"` / `"+0.1 Δ°C"` string for one-shot call sites (Today cards, explorers).
    public static func format(
        _ value: Double,
        fahrenheit: Bool,
        decimals: Int = 1
    ) -> String {
        let k = kind(of: value)
        let n = numberString(value, kind: k, fahrenheit: fahrenheit, decimals: decimals)
        return "\(n) \(unitSymbol(kind: k, fahrenheit: fahrenheit))"
    }
}
