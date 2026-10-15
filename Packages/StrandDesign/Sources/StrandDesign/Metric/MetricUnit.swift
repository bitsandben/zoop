import Foundation

// MARK: - MetricUnit
//
// The single place a metric number becomes text, via `FormatStyle` with an explicit locale ("36,4 °C" in
// German, "36.4 °C" in English). Spoken forms come from catalogue templates, not Foundation's wide unit
// names, which are missing for some units depending on ICU data ("62 ms" reads as "62 m s").

public enum MetricUnit: Equatable, Sendable {
    case score(fractionDigits: Int)
    case percent
    case milliseconds
    case beatsPerMinute
    case breathsPerMinute
    case celsius
    /// Absolute temperature, value in °C, shown in °F.
    case fahrenheit
    /// Temperature deviation, value in °C; always signed.
    case celsiusDeviation
    /// Temperature deviation, value in °C, shown in °F: a difference scales by 9/5 without the +32.
    case fahrenheitDeviation
    case kilograms
    /// Mass, value in kg, shown in pounds.
    case pounds
    case kilocalories
    case steps
    case years
    case vo2max
    case duration

    public static let score = MetricUnit.score(fractionDigits: 0)

    /// Display system chosen by the user; the package cannot see the app's `UnitSystem`, so callers map it.
    public enum System: Sendable { case metric, imperial }

    public static func mass(_ system: System) -> MetricUnit { system == .imperial ? .pounds : .kilograms }
    public static func temperature(_ system: System) -> MetricUnit { system == .imperial ? .fahrenheit : .celsius }
    public static func temperatureDeviation(_ system: System) -> MetricUnit {
        system == .imperial ? .fahrenheitDeviation : .celsiusDeviation
    }

    var fractionDigits: Int {
        switch self {
        case .score(let digits): return max(0, digits)
        case .breathsPerMinute, .celsius, .fahrenheit, .celsiusDeviation, .fahrenheitDeviation,
             .kilograms, .pounds, .vo2max: return 1
        default: return 0
        }
    }

    // MARK: Parts

    /// Converts a stored (SI) value to the unit shown. `delta` marks a difference, which has no offset.
    public func displayValue(_ value: Double, delta: Bool = false) -> Double {
        switch self {
        case .fahrenheit: return delta ? value * 9 / 5 : value * 9 / 5 + 32
        case .fahrenheitDeviation: return value * 9 / 5
        case .pounds: return value / 0.45359237
        default: return value
        }
    }

    private var isSigned: Bool { self == .celsiusDeviation || self == .fahrenheitDeviation }

    /// The number alone, as the hero draws it beside a smaller unit symbol.
    public func number(_ value: Double, locale: Locale) -> String {
        if case .duration = self { return Self.duration(value, width: .narrow, locale: locale) }
        var style = numberStyle(locale)
        if isSigned { style = style.sign(strategy: .always(includingZero: false)) }
        return displayValue(value).formatted(style)
    }

    /// Chart axis tick text. `tick` is already in display units, except durations, which stay in
    /// seconds and read as h/min instead of a raw second count.
    public func axisLabel(_ tick: Double, locale: Locale) -> String {
        if case .duration = self { return Self.duration(tick, width: .narrow, locale: locale) }
        return tick.formatted(FloatingPointFormatStyle<Double>(locale: locale)
            .precision(.fractionLength(0...fractionDigits)))
    }

    /// The short unit symbol, or nil when the unit is part of the number (duration) or absent (score).
    public func symbol(locale: Locale) -> String? {
        switch self {
        case .score, .duration: return nil
        case .percent: return "%"
        case .milliseconds: return UnitDuration.milliseconds.symbol
        case .celsius, .celsiusDeviation: return UnitTemperature.celsius.symbol
        case .fahrenheit, .fahrenheitDeviation: return UnitTemperature.fahrenheit.symbol
        case .kilograms: return UnitMass.kilograms.symbol
        case .pounds: return UnitMass.pounds.symbol
        case .kilocalories: return UnitEnergy.kilocalories.symbol
        case .vo2max: return "ml/kg/min"
        case .beatsPerMinute: return MetricStrings.resolve(MetricStrings.bpm, locale: locale)
        case .breathsPerMinute: return MetricStrings.resolve(MetricStrings.breaths, locale: locale)
        case .steps: return MetricStrings.resolve(MetricStrings.steps, locale: locale)
        case .years: return MetricStrings.resolve(MetricStrings.years, locale: locale)
        }
    }

    // MARK: Whole strings

    public func format(_ value: Double, locale: Locale) -> String {
        switch self {
        case .percent:
            return (value / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        default:
            return Self.join(number(value, locale: locale), symbol(locale: locale))
        }
    }

    public func formatDelta(_ delta: Double, locale: Locale) -> String {
        switch self {
        case .duration:
            let sign = delta < 0 ? "-" : "+"
            return sign + Self.duration(abs(delta), width: .narrow, locale: locale)
        case .percent:
            return (delta / 100).formatted(.percent.precision(.fractionLength(0))
                .sign(strategy: .always(includingZero: false)).locale(locale))
        default:
            let n = displayValue(delta, delta: true).formatted(numberStyle(locale).sign(strategy: .always(includingZero: false)))
            return Self.join(n, symbol(locale: locale))
        }
    }

    public func formatRange(_ range: ClosedRange<Double>, locale: Locale) -> String {
        if case .percent = self {
            return format(range.lowerBound, locale: locale) + "–" + format(range.upperBound, locale: locale)
        }
        let lo = plainNumber(range.lowerBound, locale: locale)
        let hi = plainNumber(range.upperBound, locale: locale)
        return Self.join("\(lo)–\(hi)", symbol(locale: locale))
    }

    public func spoken(_ value: Double, locale: Locale) -> String {
        let n = number(value, locale: locale)
        switch self {
        case .score, .percent: return format(value, locale: locale)
        case .duration: return Self.duration(value, width: .wide, locale: locale)
        case .milliseconds: return MetricStrings.resolve(MetricStrings.millisecondsSpoken(n), locale: locale)
        case .celsius, .celsiusDeviation: return MetricStrings.resolve(MetricStrings.celsiusSpoken(n), locale: locale)
        case .fahrenheit, .fahrenheitDeviation: return MetricStrings.resolve(MetricStrings.fahrenheitSpoken(n), locale: locale)
        case .kilograms: return MetricStrings.resolve(MetricStrings.kilogramsSpoken(n), locale: locale)
        case .pounds: return MetricStrings.resolve(MetricStrings.poundsSpoken(n), locale: locale)
        case .kilocalories: return MetricStrings.resolve(MetricStrings.kilocaloriesSpoken(n), locale: locale)
        case .beatsPerMinute: return MetricStrings.resolve(MetricStrings.bpmSpoken(n), locale: locale)
        case .breathsPerMinute: return MetricStrings.resolve(MetricStrings.breathsSpoken(n), locale: locale)
        case .steps: return MetricStrings.resolve(MetricStrings.stepsSpoken(n), locale: locale)
        case .years: return MetricStrings.resolve(MetricStrings.yearsSpoken(n), locale: locale)
        case .vo2max: return MetricStrings.resolve(MetricStrings.vo2maxSpoken(n), locale: locale)
        }
    }

    // MARK: Helpers

    private func plainNumber(_ value: Double, locale: Locale) -> String {
        if case .duration = self { return Self.duration(value, width: .narrow, locale: locale) }
        return displayValue(value).formatted(numberStyle(locale))
    }

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
