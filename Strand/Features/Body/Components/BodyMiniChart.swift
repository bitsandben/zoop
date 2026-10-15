#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Mini chart (insight tiles)
//
// The shape of a finding at a glance: no axes, because the number and verdict under it say what it
// shows, and the explainer behind the tap draws the labelled chart (`BodyFindingChart`). Highlights use
// the same colours as the explainer, so the two read alike.

struct BodyMiniChart: View {
    let visual: BodyFindingVisual
    private var muted: Color { StrandPalette.textTertiary.opacity(0.45) }

    var body: some View {
        switch visual {
        case let .line(points, normal, spread, _):
            BodySparkline(points: points, band: (normal - spread)...(normal + spread), muted: false)
        case let .weekdays(means, low, high):
            // Zoomed to the spread, so a few points between weekdays are visible at tile size.
            bars((1...7).compactMap { wd in means[wd].map { (String(wd), $0, color(wd, low: low, high: high)) } },
                 domain: zoomed(Array(means.values)))
        case let .trajectory(values):
            bars(values.enumerated().compactMap { k, v in
                v.map { ("\(k)", $0, $0 >= -ActivityCostEngine.tolerance ? StrandPalette.recovery100 : StrandPalette.statusWarning) }
            }, domain: nil)
        case let .zones(minutes):
            bars((0..<min(5, minutes.count)).map { ("Z\($0 + 1)", minutes[$0], StrandPalette.hrZoneColor($0 + 1)) },
                 domain: nil)
        case let .hours(levels, peak, calm):
            bars(levels.map { h in
                ("\(h.hour)", h.level, h.hour == peak ? StrandPalette.stressHigh : h.hour == calm ? StrandPalette.stressLow : muted)
            }, domain: 0...3)
        case let .scatter(points, slope):
            scatter(points, slope: slope)
        case let .groups(first, second, _, _, _):
            groups(first, second)
        }
    }

    private func color(_ wd: Int, low: Int?, high: Int?) -> Color {
        wd == low ? StrandPalette.statusWarning : wd == high ? StrandPalette.recovery100 : muted
    }

    private func bars(_ items: [(key: String, value: Double, color: Color)], domain: ClosedRange<Double>?) -> some View {
        Chart {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                BarMark(x: .value("Key", item.key), y: .value("Value", item.value), width: .ratio(0.7))
                    .foregroundStyle(item.color)
                    .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain ?? autoDomain(items.map(\.value)))
        // A zoomed floor sits above zero; bars are cut at the plot edge rather than drawn past it.
        .chartPlotStyle { $0.clipped() }
    }

    /// Includes zero, so a bar's height is its value (or its gap to normal when negative).
    private func autoDomain(_ values: [Double]) -> ClosedRange<Double> {
        let lo = min(0, values.min() ?? 0), hi = max(0, values.max() ?? 1)
        return lo == hi ? lo...(lo + 1) : lo...hi
    }

    /// A floor one spread below the lowest value, so the smallest bar keeps a visible height.
    private func zoomed(_ values: [Double]) -> ClosedRange<Double> {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max(hi - lo, 1)
        return max(0, lo - pad)...(hi + pad * 0.1)
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
                    .symbolSize(8)
            }
            ForEach([x0, x1], id: \.self) { x in
                LineMark(x: .value("Effort", x), y: .value("Recovery", my + slope * (x - mx)), series: .value("Fit", "fit"))
                    .foregroundStyle(StrandPalette.effortColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: ((ys.min() ?? 0) - 2)...((ys.max() ?? 100) + 2))
        .chartPlotStyle { $0.clipped() }
    }

    /// Two horizontal bars on one scale: the first group strong, the second muted, as in the explainer.
    private func groups(_ first: Double, _ second: Double) -> some View {
        let top = max(first, second, 1e-9)
        return VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            capsule(first / top, StrandPalette.textPrimary)
            capsule(second / top, muted)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func capsule(_ share: Double, _ color: Color) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(color)
                .frame(width: max(4, geo.size.width * min(max(share, 0), 1)))
        }
        .frame(height: 10)
    }
}
#endif
