import Foundation

// MARK: - MetricExplanation (explainer sheet content)
//
// What the explainer shows beyond the readout: what the metric is, how it is computed, the data that
// went in, why the confidence is what it is, the 30-day trend and what moves it. The sheet only lays it out.

public struct MetricExplanation: Equatable, Sendable {

    public struct Method: Equatable, Sendable {
        public let name: LocalizedStringResource
        public let summary: LocalizedStringResource
        /// Literature reference, e.g. "Plews et al., 2012". Not translated.
        public let citation: String?

        public init(name: LocalizedStringResource, summary: LocalizedStringResource, citation: String? = nil) {
            self.name = name
            self.summary = summary
            self.citation = citation
        }
    }

    public struct DataUsed: Equatable, Sendable {
        public enum Count: Equatable, Sendable {
            case nights(Int), days(Int), samples(Int)
        }
        public let count: Count
        public let window: DateInterval?
        public let source: String?

        public init(count: Count, window: DateInterval? = nil, source: String? = nil) {
            self.count = count
            self.window = window
            self.source = source
        }
    }

    public struct TrendPoint: Equatable, Sendable, Identifiable {
        public let date: Date
        public let value: Double
        public var id: Date { date }

        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    public struct Contributor: Equatable, Sendable, Identifiable {
        public enum Effect: Equatable, Sendable { case raises, lowers, neutral }
        public let id: String
        public let label: LocalizedStringResource
        public let detail: LocalizedStringResource?
        public let effect: Effect

        public init(id: String, label: LocalizedStringResource, detail: LocalizedStringResource? = nil, effect: Effect) {
            self.id = id
            self.label = label
            self.detail = detail
            self.effect = effect
        }
    }

    public let whatItIs: LocalizedStringResource
    public let method: Method
    public let dataUsed: DataUsed
    public let confidenceReason: LocalizedStringResource?
    /// Up to 30 days, oldest first. Missing days are simply absent, so the line breaks there.
    public let trend: [TrendPoint]
    public let contributors: [Contributor]

    public init(
        whatItIs: LocalizedStringResource,
        method: Method,
        dataUsed: DataUsed,
        confidenceReason: LocalizedStringResource? = nil,
        trend: [TrendPoint] = [],
        contributors: [Contributor] = []
    ) {
        self.whatItIs = whatItIs
        self.method = method
        self.dataUsed = dataUsed
        self.confidenceReason = confidenceReason
        self.trend = trend
        self.contributors = contributors
    }
}

extension MetricExplanation.DataUsed {
    /// "14 nights · 1–14 Oct · Source: WHOOP 4.0", in the given locale.
    func summary(locale: Locale) -> String {
        var parts: [String] = []
        let count: LocalizedStringResource
        switch self.count {
        case .nights(let n): count = MetricStrings.nights(n)
        case .days(let n): count = MetricStrings.days(n)
        case .samples(let n): count = MetricStrings.samples(n)
        }
        parts.append(MetricStrings.resolve(count, locale: locale))
        if let window {
            let style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, locale: locale)
            parts.append((window.start..<window.end).formatted(style))
        }
        if let source { parts.append(MetricStrings.resolve(MetricStrings.source(source), locale: locale)) }
        return parts.joined(separator: " · ")
    }
}
