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

/// The health monitor as one slim row: status headline, the in-range count, and a chevron.
struct HomeHealthMonitorRow: View {
    @EnvironmentObject private var repo: Repository
    let temperatureUnit: TemperatureUnit

    var body: some View {
        let readings = BodyVitalSigns.readings(sourceRows: repo.vitalMetricRows, temperatureUnit: temperatureUnit)
        let scored = readings.filter { $0.banding.band != .noData }
        let inRange = scored.filter { $0.banding.band == .inRange }.count
        let allIn = !scored.isEmpty && inRange == scored.count
        HStack(spacing: 12) {
            Image(systemName: scored.isEmpty ? "minus" : (allIn ? "checkmark" : "exclamationmark"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(scored.isEmpty ? StrandPalette.textSecondary
                                 : (allIn ? StrandPalette.textPrimary : StrandPalette.statusWarning))
                .frame(width: 36, height: 36)
                .background(Circle().fill(StrandPalette.surfaceBase))
            VStack(alignment: .leading, spacing: 1) {
                Text("Health monitor")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(scored.isEmpty ? String(localized: "No readings yet")
                     : (allIn ? String(localized: "Within range") : String(localized: "Outside range")))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            if !scored.isEmpty {
                Text(String(localized: "\(inRange)/\(scored.count) metrics"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .background(ZoopPanelSurface(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// The stress monitor on Home: today's level and band in the header and the day's stress line, the
/// same line the Stress screen draws.
struct HomeStressMonitorCard: View {
    let score: Double?
    let hours: [DaytimeStress.HourPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stress monitor")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if let score {
                    let band = StressBand(score: score)
                    Text(HomeStressMonitorTile.bandName(band))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HomeStressMonitorTile.tint(band))
                    Text(score, format: .number.precision(.fractionLength(1)))
                        .font(StrandFont.display(24))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if hours.contains(where: { $0.level != nil }) {
                DaytimeLoadLine(hours: hours)
            } else {
                Text("Builds up through the day")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface())
    }
}

/// One entry in "Today's activities".
struct HomeActivity: Identifiable {
    enum Kind { case sleep, nap, workout }
    let kind: Kind
    let title: String
    let start: Int
    let end: Int
    let workout: WorkoutRow?
    var id: String { "\(kind)-\(start)" }
}

/// A row in "Today's activities": a tinted badge, the title, and the time span with its duration.
struct HomeActivityRow: View {
    let item: HomeActivity

    private var tint: Color {
        switch item.kind {
        case .sleep, .nap: return StrandPalette.restColor
        case .workout: return StrandPalette.effortColor
        }
    }
    private var icon: String {
        switch item.kind {
        case .sleep: return "moon.fill"
        case .nap: return "bed.double.fill"
        case .workout: return "figure.run"
        }
    }

    var body: some View {
        let start = Date(timeIntervalSince1970: TimeInterval(item.start))
        let end = Date(timeIntervalSince1970: TimeInterval(item.end))
        let minutes = max(0, (item.end - item.start) / 60)
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.surfaceBase)
                .frame(width: 44, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint))
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("\(minutes / 60):\(String(format: "%02d", minutes % 60))")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceOverlay))
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

/// Tracks which column of a week chart the finger is over while scrubbing, through the shared chart
/// scrub: a tap still reaches the card's link, a vertical drag scrolls Home, and only a sideways drag (or
/// a short hold) scrubs. Draws the vertical rule through the selected column.
private struct WeekScrub: ViewModifier {
    let count: Int
    @Binding var selected: Int?

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let col = geo.size.width / CGFloat(max(count, 1))
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if let i = selected {
                        CrosshairRule(x: col * (CGFloat(i) + 0.5), height: geo.size.height)
                    }
                }
                .contentShape(Rectangle())
                .zoopChartScrub(onChange: { location in
                    selected = min(count - 1, max(0, Int(location.x / col)))
                }, onEnd: { selected = nil })
            }
        }
    }
}

/// The value bubble shown above a scrubbed week column.
private struct ScrubBubble: View {
    let value: String
    let day: WeeklyTrendDay
    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
            Text(day.date.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StrandPalette.surfaceOverlay))
        .fixedSize()
    }
}

/// Recovery for the week as rounded bars in each day's band colour, the value above each bar.
struct WeeklyRecoveryCard: View {
    let days: [WeeklyTrendDay]
    private let plotHeight: CGFloat = 170
    @State private var scrub: Int?

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
                .modifier(WeekScrub(count: days.count, selected: $scrub))
                .overlay(alignment: .top) {
                    GeometryReader { geo in
                        if let i = scrub, days.indices.contains(i), let r = days[i].recovery {
                            let col = geo.size.width / CGFloat(days.count)
                            ScrubBubble(value: "\(Int(r.rounded()))%", day: days[i])
                                .position(x: min(max(col * (CGFloat(i) + 0.5), 50), geo.size.width - 50), y: -6)
                        }
                    }
                }
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
    @State private var scrub: Int?

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
                .modifier(WeekScrub(count: days.count, selected: $scrub))
                .overlay(alignment: .top) {
                    GeometryReader { geo in
                        if let i = scrub, days.indices.contains(i), let v = days[i].hrv {
                            let col = geo.size.width / CGFloat(days.count)
                            ScrubBubble(value: "\(Int(v.rounded())) ms", day: days[i])
                                .position(x: min(max(col * (CGFloat(i) + 0.5), 50), geo.size.width - 50), y: -6)
                        }
                    }
                }
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
