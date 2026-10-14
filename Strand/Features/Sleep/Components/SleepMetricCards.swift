import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

/// A list card of metric rows, each opening its explainer.
struct SleepMetricListCard: View {
    let title: LocalizedStringResource
    let metrics: [SleepMetric]
    let onSelect: (SleepMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            SleepSectionTitle(title)
            ListCard {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    SleepMetricRowButton(metric: metric, isFirst: index == 0, onSelect: onSelect)
                }
            }
        }
    }
}

/// A metric row inside a list card, with the hairline above every row but the first.
struct SleepMetricRowButton: View {
    let metric: SleepMetric
    let isFirst: Bool
    let onSelect: (SleepMetric) -> Void

    var body: some View {
        Button { onSelect(metric) } label: { MetricRow(metric.readout) }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                if !isFirst { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
            }
    }
}

/// Section label above a card (§2.4: one component, no overline caps).
struct SleepSectionTitle: View {
    let title: LocalizedStringResource
    var trailing: LocalizedStringResource?

    init(_ title: LocalizedStringResource, trailing: LocalizedStringResource? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ZoopSpacing.s)
            if let trailing {
                Text(trailing).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, ZoopSpacing.xs)
    }
}

/// Sleep debt and regularity, the rolling numbers as of the newest night. The debt row carries the
/// last 14 nights against the need underneath it.
struct SleepRhythmCard: View {
    let overview: SleepOverviewMetrics
    let onSelect: (SleepMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            SleepSectionTitle(SleepStrings.rhythmCard, trailing: SleepStrings.current)
            ListCard {
                SleepMetricRowButton(metric: overview.debt, isFirst: true, onSelect: onSelect)
                if overview.debtNights.count >= 2 {
                    SleepDebtBars(nights: overview.debtNights)
                        .padding(.bottom, ZoopSpacing.m)
                }
                SleepMetricRowButton(metric: overview.regularity, isFirst: false, onSelect: onSelect)
            }
        }
    }
}

/// Each counted night's time asleep minus the need, with the need as the zero line.
struct SleepDebtBars: View {
    let nights: [SleepDebtNight]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(SleepStrings.debtChart)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Chart {
                ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
                    BarMark(x: .value("Night", index), y: .value("Minutes", night.deltaMin))
                        .foregroundStyle(night.deltaMin >= 0 ? StrandPalette.metricPurple
                                                             : StrandPalette.textTertiary.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                RuleMark(y: .value("Need", 0)).zoopReferenceRule()
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: height)
            .accessibilityHidden(true)
        }
    }
}

/// The night's vitals as two-up tiles, each opening its explainer.
struct SleepVitalsGrid: View {
    let metrics: [SleepMetric]
    let onSelect: (SleepMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            SleepSectionTitle(SleepStrings.vitalsCard)
            TileGrid {
                ForEach(metrics) { metric in
                    Button { onSelect(metric) } label: { MetricTile(metric.readout) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}
