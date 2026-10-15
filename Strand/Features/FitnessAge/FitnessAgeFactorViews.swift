#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// MARK: - Factor list
//
// One card of factor rows. Each row is built from a `MetricReadout`, so the value, the range it is
// scored against and the verdict word come from the same anatomy as every other metric in the app.

struct FitnessFactorList: View {
    let items: [FitnessFactorItem]
    let onSelect: (FitnessFactorItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, ZoopSpacing.l)
                }
                Button { onSelect(item) } label: { FitnessFactorRow(item: item) }
                    .buttonStyle(.plain)
            }
        }
        .zoopInsetSurface(radius: ZoopRadius.tile)
        .clipShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
    }
}

/// One factor: name and value, the verdict and trend, the years it adds (+) or removes (−), the range
/// it is scored against and a sparkline of the last 60 days.
struct FitnessFactorRow: View {
    let item: FitnessFactorItem
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    private var years: Double { item.years }

    private var yearsTint: Color {
        years < -0.05 ? StrandPalette.statusPositive
            : years > 0.05 ? StrandPalette.statusWarning : StrandPalette.textSecondary
    }

    var body: some View {
        let p = MetricPresentation(item.readout, locale: locale)
        let signed = fitnessSignedYears(years)
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                Text(verbatim: p.label)
                    .font(StrandFont.ui(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let number = p.number {
                    (Text(verbatim: number).font(StrandFont.bodyNumber.weight(.semibold))
                        + Text(verbatim: p.unit.map { "\u{00A0}" + $0 } ?? "").font(StrandFont.captionNumber))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(alignment: .center, spacing: ZoopSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: p.verdict)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: 4) {
                        Image(systemName: item.trend.icon)
                            .font(ZoopType.icon(11, weight: .semibold))
                        Text(item.trend.word)
                    }
                    .foregroundStyle(item.trend.tint)
                }
                .font(StrandFont.footnote.weight(.medium))
                Spacer(minLength: 6)
                if !typeSize.isAccessibilitySize {
                    FitnessSparkline(points: item.spark, tint: item.trend.tint)
                        .frame(width: 64, height: 28)
                }
                Text(FitnessAgeStrings.years(signed))
                    .font(StrandFont.ui(15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(yearsTint)
                    .frame(minWidth: 62, alignment: .trailing)
            }
            MetricRangeBar(item.readout)
            if let range = p.range {
                Text(verbatim: range)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, ZoopSpacing.l)
        .padding(.vertical, ZoopSpacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(p.label), \(p.accessibilityValue)"))
        .accessibilityValue(Text(FitnessAgeStrings.yearsSpoken(signed)))
        .accessibilityHint(Text(verbatim: p.meaning))
    }
}

/// A small line of a factor's recent values, its average as a dotted rule and a dot on the latest.
struct FitnessSparkline: View {
    let points: FitnessSeries
    let tint: Color

    var body: some View {
        let pts = points.compactMap { p in fitnessDayDate(p.day).map { (date: $0, value: p.value) } }
        if pts.count >= 2, let last = pts.last {
            let mean = pts.map(\.value).reduce(0, +) / Double(pts.count)
            Chart {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
                ForEach(pts, id: \.date) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                    .foregroundStyle(tint)
                    .symbolSize(22)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}
#endif
