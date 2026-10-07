#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// MARK: - Trend viewer
//
// One metric over a week, a month or six months: its average, the change against the period before,
// a sentence saying which way it moved, and the chart with the average line and (for vitals) the band
// the previous period held. Reads only the daily rows Trends already has.

struct TrendViewerCard: View {
    let days: [DailyMetric]            // oldest → newest
    let effortScale: EffortScale

    enum Metric: String, CaseIterable, Identifiable {
        case recovery, hrv, rhr, sleep, strain, steps, resp
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .recovery: return "Recovery"
            case .hrv: return "Heart Rate Variability"
            case .rhr: return "Resting Heart Rate"
            case .sleep: return "Hours of Sleep"
            case .strain: return "Strain"
            case .steps: return "Steps"
            case .resp: return "Respiratory Rate"
            }
        }

        var icon: String {
            switch self {
            case .recovery: return "heart.circle"
            case .hrv: return "waveform.path.ecg"
            case .rhr: return "heart"
            case .sleep: return "bed.double"
            case .strain: return "bolt"
            case .steps: return "figure.walk"
            case .resp: return "lungs"
            }
        }

        var unit: String {
            switch self {
            case .recovery: return "%"
            case .hrv: return "ms"
            case .rhr: return "bpm"
            case .sleep: return "h"
            case .strain, .steps: return ""
            case .resp: return "rpm"
            }
        }

        /// Whether a rise is good news (nil: neither, as for strain).
        var higherIsBetter: Bool? {
            switch self {
            case .recovery, .hrv, .sleep, .steps: return true
            case .rhr: return false
            case .strain, .resp: return nil
            }
        }

        var drawsBars: Bool { self == .steps || self == .strain || self == .sleep }
        var showsNormalBand: Bool { self == .hrv || self == .rhr || self == .resp }
        var decimals: Int { (self == .resp || self == .sleep) ? 1 : 0 }

        var tint: Color {
            switch self {
            case .recovery: return StrandPalette.recovery100
            case .hrv, .resp: return StrandPalette.accent
            case .rhr: return StrandPalette.statusCritical
            case .sleep: return StrandPalette.restColor
            case .strain, .steps: return StrandPalette.effortColor
            }
        }
    }

    enum Window: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, halfYear = 182
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week: return String(localized: "W")
            case .month: return String(localized: "M")
            case .halfYear: return String(localized: "6M")
            }
        }
    }

    @AppStorage("zoop.trendViewer.metric") private var metricRaw = Metric.hrv.rawValue
    /// The date under the finger while scrubbing the chart.
    @State private var scrubDate: Date?
    @AppStorage("zoop.trendViewer.window") private var windowRaw = Window.month.rawValue
    private var metric: Metric { Metric(rawValue: metricRaw) ?? .hrv }
    private var window: Window { Window(rawValue: windowRaw) ?? .month }

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func value(_ d: DailyMetric) -> Double? {
        switch metric {
        case .recovery: return d.recovery
        case .hrv: return d.avgHrv
        case .rhr: return d.restingHr.map(Double.init)
        case .sleep: return d.totalSleepMin.map { $0 / 60 }
        case .strain: return d.strain.map { UnitFormatter.effortValue($0, scale: effortScale) }
        case .steps: return d.steps.map(Double.init)
        case .resp: return d.respRateBpm
        }
    }

    /// Points for one window, `offset` windows back from the newest day. Six months are averaged per week
    /// so the chart stays readable.
    private func points(offset: Int) -> [Point] {
        guard let last = days.last.flatMap({ Self.parser.date(from: $0.day) }) else { return [] }
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: -offset * window.rawValue, to: last) ?? last
        let start = cal.date(byAdding: .day, value: -(window.rawValue - 1), to: end) ?? end
        let daily: [Point] = days.compactMap { d in
            guard let date = Self.parser.date(from: d.day), date >= start, date <= end, let v = value(d) else { return nil }
            return Point(date: date, value: v)
        }
        guard window == .halfYear else { return daily }
        let byWeek = Dictionary(grouping: daily) { cal.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        return byWeek.map { Point(date: $0.key, value: $0.value.map(\.value).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
    }

    private func mean(_ p: [Point]) -> Double? {
        p.isEmpty ? nil : p.map(\.value).reduce(0, +) / Double(p.count)
    }

    private func format(_ v: Double) -> String {
        if metric == .steps { return Int(v.rounded()).formatted() }
        return v.formatted(.number.precision(.fractionLength(metric.decimals)))
    }

    var body: some View {
        let current = points(offset: 0)
        let previous = points(offset: 1)
        let avg = mean(current)
        let prevAvg = mean(previous)
        let change: Double? = {
            guard let avg, let prevAvg, prevAvg != 0 else { return nil }
            return (avg - prevAvg) / prevAvg * 100
        }()

        VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
            metricPicker
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Average")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(avg.map(format) ?? "–")
                            .font(StrandFont.display(46))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                    if let change { changeChip(change) }
                }
                Spacer(minLength: 8)
                windowPicker
            }
            if let avg, let prevAvg {
                Text(sentence(avg: avg, prevAvg: prevAvg))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            chart(current: current, avg: avg, previous: previous)
                .frame(height: 220)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }

    private var metricPicker: some View {
        Menu {
            ForEach(Metric.allCases) { m in
                Button { metricRaw = m.rawValue } label: { Label(m.title, systemImage: m.icon) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: metric.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                Text(metric.title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityLabel(Text("Metric"))
    }

    private var windowPicker: some View {
        HStack(spacing: 0) {
            ForEach(Window.allCases) { w in
                Button { windowRaw = w.rawValue } label: {
                    Text(w.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(w == window ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        .frame(width: 44, height: 32)
                        .background(Capsule().fill(w == window ? StrandPalette.hairlineStrong : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(StrandPalette.surfaceBase))
    }

    private func changeChip(_ change: Double) -> some View {
        let up = change > 0.5, down = change < -0.5
        let good: Bool? = metric.higherIsBetter.map { up ? $0 : (down ? !$0 : true) }
        let tint: Color = (!up && !down) ? StrandPalette.textSecondary
            : (good == nil ? StrandPalette.textSecondary : (good! ? StrandPalette.statusPositive : StrandPalette.statusWarning))
        return HStack(spacing: 4) {
            Image(systemName: up ? "arrowtriangle.up.fill" : (down ? "arrowtriangle.down.fill" : "circle.fill"))
                .font(.system(size: 8))
            Text("\(abs(change).formatted(.number.precision(.fractionLength(0))))% vs previous")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.16)))
    }

    private func sentence(avg: Double, prevAvg: Double) -> String {
        let a = format(avg), p = format(prevAvg)
        if abs(avg - prevAvg) / max(abs(prevAvg), 0.0001) < 0.005 {
            return String(localized: "Your average for this period (\(a)) matches the previous period's (\(p)).")
        }
        return avg > prevAvg
            ? String(localized: "Your average for this period (\(a)) was above the previous period's (\(p)).")
            : String(localized: "Your average for this period (\(a)) was below the previous period's (\(p)).")
    }

    private func nearest(_ p: [Point], to date: Date) -> Point? {
        p.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// Bars start at zero; lines zoom to their own range (and the band) so a vital's movement shows.
    private func yDomain(_ p: [Point], band: (lo: Double, hi: Double)?) -> ClosedRange<Double> {
        let values = p.map(\.value) + (band.map { [$0.lo, $0.hi] } ?? [])
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if metric.drawsBars { return 0...max(hi * 1.15, 1) }
        let pad = max((hi - lo) * 0.2, 1)
        return (lo - pad)...(hi + pad)
    }

    @ViewBuilder
    private func chart(current: [Point], avg: Double?, previous: [Point]) -> some View {
        let band: (lo: Double, hi: Double)? = {
            guard metric.showsNormalBand, previous.count >= 3, let m = mean(previous) else { return nil }
            let sd = sqrt(previous.map { ($0.value - m) * ($0.value - m) }.reduce(0, +) / Double(previous.count))
            return (m - sd, m + sd)
        }()
        if current.isEmpty {
            Text("No readings in this period")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                if let band, let first = current.first, let last = current.last {
                    RectangleMark(xStart: .value("Start", first.date), xEnd: .value("End", last.date),
                                  yStart: .value("Low", band.lo), yEnd: .value("High", band.hi))
                        .foregroundStyle(StrandPalette.hairlineStrong.opacity(0.6))
                }
                ForEach(current) { p in
                    if metric.drawsBars {
                        BarMark(x: .value("Day", p.date, unit: window == .halfYear ? .weekOfYear : .day),
                                y: .value("Value", p.value))
                            .foregroundStyle(metric.tint)
                            .clipShape(Capsule())
                    } else {
                        AreaMark(x: .value("Day", p.date), y: .value("Value", p.value))
                            .foregroundStyle(LinearGradient(colors: [metric.tint.opacity(0.25), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.linear)
                        LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                            .foregroundStyle(metric.tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                if let last = current.last, !metric.drawsBars {
                    PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                        .symbol { Circle().stroke(metric.tint, lineWidth: 2.5).background(Circle().fill(StrandPalette.surfaceRaised)).frame(width: 12, height: 12) }
                        .annotation(position: .top) {
                            Text(format(last.value))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(metric.tint)
                        }
                }
                if let avg {
                    RuleMark(y: .value("Average", avg))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let scrubDate, let p = nearest(current, to: scrubDate) {
                    // The reading under the finger: a rule at that day with its value and date.
                    RuleMark(x: .value("Selected", p.date))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.6))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(spacing: 2) {
                                Text(format(p.value) + (metric.unit.isEmpty ? "" : " \(metric.unit)"))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(p.date.formatted(window == .halfYear
                                                      ? .dateTime.day().month(.abbreviated)
                                                      : .dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StrandPalette.surfaceOverlay))
                        }
                }
            }
            .chartXSelection(value: $scrubDate)
            .chartYScale(domain: yDomain(current, band: band))
            // The area fill runs down to zero; keep it inside the plot when the axis starts higher.
            .chartPlotStyle { $0.clipped() }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: window == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel().foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
