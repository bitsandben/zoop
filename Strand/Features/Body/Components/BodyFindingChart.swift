#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Finding charts (explainer)
//
// Every chart has labelled axes and, where a normal exists, the band and a dashed reference line
// (§7.4). The tiles draw an axis-free `BodyMiniChart` beside the number and verdict that label it.

struct BodyFindingChart: View {
    let visual: BodyFindingVisual
    private var locale: Locale { BodyFormat.locale }
    private var muted: Color { StrandPalette.textTertiary.opacity(0.5) }

    var body: some View {
        switch visual {
        case let .line(points, normal, spread, unit): line(points, normal: normal, spread: spread, unit: unit)
        case let .weekdays(means, low, high): weekdays(means, low: low, high: high)
        case let .trajectory(values): trajectory(values)
        case let .zones(minutes): zones(minutes)
        case let .hours(levels, peak, calm): hours(levels, peak: peak, calm: calm)
        case let .scatter(points, slope): scatter(points, slope: slope)
        case let .groups(first, second, firstLabel, secondLabel, unit):
            groups(first, second, String(localized: firstLabel), String(localized: secondLabel), unit: unit)
        }
    }

    private func line(_ points: [MetricExplanation.TrendPoint], normal: Double, spread: Double,
                      unit: MetricUnit) -> some View {
        Chart {
            if let first = points.first, let last = points.last {
                ZoopBandMark(x: .value("Day", first.date), low: normal - spread, high: normal + spread, color: StrandPalette.metricPurple)
                ZoopBandMark(x: .value("Day", last.date), low: normal - spread, high: normal + spread, color: StrandPalette.metricPurple)
            }
            RuleMark(y: .value("Normal", normal)).zoopReferenceRule()
            ForEach(points) { p in
                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                    .foregroundStyle(StrandPalette.metricPurple)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .zoopYAxis { unit.number($0, locale: locale) }
        .zoopDayXAxis(days: 30)
    }

    private func weekdays(_ means: [Int: Double], low: Int?, high: Int?) -> some View {
        Chart {
            ForEach(1...7, id: \.self) { wd in
                if let m = means[wd] {
                    BarMark(x: .value("Weekday", BodyFormat.shortWeekday(wd)), y: .value("Recovery", m))
                        .foregroundStyle(wd == low ? StrandPalette.statusWarning
                                         : wd == high ? StrandPalette.recovery100 : muted)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .zoopYAxis { MetricUnit.percent.format($0, locale: locale) }
    }

    private func trajectory(_ values: [Double?]) -> some View {
        Chart {
            RuleMark(y: .value("Normal", 0)).zoopReferenceRule()
            ForEach(Array(values.enumerated()), id: \.offset) { k, v in
                if let v {
                    BarMark(x: .value("Day", k == 0 ? String(localized: BodyStrings.hardDay) : "+\(k)"),
                            y: .value("Gap", v))
                        .foregroundStyle(v >= -ActivityCostEngine.tolerance ? StrandPalette.recovery100 : StrandPalette.statusWarning)
                }
            }
        }
        .zoopYAxis { MetricUnit.score.formatDelta($0, locale: locale) }
    }

    private func zones(_ minutes: [Double]) -> some View {
        Chart {
            ForEach(0..<min(5, minutes.count), id: \.self) { i in
                BarMark(x: .value("Zone", "Z\(i + 1)"), y: .value("Minutes", minutes[i]))
                    .foregroundStyle(StrandPalette.hrZoneColor(i + 1))
            }
        }
        .zoopYAxis { MetricUnit.duration.format($0 * 60, locale: locale) }
    }

    private func hours(_ levels: [BodyInsights.HourLevel], peak: Int, calm: Int) -> some View {
        Chart {
            ForEach(levels, id: \.hour) { h in
                BarMark(x: .value("Hour", h.hour), y: .value("Stress", h.level), width: .ratio(0.7))
                    .foregroundStyle(h.hour == peak ? StrandPalette.stressHigh : h.hour == calm ? StrandPalette.stressLow : muted)
            }
        }
        .chartYScale(domain: 0...3)
        .chartXAxis {
            AxisMarks(values: .stride(by: 4)) { value in
                AxisValueLabel { if let h = value.as(Int.self) { Text(verbatim: BodyFormat.clock(hour: h)) } }
            }
        }
        .zoopYAxis { MetricUnit.score(fractionDigits: 1).format($0, locale: locale) }
    }

    private func scatter(_ points: [BodyInsights.StrainSensitivity.Pair], slope: Double) -> some View {
        let xs = points.map(\.strain), ys = points.map(\.recovery)
        let mx = xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        let my = ys.isEmpty ? 0 : ys.reduce(0, +) / Double(ys.count)
        let x0 = xs.min() ?? 0, x1 = xs.max() ?? 1
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("Effort", p.strain), y: .value("Recovery", p.recovery))
                    .foregroundStyle(muted)
                    .symbolSize(24)
            }
            ForEach([x0, x1], id: \.self) { x in
                LineMark(x: .value("Effort", x), y: .value("Recovery", my + slope * (x - mx)), series: .value("Fit", "fit"))
                    .foregroundStyle(StrandPalette.effortColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartYScale(domain: 0...100)
        .zoopYAxis { MetricUnit.percent.format($0, locale: locale) }
    }

    private func groups(_ first: Double, _ second: Double, _ firstLabel: String, _ secondLabel: String,
                        unit: MetricUnit) -> some View {
        Chart {
            BarMark(x: .value("Group", firstLabel), y: .value("Value", first))
                .foregroundStyle(StrandPalette.textPrimary)
                .annotation(position: .top) { Text(verbatim: unit.format(first, locale: locale)).font(ZoopType.caption) }
            BarMark(x: .value("Group", secondLabel), y: .value("Value", second))
                .foregroundStyle(muted)
                .annotation(position: .top) { Text(verbatim: unit.format(second, locale: locale)).font(ZoopType.caption) }
        }
        .zoopYAxis { unit.number($0, locale: locale) }
    }
}
#endif
