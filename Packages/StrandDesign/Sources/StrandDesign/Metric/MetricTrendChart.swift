import SwiftUI
import Charts

// MARK: - MetricTrendChart (explainer "Your trend")
//
// 30-day line against the personal band (15 % area, mean as a 1 pt dashed rule). A day without data
// breaks the line rather than bridging it, so a gap never reads as a trend.

enum MetricTrendSegments {
    /// Splits points (oldest first) wherever consecutive days are more than `maxGap` apart.
    static func split(_ points: [MetricExplanation.TrendPoint],
                      maxGap: TimeInterval = 36 * 3600) -> [[MetricExplanation.TrendPoint]] {
        var segments: [[MetricExplanation.TrendPoint]] = []
        for point in points {
            if let last = segments.last?.last, point.date.timeIntervalSince(last.date) <= maxGap {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        return segments
    }
}

struct MetricTrendChart: View {
    let readout: MetricReadout
    let points: [MetricExplanation.TrendPoint]
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 160

    var body: some View {
        let tint = MetricStyle.tint(readout)
        let unit = readout.unit
        let segments = MetricTrendSegments.split(points)
        Chart {
            if let range = readout.typicalRange, let first = points.first, let last = points.last {
                ForEach([first.date, last.date], id: \.self) { day in
                    AreaMark(x: .value("Day", day),
                             yStart: .value("Low", unit.displayValue(range.lowerBound)),
                             yEnd: .value("High", unit.displayValue(range.upperBound)),
                             series: .value("Series", "band"))
                        .foregroundStyle(tint.opacity(0.15))
                }
                RuleMark(y: .value("Typical", unit.displayValue((range.lowerBound + range.upperBound) / 2)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(tint.opacity(0.6))
            }
            ForEach(segments.indices, id: \.self) { index in
                ForEach(segments[index]) { point in
                    LineMark(x: .value("Day", point.date),
                             y: .value("Value", unit.displayValue(point.value)),
                             series: .value("Series", "line\(index)"))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    // A lone day between gaps has no line to sit on.
                    if segments[index].count == 1 {
                        PointMark(x: .value("Day", point.date), y: .value("Value", unit.displayValue(point.value)))
                            .foregroundStyle(tint)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let tick = mark.as(Double.self) { Text(verbatim: unit.axisLabel(tick, locale: locale)) }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: height)
        .accessibilityLabel(Text(MetricStrings.trend))
    }
}
