import Foundation

// MARK: - MetricUnit (CONCEPT §1.1 "Value", §7.7 Locale)
//
// The single place a metric number becomes text. Everything goes through `FormatStyle` with an
// explicit locale, so German reads "36,4 °C" and "12.345 Schritte" while English reads "36.4 °C" and
// "12,345 steps". Spoken forms come from catalogue templates rather than Foundation's wide unit names:
// those are missing for some units depending on the ICU data the process loads ("62 ms" is read
// as "62 m s"), and VoiceOver wording must not depend on that.

public enum MetricUnit: Equatable, Sendable {
    /// Unitless score (Sleep score 0–100, Strain 0–21 with one decimal).
    case score(fractionDigits: Int)
    /// A 0–100 value shown with the locale's percent sign (Recovery, SpO₂).
    case percent
    case milliseconds
    case beatsPerMinute
    case breathsPerMinute
    case celsius
    case kilograms
    case kilocalories
    case steps
    case years
    case vo2max
    /// Value in seconds, shown as hours and minutes.
    case duration

    public static let score = MetricUnit.score(fractionDigits: 0)

    var fractionDigits: Int {
        switch self {
        case .score(let digits): return max(0, digits)
        case .breathsPerMinute, .celsius, .kilograms, .vo2max: return 1
        default: return 0
        }
    }

    // MARK: Parts

    /// The number alone, as the hero draws it beside a smaller unit symbol.
    public func number(_ value: Double, locale: Locale) -> String {
        if case .duration = self { return Self.duration(value, width: .narrow, locale: locale) }
        return value.formatted(numberStyle(locale))
    }

    /// The short unit symbol, or nil when the unit is part of the number (duration) or absent (score).
    public func symbol(locale: Locale) -> String? {
        switch self {
        case .score, .duration: return nil
        case .percent: return "%"
        case .milliseconds: return UnitDuration.milliseconds.symbol
        case .celsius: return UnitTemperature.celsius.symbol
        case .kilograms: return UnitMass.kilograms.symbol
        case .kilocalories: return UnitEnergy.kilocalories.symbol
        case .vo2max: return "ml/kg/min"
        case .beatsPerMinute: return MetricStrings.resolve(MetricStrings.bpm, locale: locale)
        case .breathsPerMinute: return MetricStrings.resolve(MetricStrings.breaths, locale: locale)
        case .steps: return MetricStrings.resolve(MetricStrings.steps, locale: locale)
        case .years: return MetricStrings.resolve(MetricStrings.years, locale: locale)
        }
    }

    // MARK: Whole strings

    /// "62 ms", "62 %", "7h 43min".
    public func format(_ value: Double, locale: Locale) -> String {
        switch self {
        case .percent:
            return (value / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        default:
            return Self.join(number(value, locale: locale), symbol(locale: locale))
        }
    }

    /// Signed delta with its unit: "+8 ms", "-0,3 °C", "+25min".
    public func formatDelta(_ delta: Double, locale: Locale) -> String {
        switch self {
        case .duration:
            let sign = delta < 0 ? "-" : "+"
            return sign + Self.duration(abs(delta), width: .narrow, locale: locale)
        case .percent:
            return (delta / 100).formatted(.percent.precision(.fractionLength(0))
                .sign(strategy: .always(includingZero: false)).locale(locale))
        default:
            let n = delta.formatted(numberStyle(locale).sign(strategy: .always(includingZero: false)))
            return Self.join(n, symbol(locale: locale))
        }
    }

    /// "52–68 ms": both bounds share one unit.
    public func formatRange(_ range: ClosedRange<Double>, locale: Locale) -> String {
        if case .percent = self {
            return format(range.lowerBound, locale: locale) + "–" + format(range.upperBound, locale: locale)
        }
        let lo = number(range.lowerBound, locale: locale)
        let hi = number(range.upperBound, locale: locale)
        return Self.join("\(lo)–\(hi)", symbol(locale: locale))
    }

    /// The form VoiceOver reads: "62 Millisekunden", not "62 m s".
    public func spoken(_ value: Double, locale: Locale) -> String {
        let n = number(value, locale: locale)
        switch self {
        case .score, .percent: return format(value, locale: locale)
        case .duration: return Self.duration(value, width: .wide, locale: locale)
        case .milliseconds: return MetricStrings.resolve(MetricStrings.millisecondsSpoken(n), locale: locale)
        case .celsius: return MetricStrings.resolve(MetricStrings.celsiusSpoken(n), locale: locale)
        case .kilograms: return MetricStrings.resolve(MetricStrings.kilogramsSpoken(n), locale: locale)
        case .kilocalories: return MetricStrings.resolve(MetricStrings.kilocaloriesSpoken(n), locale: locale)
        case .beatsPerMinute: return MetricStrings.resolve(MetricStrings.bpmSpoken(n), locale: locale)
        case .breathsPerMinute: return MetricStrings.resolve(MetricStrings.breathsSpoken(n), locale: locale)
        case .steps: return MetricStrings.resolve(MetricStrings.stepsSpoken(n), locale: locale)
        case .years: return MetricStrings.resolve(MetricStrings.yearsSpoken(n), locale: locale)
        case .vo2max: return MetricStrings.resolve(MetricStrings.vo2maxSpoken(n), locale: locale)
        }
    }

    // MARK: Helpers

    private func numberStyle(_ locale: Locale) -> FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(fractionDigits))
    }

    private static func duration(_ seconds: Double, width: Duration.UnitsFormatStyle.UnitWidth, locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: width,
                                              zeroValueUnits: .hide)
        style.locale = locale
        return Duration.seconds(Int64(seconds.rounded())).formatted(style)
    }

    /// A no-break space keeps a value and its unit on one line at large Dynamic Type sizes.
    private static func join(_ number: String, _ symbol: String?) -> String {
        guard let symbol else { return number }
        return number + "\u{00A0}" + symbol
    }
}
