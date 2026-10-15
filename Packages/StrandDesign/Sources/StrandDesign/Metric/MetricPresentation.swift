import Foundation

// MARK: - MetricPresentation
//
// Every string a Metric* view shows or speaks, resolved once per readout and locale, so hero, tile, row
// and explainer word one readout identically and the wording is unit-testable.

public struct MetricPresentation: Equatable, Sendable {
    public let label: String
    public let number: String?
    public let unit: String?
    /// The verdict word, or the unavailable reason that stands in for the number.
    public let verdict: String
    /// Short form of `verdict` for small rings and tiles ("No data" for a long reason).
    public let compactVerdict: String
    public let meaning: String
    public let delta: String?
    public let deltaDirection: DeltaDirection
    /// "Your range 52–68 ms" or "Population range 52–68 ms".
    public let range: String?
    /// Confidence note under the verdict: provisional, dated, or the calibration timeline.
    public let confidenceNote: String?
    /// Spoken after the label: "62 milliseconds, Above your range".
    public let accessibilityValue: String

    public init(_ readout: MetricReadout, locale: Locale) {
        func text(_ r: LocalizedStringResource) -> String { MetricStrings.resolve(r, locale: locale) }
        let unit = readout.unit

        label = text(readout.label)
        verdict = text(readout.verdict.text(rangeIsPersonal: readout.rangeIsPersonal, polarity: readout.polarity))
        compactVerdict = readout.verdict.isUnavailable ? text(readout.verdict.compactText) : verdict
        meaning = text(readout.meaning)

        if let value = readout.displayValue {
            number = unit.number(value, locale: locale)
            self.unit = unit.symbol(locale: locale)
            accessibilityValue = unit.spoken(value, locale: locale) + ", " + verdict
        } else {
            number = nil
            self.unit = nil
            accessibilityValue = verdict
        }

        if readout.displayValue != nil, let d = readout.delta {
            let signed = unit.formatDelta(d, locale: locale)
            delta = text(readout.deltaReference == .typical ? MetricStrings.vsTypical(signed)
                                                            : MetricStrings.vsYesterday(signed))
            deltaDirection = readout.deltaDirection
        } else {
            delta = nil
            deltaDirection = .flat
        }

        if let r = readout.typicalRange {
            let formatted = unit.formatRange(r, locale: locale)
            range = text(readout.rangeIsPersonal ? MetricStrings.yourRange(formatted)
                                                 : MetricStrings.populationRangeValue(formatted))
        } else {
            range = nil
        }

        confidenceNote = Self.note(for: readout).map(text)
    }

    static func note(for readout: MetricReadout) -> LocalizedStringResource? {
        if case .unavailable = readout.verdict { return nil }
        switch readout.confidence {
        case .solid: return nil
        case .building: return MetricStrings.provisional
        case .stale(let since): return MetricStrings.asOf(since)
        case .calibrating(let nights): return MetricStrings.populationRange(nightsLeft: max(nights, 1))
        }
    }

    static func confidenceTitle(_ confidence: MetricReadout.Confidence) -> LocalizedStringResource {
        switch confidence {
        case .solid: return MetricStrings.calibrated
        case .building: return MetricStrings.provisional
        case .calibrating: return MetricStrings.calibrating
        case .stale(let since): return MetricStrings.asOf(since)
        }
    }
}
