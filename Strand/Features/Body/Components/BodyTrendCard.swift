#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// MARK: - Trend card (pick a metric and a window)
//
// Title (what), personal band and dashed mean (compared to what), one-sentence takeaway (so what):
// §7.4. Days without a value break the line instead of being bridged.

struct BodyTrendCard: View {
    @ObservedObject var model: BodyModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            BodySectionTitle(title: BodyStrings.trendsTitle)
            ContentCard {
                VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                    HStack {
                        Picker(selection: $model.trendMetric) {
                            ForEach(BodyTrendMetric.allCases) { Text($0.label).tag($0) }
                        } label: { Text(BodyStrings.trendMetricPicker) }
                        .pickerStyle(.menu)
                        .tint(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    Picker(selection: $model.trendWindow) {
                        ForEach(BodyTrendWindow.allCases) { Text($0.label).tag($0) }
                    } label: { Text(BodyStrings.trendWindowPicker) }
                    .pickerStyle(.segmented)
                    if let trend = model.trend {
                        Text(trend.takeaway)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if trend.mean != nil {
                            BodyTrendChart(trend: trend).frame(height: 180)
                        }
                        Text(trend.bandNote)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct BodyTrendChart: View {
    let trend: BodyTrend

    var body: some View {
        let segments = BodyTrendChart.segments(trend.points)
        let tint = StrandPalette.textPrimary
        Chart {
            if let band = trend.band, let first = trend.points.first, let last = trend.points.last {
                ZoopBandMark(x: .value("Day", first.date), low: band.lowerBound, high: band.upperBound,
                             color: StrandPalette.metricPurple)
                ZoopBandMark(x: .value("Day", last.date), low: band.lowerBound, high: band.upperBound,
                             color: StrandPalette.metricPurple)
            }
            if let mean = trend.mean {
                RuleMark(y: .value("Average", mean)).zoopReferenceRule()
            }
            ForEach(segments.indices, id: \.self) { i in
                ForEach(segments[i]) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Value", p.value), series: .value("Series", "s\(i)"))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                    if segments[i].count == 1 {
                        PointMark(x: .value("Day", p.date), y: .value("Value", p.value)).foregroundStyle(tint)
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .zoopYAxis { trend.unit.number($0, locale: BodyFormat.locale) }
        .zoopDayXAxis(days: trend.window.rawValue)
        .accessibilityLabel(Text(trend.takeaway))
    }

    /// Splits the points wherever consecutive days are more than a day and a half apart.
    static func segments(_ points: [MetricExplanation.TrendPoint]) -> [[MetricExplanation.TrendPoint]] {
        var out: [[MetricExplanation.TrendPoint]] = []
        for p in points {
            if let last = out.last?.last, p.date.timeIntervalSince(last.date) <= 36 * 3600 {
                out[out.count - 1].append(p)
            } else {
                out.append([p])
            }
        }
        return out
    }
}
#endif
