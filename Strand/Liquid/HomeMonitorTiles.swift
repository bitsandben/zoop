#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Home monitor tiles
//
// The two tiles under the Home score rings: a vitals summary that taps through to the Health screen,
// and the current stress level that taps through to Stress. Both read figures the destination screens
// already compute (BodyVitalSigns, StressModel), so a tile and its screen cannot disagree.

/// The concept's tile: a headline with a chevron, a grey line under it, and a black well holding a
/// glyph or a number beside the tile's name at the bottom.
struct HomeMonitorTile<Well: View>: View {
    let headline: String
    var headlineTint: Color = StrandPalette.textPrimary
    let detail: String
    let name: LocalizedStringKey
    @ViewBuilder var well: () -> Well

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headline)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(headlineTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityHidden(true)
            }
            Text(detail)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: ZoopMetrics.space4)
            HStack(spacing: 10) {
                well()
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(ZoopPanelSurface(cornerRadius: 20))
        .contentShape(Rectangle())
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
        let allIn = s.withData > 0 && s.inRange == s.withData
        HomeMonitorTile(
            headline: s.withData == 0 ? String(localized: "Pending")
                : (allIn ? String(localized: "Within range") : String(localized: "Outside range")),
            detail: s.withData == 0 ? String(localized: "No readings yet")
                : String(localized: "\(s.inRange)/\(s.withData) metrics"),
            name: "Health monitor"
        ) {
            Image(systemName: s.withData == 0 ? "minus" : (allIn ? "checkmark" : "exclamationmark"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(s.withData == 0 ? StrandPalette.textSecondary
                                 : (allIn ? StrandPalette.textPrimary : StrandPalette.statusWarning))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The current stress level on its 0–3 scale.
struct HomeStressMonitorTile: View {
    let score: Double?

    var body: some View {
        HomeMonitorTile(
            headline: score.map { Self.bandName(StressBand(score: $0)) } ?? String(localized: "Pending"),
            detail: score == nil ? String(localized: "No readings yet") : String(localized: "Today"),
            name: "Stress monitor"
        ) {
            if let score {
                Text(score, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Self.tint(StressBand(score: score)))
            } else {
                Image(systemName: "minus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func bandName(_ band: StressBand) -> String {
        switch band {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    static func tint(_ band: StressBand) -> Color {
        switch band {
        case .low: return StrandPalette.stressLow
        case .medium: return StrandPalette.stressMedium
        case .high: return StrandPalette.stressHigh
        }
    }
}

// MARK: - Weekly trends

/// One day of the weekly trend cards.
struct WeeklyTrendDay: Identifiable {
    let day: String
    let recovery: Double?
    let hrv: Double?
    var id: String { day }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var date: Date? { Self.parser.date(from: day) }
}

/// The weekday and day-of-month labels under both weekly cards; the selected (last) day is white.
private struct WeekAxis: View {
    let days: [WeeklyTrendDay]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                VStack(spacing: 2) {
                    Text(d.date.map { $0.formatted(.dateTime.weekday(.abbreviated)) } ?? "")
                    Text(d.date.map { $0.formatted(.dateTime.day()) } ?? "")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(i == days.count - 1 ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A card titled like the concept's weekly cards: a semibold title and a chevron.
private struct WeeklyCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }
}

/// Recovery for the week as rounded bars in each day's band colour, the value above each bar.
struct WeeklyRecoveryCard: View {
    let days: [WeeklyTrendDay]
    private let plotHeight: CGFloat = 170

    var body: some View {
        WeeklyCard(title: "Recovery") {
            VStack(spacing: ZoopMetrics.space2) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(days) { d in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            if let r = d.recovery {
                                Text("\(Int(r.rounded()))%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.recoveryColor(r))
                                    .fixedSize()
                                Capsule()
                                    .fill(StrandPalette.recoveryColor(r))
                                    .frame(width: 9, height: max(10, plotHeight * 0.82 * CGFloat(min(max(r, 0), 100) / 100)))
                            } else {
                                Capsule()
                                    .fill(StrandPalette.surfaceBase)
                                    .frame(width: 9, height: 10)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: plotHeight)
                WeekAxis(days: days)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recovery over the last seven days"))
    }
}

/// HRV for the week as a teal line with hollow points and a fading fill, the selected day
/// highlighted by a dark column.
struct WeeklyHRVCard: View {
    let days: [WeeklyTrendDay]
    private let plotHeight: CGFloat = 150

    var body: some View {
        WeeklyCard(title: "Heart Rate Variability") {
            let values = days.compactMap(\.hrv)
            let lo = (values.min() ?? 0) * 0.8
            let hi = max((values.max() ?? 1) * 1.1, lo + 1)
            VStack(spacing: ZoopMetrics.space2) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let col = w / CGFloat(max(days.count, 1))
                    let x: (Int) -> CGFloat = { CGFloat($0) * col + col / 2 }
                    let y: (Double) -> CGFloat = { h - CGFloat(($0 - lo) / (hi - lo)) * h }
                    let points = days.enumerated().compactMap { i, d in d.hrv.map { CGPoint(x: x(i), y: y($0)) } }
                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(StrandPalette.surfaceBase)
                            .frame(width: col * 0.62, height: h + 48)
                            .position(x: x(days.count - 1), y: h / 2 + 14)
                        if let first = points.first, let last = points.last {
                            Path { p in
                                p.move(to: CGPoint(x: first.x, y: h))
                                points.forEach { p.addLine(to: $0) }
                                p.addLine(to: CGPoint(x: last.x, y: h))
                                p.closeSubpath()
                            }
                            .fill(LinearGradient(colors: [StrandPalette.accent.opacity(0.22), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                            Path { p in
                                p.move(to: first)
                                points.dropFirst().forEach { p.addLine(to: $0) }
                            }
                            .stroke(StrandPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                            if let v = d.hrv {
                                Circle()
                                    .fill(StrandPalette.surfaceRaised)
                                    .overlay(Circle().stroke(StrandPalette.accent, lineWidth: 2))
                                    .frame(width: 12, height: 12)
                                    .position(x: x(i), y: y(v))
                                Text("\(Int(v.rounded()))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.accent)
                                    .fixedSize()
                                    .position(x: x(i), y: y(v) - 16)
                            }
                        }
                    }
                }
                .frame(height: plotHeight)
                .padding(.top, 18)
                WeekAxis(days: days)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate variability over the last seven days"))
    }
}

/// A sentence-case section title with an optional trailing control, as used for "My Day" and
/// "Weekly Trends" on Home.
struct HomeSectionTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopMetrics.space2)
            trailing()
        }
        .padding(.top, ZoopMetrics.space5)
        .padding(.horizontal, 2)
    }
}
#endif
