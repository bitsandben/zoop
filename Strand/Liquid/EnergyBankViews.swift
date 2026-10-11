#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Energy Bank (Zoop iOS)
//
// Home's Energy Bank card and its detail screen. Both read `EnergyBankDay.today`, so the card and the
// screen show one estimate. The level is an estimate (see `EnergyBank` in StrandAnalytics).

/// Loads today's Energy Bank and keeps it fresh: on every data refresh and every three minutes while
/// the view is on screen.
private struct EnergyBankLoader: ViewModifier {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Binding var result: EnergyBank.Result?

    func body(content: Content) -> some View {
        content
            .task(id: repo.refreshSeq) { await load() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    guard !Task.isCancelled else { break }
                    await load()
                }
            }
    }

    private func load() async {
        result = await EnergyBankDay.today(repo: repo, maxHR: profile.effortHRmax)
    }
}

extension EnergyBank.Result {
    var currentRounded: Int { Int(current.rounded()) }
}

private func energyTint(_ level: Double) -> Color { StrandPalette.recoveryColor(level) }

/// The full-width Home card: the current level out of 100, today's charged and drained totals, and a
/// faint line of the day's level along the bottom.
struct HomeEnergyBankCard: View {
    @State private var result: EnergyBank.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
            HStack(spacing: 6) {
                Text("Energy Bank")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(result.map { "\($0.currentRounded)" } ?? "–")
                    .font(StrandFont.display(34))
                    .foregroundStyle(result.map { energyTint($0.current) } ?? StrandPalette.textSecondary)
                if result != nil {
                    Text(verbatim: "/ 100")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Text(result.map { String(localized: "+\(Int($0.charged.rounded())) charged · −\(Int($0.drained.rounded())) drained") }
                 ?? String(localized: "No readings yet"))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(alignment: .bottom) {
            EnergyBankSparkline(points: result?.timeline ?? [],
                                tint: result.map { energyTint($0.current) } ?? StrandPalette.textTertiary)
        }
        .background(ZoopPanelSurface(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .modifier(EnergyBankLoader(result: $result))
        .accessibilityElement(children: .combine)
    }
}

/// A faint area line of the day's level (0–100) along the bottom of the card.
private struct EnergyBankSparkline: View {
    let points: [EnergyBank.Point]
    let tint: Color

    var body: some View {
        if points.count >= 2 {
            GeometryReader { g in
                let minX = Double(points[0].ts), maxX = max(Double(points[points.count - 1].ts), minX + 1)
                let h = g.size.height
                let point: (EnergyBank.Point) -> CGPoint = { p in
                    CGPoint(x: (Double(p.ts) - minX) / (maxX - minX) * g.size.width,
                            y: h - CGFloat(p.level / 100) * h * 0.9)
                }
                let line = Path { path in
                    path.move(to: point(points[0]))
                    for p in points.dropFirst() { path.addLine(to: point(p)) }
                }
                let area = Path { path in
                    path.move(to: CGPoint(x: point(points[0]).x, y: h))
                    for p in points { path.addLine(to: point(p)) }
                    path.addLine(to: CGPoint(x: point(points[points.count - 1]).x, y: h))
                    path.closeSubpath()
                }
                ZStack {
                    area.fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    line.stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 70)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The Energy Bank screen: the level over the day (scrubbable, sleep shaded), the day's totals, and
/// one sentence on what fills and drains it.
struct EnergyBankScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var result: EnergyBank.Result?
    @State private var scrubbed: EnergyBank.Point?

    var body: some View {
        ScreenScaffold(title: "Energy Bank") {
            VStack(alignment: .leading, spacing: 14) {
                hero
                if let r = result { totals(r) }
                Text("Sleep and calm rest fill it; activity, stress and simply being awake drain it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
        .modifier(EnergyBankLoader(result: $result))
    }

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private var hero: some View {
        let shown = scrubbed ?? result?.timeline.last
        return VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Text(scrubbed.map { date($0.ts).formatted(date: .omitted, time: .shortened) } ?? String(localized: "Now"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                Text(shown.map { "\(Int($0.level.rounded()))" } ?? "–")
                    .font(StrandFont.display(52))
                    .foregroundStyle(shown.map { energyTint($0.level) } ?? StrandPalette.textSecondary)
                Text(verbatim: "/ 100")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let r = result, r.timeline.count >= 2 {
                chart(r).frame(height: 200)
            } else {
                Text("No readings yet")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }

    private func totals(_ r: EnergyBank.Result) -> some View {
        HStack(spacing: 0) {
            stat("This morning", "\(Int(r.morning.rounded()))")
            stat("Charged", "+\(Int(r.charged.rounded()))")
            stat("Drained", "−\(Int(r.drained.rounded()))")
        }
        .padding(16)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sleep spans inside the plotted window, to shade behind the curve.
    private func sleepSpans(first: Int, last: Int) -> [(start: Int, end: Int)] {
        repo.sleeps.compactMap { s in
            let lo = max(s.effectiveStartTs, first), hi = min(s.endTs, last)
            return lo < hi ? (lo, hi) : nil
        }
    }

    private func chart(_ r: EnergyBank.Result) -> some View {
        let points = r.timeline
        let first = points.first?.ts ?? 0, last = points.last?.ts ?? 0
        return Chart {
            ForEach(Array(sleepSpans(first: first, last: last).enumerated()), id: \.offset) { _, s in
                RectangleMark(xStart: .value("Sleep start", date(s.start)), xEnd: .value("Sleep end", date(s.end)),
                              yStart: .value("Low", 0), yEnd: .value("High", 100))
                    .foregroundStyle(StrandPalette.restColor.opacity(0.14))
            }
            ForEach(points, id: \.ts) { p in
                AreaMark(x: .value("Time", date(p.ts)), y: .value("Energy", p.level))
                    .foregroundStyle(LinearGradient(colors: [energyTint(r.current).opacity(0.22), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", date(p.ts)), y: .value("Energy", p.level))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let s = scrubbed {
                RuleMark(x: .value("Selected", date(s.ts)))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.5))
                PointMark(x: .value("Selected", date(s.ts)), y: .value("Energy", s.level))
                    .symbol { Circle().fill(energyTint(s.level)).frame(width: 10, height: 10) }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
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
                        scrubbed = points.min(by: { abs($0.ts - t) < abs($1.ts - t) })
                    }, onEnd: { scrubbed = nil })
            }
        }
    }
}
#endif
