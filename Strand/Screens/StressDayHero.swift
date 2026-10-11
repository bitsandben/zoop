#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Stress day hero (Zoop iOS)
//
// The top of the Stress screen: the current stress level, large, read from today's intraday curve (the
// same sliding 0–3 heart-rate read the curve is drawn from), and that curve underneath with the hours you
// slept shaded. Scrubbing the curve shows the reading under the finger in the header. When the day has no
// intraday reading yet, the header falls back to the morning's daily score and says so.

struct StressDayHero: View {
    let hours: [DaytimeStress.HourPoint]
    /// Sleep spans (unix seconds) to shade on the curve.
    let sleeps: [(start: Int, end: Int)]
    /// The morning's daily score, used only while the day has no intraday reading.
    let fallbackScore: Double?

    @State private var scrubbed: DaytimeStress.HourPoint?

    private var points: [DaytimeStress.HourPoint] { hours.filter { $0.level != nil } }
    private var current: DaytimeStress.HourPoint? { points.last }

    var body: some View {
        let shown = scrubbed ?? current
        let value = shown?.level ?? fallbackScore
        VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Text(headerLabel(shown))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                    .font(StrandFont.display(52))
                    .foregroundStyle(value.map { HomeStressMonitorTile.tint(StressBand(score: $0)) } ?? StrandPalette.textSecondary)
                Text(verbatim: "/ 3")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let value {
                    Text(HomeStressMonitorTile.bandName(StressBand(score: value)))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.leading, ZoopMetrics.space1)
                }
            }
            if points.count >= 2 {
                chart.frame(height: 190)
            } else {
                Text("The curve fills in as the strap records your heart rate through the day.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }

    private func headerLabel(_ p: DaytimeStress.HourPoint?) -> String {
        if let s = scrubbed {
            return Date(timeIntervalSince1970: TimeInterval(s.startTs)).formatted(date: .omitted, time: .shortened)
        }
        if current != nil { return String(localized: "Now") }
        return String(localized: "This morning")
    }

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private var chart: some View {
        let first = points.first.map { date($0.startTs) } ?? Date()
        let last = points.last.map { date($0.startTs) } ?? Date()
        return Chart {
            // Sleep, clipped to the plotted window, as a quiet band behind the curve.
            ForEach(Array(sleeps.enumerated()), id: \.offset) { _, s in
                let lo = max(date(s.start), first), hi = min(date(s.end), last)
                if lo < hi {
                    RectangleMark(xStart: .value("Sleep start", lo), xEnd: .value("Sleep end", hi),
                                  yStart: .value("Low", 0), yEnd: .value("High", 3))
                        .foregroundStyle(StrandPalette.restColor.opacity(0.14))
                }
            }
            ForEach(points, id: \.startTs) { p in
                AreaMark(x: .value("Time", date(p.startTs)), y: .value("Stress", p.level ?? 0))
                    .foregroundStyle(LinearGradient(colors: [StrandPalette.stressHigh.opacity(0.22), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", date(p.startTs)), y: .value("Stress", p.level ?? 0))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let s = scrubbed, let l = s.level {
                RuleMark(x: .value("Selected", date(s.startTs)))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.5))
                PointMark(x: .value("Selected", date(s.startTs)), y: .value("Stress", l))
                    .symbol { Circle().fill(HomeStressMonitorTile.tint(StressBand(score: l))).frame(width: 10, height: 10) }
            }
        }
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                Color.clear
                    .contentShape(Rectangle())
                    .zoopChartScrub(onChange: { location in
                        let x = min(max(location.x, plot.minX), plot.maxX) - plot.minX
                        guard let d: Date = proxy.value(atX: x) else { return }
                        let t = Int(d.timeIntervalSince1970)
                        scrubbed = points.min(by: { abs($0.startTs - t) < abs($1.startTs - t) })
                    }, onEnd: { scrubbed = nil })
            }
        }
    }
}

/// The current stress level from today's intraday curve: its latest scored point, or nil.
func liveStressLevel(_ hours: [DaytimeStress.HourPoint]) -> Double? {
    hours.last(where: { $0.level != nil })?.level
}
#endif
