import SwiftUI
import Charts

// MARK: - Chart style helpers (Zoop 2.0 §7.4)
//
// Small, composable pieces so every Swift Charts chart gets the same axes, gridlines, band and
// reference line without re-deriving them. Pure styling: no data logic.

public enum ZoopChartStyle {
    /// Band fill opacity (personal range) in the metric colour.
    public static let bandOpacity: Double = 0.15
    /// Gridlines stay quiet so data leads.
    public static let gridOpacity: Double = 0.4
    /// Reference-line stroke: 1 pt dashed.
    public static let ruleStroke = StrokeStyle(lineWidth: 1, dash: [4, 3])
    /// Scrub indicator stroke: solid hairline.
    public static let scrubStroke = StrokeStyle(lineWidth: 1)
    /// Maximum y-axis labels.
    public static let maxYLabels = 4
}

public extension View {
    /// Y axis on the trailing edge with at most four labels and quiet gridlines. `format` renders a
    /// label (pass a locale-aware formatter; the default is plain `description`).
    func zoopYAxis(format: @escaping (Double) -> String = { "\(Int($0.rounded()))" }) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: ZoopChartStyle.maxYLabels)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(ZoopChartStyle.gridOpacity))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)).font(ZoopType.caption) }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// X axis for a day range: weekday letters for 7 days, short dates for 30/90 days. Locale-aware
    /// through `Date.FormatStyle`.
    func zoopDayXAxis(days: Int) -> some View {
        chartXAxis {
            if days <= 7 {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }
}

// MARK: - Marks

/// Personal-range band: an `AreaMark` at 15 % in the metric colour between `low` and `high`.
public struct ZoopBandMark<X: Plottable>: ChartContent {
    let x: PlottableValue<X>
    let low: Double
    let high: Double
    let color: Color

    public init(x: PlottableValue<X>, low: Double, high: Double, color: Color) {
        self.x = x; self.low = low; self.high = high; self.color = color
    }

    public var body: some ChartContent {
        AreaMark(x: x, yStart: .value("Low", low), yEnd: .value("High", high))
            .foregroundStyle(color.opacity(ZoopChartStyle.bandOpacity))
            .interpolationMethod(.monotone)
    }
}

public extension ChartContent {
    /// Style a `RuleMark` as the dashed 1 pt mean / reference line.
    func zoopReferenceRule(color: Color = StrandPalette.textTertiary) -> some ChartContent {
        foregroundStyle(color).lineStyle(ZoopChartStyle.ruleStroke)
    }

    /// Style a `RuleMark` as the scrub (drag selection) indicator.
    func zoopScrubRule() -> some ChartContent {
        foregroundStyle(StrandPalette.textSecondary).lineStyle(ZoopChartStyle.scrubStroke)
    }
}

/// Faint rectangle for a data gap longer than an hour, so the line is visibly interrupted instead
/// of drawn across missing data.
public struct ZoopGapMark<X: Plottable>: ChartContent {
    let from: PlottableValue<X>
    let to: PlottableValue<X>

    public init(from: PlottableValue<X>, to: PlottableValue<X>) { self.from = from; self.to = to }

    public var body: some ChartContent {
        RectangleMark(xStart: from, xEnd: to)
            .foregroundStyle(StrandPalette.hairline.opacity(0.35))
    }
}
