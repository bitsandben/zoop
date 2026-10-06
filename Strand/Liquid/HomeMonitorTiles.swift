#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Home monitor tiles
//
// The two half-width tiles under the Home score rings: a vitals summary that taps through to the Health
// screen, and the current stress level that taps through to Stress. Both read figures the destination
// screens already compute (BodyVitalSigns, StressModel), so a tile and its screen cannot disagree.

/// The shared tile chrome: an uppercase title with a chevron, and the status row pinned to the bottom.
struct HomeMonitorTile<Status: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            HStack(alignment: .top, spacing: ZoopMetrics.space1) {
                Text(title)
                    .font(StrandFont.overlineScaled(13))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            status()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(ZoopPanelSurface())
        .contentShape(Rectangle())
    }
}

/// A small square badge leading a status row: a glyph or a number on a tinted fill.
private struct MonitorBadge<Content: View>: View {
    let fill: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
    }
}

/// Vitals at a glance: how many of the latest readings sit inside their range.
struct HomeHealthMonitorTile: View {
    @EnvironmentObject private var repo: Repository
    let temperatureUnit: TemperatureUnit

    private var summary: (inRange: Int, withData: Int) {
        let readings = BodyVitalSigns.readings(sourceRows: repo.vitalMetricRows, temperatureUnit: temperatureUnit)
        let scored = readings.filter { $0.banding.band != .noData }
        return (scored.filter { $0.banding.band == .inRange }.count, scored.count)
    }

    var body: some View {
        let s = summary
        HomeMonitorTile(title: "Health Monitor") {
            HStack(spacing: ZoopMetrics.space2) {
                if s.withData == 0 {
                    MonitorBadge(fill: StrandPalette.hairlineStrong) {
                        Image(systemName: "minus").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Pending")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    let allIn = s.inRange == s.withData
                    MonitorBadge(fill: (allIn ? StrandPalette.statusPositive : StrandPalette.statusWarning).opacity(0.22)) {
                        Image(systemName: allIn ? "checkmark" : "exclamationmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(allIn ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(allIn ? "Within range" : "Outside range")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(s.inRange)/\(s.withData) metrics")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The current stress level on its 0–3 scale, coloured by band.
struct HomeStressMonitorTile: View {
    let score: Double?

    var body: some View {
        HomeMonitorTile(title: "Stress Monitor") {
            HStack(spacing: ZoopMetrics.space2) {
                if let score {
                    let band = StressBand(score: score)
                    let tint = Self.tint(band)
                    MonitorBadge(fill: tint.opacity(0.22)) {
                        Text(score, format: .number.precision(.fractionLength(1)))
                            .font(StrandFont.number(17, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 4)
                    }
                    Text(band.title)
                        .font(StrandFont.overlineScaled(13))
                        .tracking(1.5)
                        .foregroundStyle(tint)
                } else {
                    MonitorBadge(fill: StrandPalette.hairlineStrong) {
                        Image(systemName: "minus").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Pending")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func tint(_ band: StressBand) -> Color {
        switch band {
        case .low: return StrandPalette.stressLow
        case .medium: return StrandPalette.stressMedium
        case .high: return StrandPalette.stressHigh
        }
    }
}

// MARK: - Effort & Charge week chart

/// One day of the week chart: Charge (0–100 %) and Effort on the wearer's chosen scale.
struct EffortChargeDay: Identifiable {
    let day: String
    let charge: Double?
    let effort: Double?
    var id: String { day }
}

/// Seven days of Effort (blue, left axis) against Charge (banded dots on a grey line, right axis),
/// with the selected day highlighted. Drawn by hand because the two series need independent axes.
struct EffortChargeWeekCard: View {
    let days: [EffortChargeDay]          // oldest → newest, the last one is the selected day
    let effortMax: Double                // 21 or 100, matching the Effort scale
    let effortDecimals: Int

    private let plotHeight: CGFloat = 190
    private let axisWidth: CGFloat = 34

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
            Text("Effort & Charge")
                .font(StrandFont.overlineScaled(14))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .top, spacing: ZoopMetrics.space1) {
                leftAxis
                plot
                rightAxis
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort and Charge over the last seven days"))
    }

    private var effortTicks: [Double] {
        effortMax <= 21 ? [21, 14, 7, 0] : [100, 66, 33, 0]
    }

    private var leftAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(effortTicks.enumerated()), id: \.offset) { idx, v in
                Text(v, format: .number.precision(.fractionLength(0)))
                    .font(StrandFont.number(12, weight: .bold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(height: 16)
                if idx < effortTicks.count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(width: 24, height: plotHeight + 16)
    }

    private var rightAxis: some View {
        let ticks: [(String, Color)] = [
            ("100%", StrandPalette.recoveryColor(100)), ("66%", StrandPalette.recoveryColor(50)),
            ("33%", StrandPalette.recoveryColor(10)), ("0%", StrandPalette.recoveryColor(0)),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { idx, t in
                Text(t.0)
                    .font(StrandFont.number(12, weight: .bold))
                    .foregroundStyle(t.1)
                    .frame(height: 16)
                if idx < ticks.count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(width: axisWidth, height: plotHeight + 16)
    }

    private var plot: some View {
        VStack(spacing: ZoopMetrics.space2) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let n = max(days.count, 1)
                let col = w / CGFloat(n)
                let x: (Int) -> CGFloat = { CGFloat($0) * col + col / 2 }
                let yCharge: (Double) -> CGFloat = { h - CGFloat(min(max($0, 0), 100) / 100) * h }
                let yEffort: (Double) -> CGFloat = { h - CGFloat(min(max($0, 0), effortMax) / effortMax) * h }
                ZStack(alignment: .topLeading) {
                    // Selected-day column.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(StrandPalette.hairlineStrong.opacity(0.7))
                        .frame(width: col * 0.82, height: h + 8)
                        .position(x: x(n - 1), y: h / 2)
                    // Grid.
                    ForEach(0..<4, id: \.self) { i in
                        Path { p in
                            let y = h * CGFloat(i) / 3
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(StrandPalette.hairline, lineWidth: 1)
                    }
                    line(points: days.enumerated().compactMap { i, d in d.charge.map { CGPoint(x: x(i), y: yCharge($0)) } },
                         color: StrandPalette.textTertiary)
                    line(points: days.enumerated().compactMap { i, d in d.effort.map { CGPoint(x: x(i), y: yEffort($0)) } },
                         color: StrandPalette.effortColor)
                    ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                        if let c = d.charge {
                            dot(color: StrandPalette.recoveryColor(c), label: "\(Int(c.rounded()))%",
                                at: CGPoint(x: x(i), y: yCharge(c)), labelAbove: true)
                        }
                        if let e = d.effort {
                            dot(color: StrandPalette.effortColor,
                                label: e.formatted(.number.precision(.fractionLength(effortDecimals))),
                                at: CGPoint(x: x(i), y: yEffort(e)), labelAbove: false)
                        }
                    }
                }
            }
            .frame(height: plotHeight)
            .padding(.vertical, 8)
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    let date = Self.parser.date(from: d.day)
                    VStack(spacing: 2) {
                        Text(date.map { $0.formatted(.dateTime.weekday(.abbreviated)) } ?? "")
                        Text(date.map { $0.formatted(.dateTime.day()) } ?? "")
                    }
                    .font(StrandFont.number(12, weight: .bold))
                    .foregroundStyle(i == days.count - 1 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func line(points: [CGPoint], color: Color) -> some View {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            points.dropFirst().forEach { p.addLine(to: $0) }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func dot(color: Color, label: String, at point: CGPoint, labelAbove: Bool) -> some View {
        ZStack {
            Circle()
                .fill(StrandPalette.surfaceRaised)
                .overlay(Circle().stroke(color, lineWidth: 2.5))
                .frame(width: 11, height: 11)
                .position(point)
            Text(label)
                .font(StrandFont.number(12, weight: .bold))
                .foregroundStyle(color)
                .fixedSize()
                .position(x: point.x, y: point.y + (labelAbove ? -15 : 15))
        }
    }
}

/// A large sentence-case section title with an optional trailing control, as used for "My Day" and
/// "My Dashboard" on Home.
struct HomeSectionTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopMetrics.space2)
            trailing()
        }
        .padding(.top, ZoopMetrics.space4)
        .padding(.horizontal, 2)
    }
}
#endif
