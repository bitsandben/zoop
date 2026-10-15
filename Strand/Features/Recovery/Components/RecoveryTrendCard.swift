import SwiftUI
import Charts
import StrandDesign

/// 30 or 90 days of Recovery as bars coloured by band, the personal range behind them and the average
/// as a dashed line. Days without a score leave a gap; nothing is drawn as zero.
struct RecoveryTrendCard: View {
    let days: [RecoveryTrendDay]
    let band: ClosedRange<Double>?

    @State private var window = 30
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 180

    var body: some View {
        ContentCard("zoop.recovery.trend.title") {
            if shown.count < 2 {
                Text(RecoveryStrings.trendEmpty).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Picker("", selection: $window) {
                    Text(RecoveryStrings.trend30).tag(30)
                    Text(RecoveryStrings.trend90).tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                chart
                Text(RecoveryStrings.trendAverage(MetricUnit.percent.format(average, locale: locale)))
                    .font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var shown: [RecoveryTrendDay] {
        guard let last = days.last?.date,
              let cutoff = Calendar.current.date(byAdding: .day, value: -window, to: last) else { return days }
        return days.filter { $0.date > cutoff }
    }

    private var average: Double {
        shown.reduce(0) { $0 + $1.value } / Double(max(shown.count, 1))
    }

    private var chart: some View {
        Chart {
            if let band, let first = shown.first?.date, let last = shown.last?.date {
                ForEach([first, last], id: \.self) { day in
                    ZoopBandMark(x: .value("Day", day), low: band.lowerBound, high: band.upperBound,
                                 color: StrandPalette.textSecondary)
                }
            }
            RuleMark(y: .value("Average", average)).zoopReferenceRule()
            ForEach(shown) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Recovery", day.value))
                    .foregroundStyle(StrandPalette.recoveryColor(day.value))
            }
        }
        .chartYScale(domain: 0...100)
        .zoopYAxis { MetricUnit.percent.format($0, locale: locale) }
        .zoopDayXAxis(days: window)
        .frame(height: chartHeight)
        .accessibilityLabel(Text(RecoveryStrings.trendChartLabel))
    }
}
