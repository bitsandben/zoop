import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - StressNowCard (CONCEPT §3.5)
//
// The screen's hero: the current stress level with its full anatomy, and today's curve beneath it with
// sleep shaded and exertion hours hatched. Scrubbing the curve swaps the readout to the point under the
// finger, label included, so the number and the time it belongs to cannot disagree.

struct StressNowCard: View {
    @ObservedObject var model: StressScreenModel
    let onInfo: () -> Void

    @State private var scrubbed: DaytimeStress.HourPoint?

    /// A gap longer than this between two scored points is exertion or missing data, not a line to draw.
    private static let breakSeconds = 2_700

    var body: some View {
        HeroCard {
            Button(action: onInfo) {
                MetricHero(model.readout(scrubbed: scrubbed))
            }
            .buttonStyle(.plain)
            curve
        }
    }

    @ViewBuilder
    private var curve: some View {
        let points = model.points
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                chart(points).frame(height: 190)
                footnotes
            }
        } else if model.day == nil {
            Text(StressStrings.loading).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
        } else {
            Text(StressStrings.curveEmpty).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnotes: some View {
        let lines = [model.sleeps.isEmpty ? nil : String(localized: StressStrings.sleepShade),
                     stressActivityMaskedHoursCaption(model.day?.activityMaskedHours ?? 0)].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    /// Consecutive scored points, split wherever the line should not bridge.
    private func runs(_ points: [DaytimeStress.HourPoint]) -> [[DaytimeStress.HourPoint]] {
        var out: [[DaytimeStress.HourPoint]] = []
        for p in points {
            if let last = out.last?.last, p.startTs - last.startTs <= Self.breakSeconds {
                out[out.count - 1].append(p)
            } else {
                out.append([p])
            }
        }
        return out
    }

    private func chart(_ points: [DaytimeStress.HourPoint]) -> some View {
        let first = date(points.first?.startTs ?? 0), last = date(points.last?.startTs ?? 0)
        return Chart {
            ForEach(Array(model.sleeps.enumerated()), id: \.offset) { _, s in
                let lo = max(date(s.start), first), hi = min(date(s.end), last)
                if lo < hi {
                    RectangleMark(xStart: .value("Sleep start", lo), xEnd: .value("Sleep end", hi),
                                  yStart: .value("Low", 0), yEnd: .value("High", 3))
                        .foregroundStyle(StrandPalette.restColor.opacity(0.14))
                }
            }
            ForEach((model.day?.hours ?? []).filter(\.maskedForActivity), id: \.startTs) { h in
                let lo = max(date(h.startTs), first), hi = min(date(h.startTs + 3600), last)
                if lo < hi { ZoopGapMark(from: .value("Moving start", lo), to: .value("Moving end", hi)) }
            }
            ForEach(Array(runs(points).enumerated()), id: \.offset) { index, run in
                ForEach(run, id: \.startTs) { p in
                    AreaMark(x: .value("Time", date(p.startTs)), y: .value("Stress", p.level ?? 0),
                             series: .value("Run", index))
                        .foregroundStyle(LinearGradient(colors: [StrandPalette.stressHigh.opacity(0.22), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", date(p.startTs)), y: .value("Stress", p.level ?? 0),
                             series: .value("Run", index))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let s = scrubbed, let level = s.level {
                RuleMark(x: .value("Selected", date(s.startTs))).zoopScrubRule()
                PointMark(x: .value("Selected", date(s.startTs)), y: .value("Stress", level))
                    .symbol { Circle().fill(StressRamp.color(level)).frame(width: 10, height: 10) }
            }
        }
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(ZoopChartStyle.gridOpacity))
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
        .accessibilityLabel(Text(StressStrings.curveSummary))
    }
}
