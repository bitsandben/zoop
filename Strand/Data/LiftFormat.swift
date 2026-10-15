import Foundation

// Number and unit formatting for the Lift Log.
//
// Weight is ALWAYS STORED IN KILOGRAMS; only display and typed input convert, using the app-wide
// unit system (`UnitPrefs.systemKey`), so there is no second weight-unit setting to disagree.
// Both directions use ONE constant (`UnitFormatter.poundsPerKilogram`) so a typed value
// round-trips (225 lb stores and reads back as 225 lb) instead of drifting.

enum LiftFormat {

    // MARK: - Weight

    /// Converts a typed weight in the display unit to the kilograms that get stored.
    static func kilograms(fromDisplay value: Double, system: UnitSystem) -> Double {
        system == .imperial ? value / UnitFormatter.poundsPerKilogram : value
    }

    /// Converts stored kilograms to the display unit as a number, for editable text fields.
    static func display(fromKilograms kg: Double, system: UnitSystem) -> Double {
        system == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg
    }

    /// A stored weight with its unit: "60 kg", "132.5 lb".
    static func weight(_ kg: Double?, system: UnitSystem) -> String {
        guard let kg else { return "—" }
        return "\(trim(display(fromKilograms: kg, system: system))) \(UnitFormatter.massUnit(system))"
    }

    /// The bare unit label for a field suffix.
    static func weightUnit(_ system: UnitSystem) -> String { UnitFormatter.massUnit(system) }

    // MARK: - Numbers

    /// A number with up to two decimals and no trailing noise: 8.0 to "8", 12.25 to "12.25".
    ///
    /// Two decimals because quarter-kilo plates are real (12.25 kg); one decimal would round what the
    /// user typed when the entry field reads its text back. Always renders "." regardless of locale.
    static func trim(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() && abs(rounded) < 1e9 {
            return String(Int(rounded.rounded()))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Parses a typed number, accepting "7.5" and the comma separator "7,5". Nil otherwise.
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    // MARK: - Durations

    /// A rest period as "2:00" / "45s". A running clock uses `ActiveWorkoutClock.clock` instead.
    static func duration(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
