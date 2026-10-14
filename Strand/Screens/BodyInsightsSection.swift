import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - What your body shows
//
// Standalone section: one flat card per interpretation `BodyInsights` can make from the stored history,
// each with a one-sentence reading, its number and a small chart. A tap opens a sheet with the larger chart
// and one sentence on how it is computed. Readings without enough data are simply absent, and the whole
// section draws nothing until at least one exists. Takes the repository and profile from the environment,
// so it can be dropped onto any screen.

struct BodyInsightsSection: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @StateObject private var model = BodyInsightsModel()
    @State private var open: BodyInsightCard?

    var body: some View {
        let cards = BodyInsightCard.cards(from: model.results, effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw))
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            if !cards.isEmpty {
                SectionHeader("What your body shows")
                ForEach(cards) { card in
                    Button { open = card } label: { BodyInsightCardView(card: card) }
                        .buttonStyle(.plain)
                }
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo, zoneSet: profile.hrZoneSet) }
        .sheet(item: $open) { card in
            BodyInsightDetailSheet(card: card)
        }
    }
}

// MARK: - Loading

@MainActor
final class BodyInsightsModel: ObservableObject {

    struct Results: Equatable {
        var hrv: BodyInsights.Direction?
        var restingHR: BodyInsights.Direction?
        var weekday: BodyInsights.WeekdayReading?
        var bounceBack: BodyInsights.BounceBack?
        var zoneMix: BodyInsights.ZoneMix?
        var stressTiming: BodyInsights.StressTiming?
        var sensitivity: BodyInsights.StrainSensitivity?
    }

    @Published private(set) var results = Results()

    /// Stress timing reads two weeks of raw streams, so it is scored once per local day.
    private var stressDay: String?
    private var stressCache: BodyInsights.StressTiming?

    static let zoneWindowDays = 28
    static let stressDays = 14

    func load(repo: Repository, zoneSet: HRZoneSet) async {
        let days = repo.days
        let today = Repository.localDayKey(Date())
        let loads = BodyInsights.loads(days)
        var r = Results()
        r.hrv = BodyInsights.direction(BodyInsights.hrv(days), asOf: today)
        r.restingHR = BodyInsights.direction(BodyInsights.restingHR(days), asOf: today)
        r.weekday = BodyInsights.weekday(BodyInsights.recovery(days))
        r.bounceBack = BodyInsights.bounceBack(loads)
        r.sensitivity = BodyInsights.strainSensitivity(loads)
        r.zoneMix = results.zoneMix
        r.stressTiming = stressCache
        results = r

        r.zoneMix = await zoneMix(repo: repo, zoneSet: zoneSet)
        results = r

        if stressDay != today {
            stressCache = await stressTiming(repo: repo)
            stressDay = today
        }
        r.stressTiming = stressCache
        results = r
    }

    /// Zone minutes per workout of the last four weeks: the imported split first, the strap's own heart
    /// rate otherwise (the same precedence as the workout detail page).
    private func zoneMix(repo: Repository, zoneSet: HRZoneSet) async -> BodyInsights.ZoneMix? {
        let cutoff = Int(Date().timeIntervalSince1970) - Self.zoneWindowDays * 86_400
        let rows = await repo.workoutRows(days: Self.zoneWindowDays).filter { $0.startTs >= cutoff && $0.endTs > $0.startTs }
        var sessions: [[Double]] = []
        for row in rows.prefix(60) {
            if let pct = WorkoutZones.percents(row.zonesJSON) {
                let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60
                if durMin > 0 { sessions.append(pct.map { durMin * $0 / 100 }) }
            } else if let m = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: zoneSet,
                                                             source: row.source) {
                sessions.append(m)
            }
        }
        return BodyInsights.zoneMix(sessions: sessions)
    }

    /// Hourly stress for the last 14 full days, 07:00–23:00, scored the way the Stress screen scores a day.
    private func stressTiming(repo: Repository) async -> BodyInsights.StressTiming? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var perDay: [[BodyInsights.HourLevel]] = []
        for back in 1...Self.stressDays {
            guard let date = cal.date(byAdding: .day, value: -back, to: todayStart) else { continue }
            let from = Int(date.timeIntervalSince1970) + 7 * 3600
            let to = Int(date.timeIntervalSince1970) + 23 * 3600
            let hr = await repo.hrSamples(from: from, to: to, limit: 80_000)
            guard hr.count >= DaytimeStress.minHourHRSamples * 6 else { continue }
            let rr = await repo.rrIntervals(from: from, to: to, limit: 120_000)
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 120_000)
            let tz = TimeZone.current.secondsFromGMT(for: date)
            let result = await runUnescalated {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz,
                                      mode: .dayRelative, includeTimeline: false)
            }
            let levels = result.hours.compactMap { h in h.level.map { BodyInsights.HourLevel(hour: h.hour, level: $0) } }
            if !levels.isEmpty { perDay.append(levels) }
        }
        return BodyInsights.stressTiming(days: perDay)
    }
}

// MARK: - Card content

struct BodyInsightCard: Identifiable, Equatable {
    enum Kind: String { case hrv, restingHR, sensitivity, bounceBack, zoneMix, stressTiming, weekday }

    enum Visual: Equatable {
        case line(points: [BodyInsights.DayValue], normal: Double, spread: Double)
        case weekdays(means: [Int: Double], low: Int?, high: Int?)
        case trajectory([Double?])
        case zones([Double])
        case hours([BodyInsights.HourLevel], peak: Int, calm: Int)
        /// x is already on the displayed effort scale; `slope` is recovery points per displayed effort unit.
        case scatter(points: [BodyInsights.StrainSensitivity.Pair], slope: Double)
    }

    let kind: Kind
    var id: String { kind.rawValue }
    let icon: String
    let title: String
    let headline: String
    let number: String
    let unit: String
    let tint: Color
    let visual: Visual
    /// One sentence of figures for the detail sheet.
    let figures: String
    /// One sentence on how the reading is computed.
    let method: String

    static func cards(from r: BodyInsightsModel.Results, effortScale: EffortScale) -> [BodyInsightCard] {
        var out: [BodyInsightCard] = []
        if let d = r.hrv { out.append(direction(d, kind: .hrv)) }
        if let d = r.restingHR { out.append(direction(d, kind: .restingHR)) }
        if let s = r.sensitivity { out.append(sensitivity(s, effortScale: effortScale)) }
        if let b = r.bounceBack { out.append(bounceBack(b)) }
        if let z = r.zoneMix { out.append(zoneMix(z)) }
        if let s = r.stressTiming { out.append(stressTiming(s)) }
        if let w = r.weekday, let c = weekday(w) { out.append(c) }
        return out
    }

    private static func signedPercent(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n == 0 ? "0%" : String(format: "%+d%%", n)
    }

    private static func direction(_ d: BodyInsights.Direction, kind: Kind) -> BodyInsightCard {
        let hrv = kind == .hrv
        let n = d.streakDays
        let headline: String
        switch (d.trend, hrv) {
        case (.belowStreak, true):  headline = String(localized: "Your HRV has been below your normal for \(n) days.")
        case (.aboveStreak, true):  headline = String(localized: "Your HRV has been above your normal for \(n) days.")
        case (.lowerThisWeek, true): headline = String(localized: "Your HRV has run lower than usual this week.")
        case (.higherThisWeek, true): headline = String(localized: "Your HRV has run higher than usual this week.")
        case (.steady, true):       headline = String(localized: "Your HRV is right at your normal.")
        case (.belowStreak, false): headline = String(localized: "Your resting heart rate has been below your normal for \(n) days.")
        case (.aboveStreak, false): headline = String(localized: "Your resting heart rate has been above your normal for \(n) days.")
        case (.lowerThisWeek, false): headline = String(localized: "Your resting heart rate has run lower than usual this week.")
        case (.higherThisWeek, false): headline = String(localized: "Your resting heart rate has run higher than usual this week.")
        case (.steady, false):      headline = String(localized: "Your resting heart rate is right at your normal.")
        }
        let recent = Int(d.recentMean.rounded()), normal = Int(d.baselineMean.rounded())
        return BodyInsightCard(
            kind: kind,
            icon: hrv ? "waveform.path.ecg" : "heart.fill",
            title: hrv ? String(localized: "HRV trend") : String(localized: "Resting HR trend"),
            headline: headline,
            number: signedPercent(d.deltaPercent),
            unit: String(localized: "vs. normal"),
            tint: hrv ? StrandPalette.metricCyan : StrandPalette.metricRose,
            visual: .line(points: d.series, normal: d.baselineMean, spread: d.baselineSD),
            figures: hrv ? String(localized: "Last 7 days: \(recent) ms, your normal: \(normal) ms.")
                         : String(localized: "Last 7 days: \(recent) bpm, your normal: \(normal) bpm."),
            method: String(localized: "Each night is compared with the 30 days before it; a run counts nights at least half a standard deviation away."))
    }

    private static func sensitivity(_ s: BodyInsights.StrainSensitivity, effortScale: EffortScale) -> BodyInsightCard {
        let headline: String
        switch s.level {
        case .strong:     headline = String(localized: "Hard days hit your next-morning recovery hard.")
        case .noticeable: headline = String(localized: "Hard days lower your next-morning recovery noticeably.")
        case .little:     headline = String(localized: "Hard days barely move your next-morning recovery.")
        }
        // Stored effort is 0–100; WHOOP-scale users read it on 0–21, so the slope is per one of their points.
        let whoop = effortScale == .whoop
        let factor = whoop ? 0.21 : 1.0
        let perUnit = s.pointsPer10 / 10 / factor
        let shown = whoop ? perUnit : s.pointsPer10
        let points = s.points.map { BodyInsights.StrainSensitivity.Pair(strain: $0.strain * factor, recovery: $0.recovery) }
        return BodyInsightCard(
            kind: .sensitivity,
            icon: "arrow.down.right",
            title: String(localized: "Effort and recovery"),
            headline: headline,
            number: shown.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())),
            unit: whoop ? String(localized: "pts per effort point") : String(localized: "pts per 10 effort"),
            tint: StrandPalette.effortColor,
            visual: .scatter(points: points, slope: perUnit),
            figures: String(localized: "Based on \(s.pairs) days."),
            method: String(localized: "Each day's effort against the next morning's recovery over the last 180 days, as a straight-line fit."))
    }

    private static func bounceBack(_ b: BodyInsights.BounceBack) -> BodyInsightCard {
        let days = Int(b.medianDays.rounded(.up))
        let headline: String
        if days <= 1 {
            headline = String(localized: "After your hardest days, your recovery is back to normal by the next morning.")
        } else if days <= 7 {
            headline = String(localized: "After your hardest days, your recovery takes about \(days) days to get back to normal.")
        } else {
            headline = String(localized: "After your hardest days, your recovery often takes over a week to get back to normal.")
        }
        let dip = Int((-b.nextMorningDip).rounded())
        return BodyInsightCard(
            kind: .bounceBack,
            icon: "arrow.uturn.up",
            title: String(localized: "Bounce-back"),
            headline: headline,
            number: days > 7 ? ">7" : "\(max(1, days))",
            unit: days == 1 ? String(localized: "day") : String(localized: "days"),
            tint: StrandPalette.chargeColor,
            visual: .trajectory(b.trajectory),
            figures: dip >= 1
                ? String(localized: "\(b.events) hard days measured; the next morning sits \(dip) points below normal on average.")
                : String(localized: "\(b.events) hard days measured."),
            method: String(localized: "Your hardest fifth of days, each compared with the median recovery of the 30 days before it."))
    }

    private static func zoneMix(_ z: BodyInsights.ZoneMix) -> BodyInsightCard {
        let headline: String
        switch z.style {
        case .mostlyEasy: headline = String(localized: "Most of your training is easy, close to an 80/20 split.")
        case .mixed:      headline = String(localized: "Your training leans easy but carries a lot of hard time.")
        case .mostlyHard: headline = String(localized: "Most of your training time is hard, in zones 3 to 5.")
        }
        return BodyInsightCard(
            kind: .zoneMix,
            icon: "figure.run",
            title: String(localized: "Training intensity"),
            headline: headline,
            number: "\(Int((z.easyShare * 100).rounded()))%",
            unit: String(localized: "easy"),
            tint: StrandPalette.effortColor,
            visual: .zones(z.minutes),
            figures: String(localized: "\(z.sessions) workouts with \(Int(z.totalMinutes.rounded())) minutes of zone time."),
            method: String(localized: "Heart-rate zone time of your workouts in the last four weeks; zones 1–2 count as easy, 3–5 as hard."))
    }

    static func clock(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func stressTiming(_ s: BodyInsights.StressTiming) -> BodyInsightCard {
        BodyInsightCard(
            kind: .stressTiming,
            icon: "clock",
            title: String(localized: "Stress timing"),
            headline: String(localized: "Your stress usually peaks around \(clock(s.peakHour)) and is lowest around \(clock(s.calmHour))."),
            number: clock(s.peakHour),
            unit: String(localized: "peak"),
            tint: StrandPalette.stressHigh,
            visual: .hours(s.hourMeans, peak: s.peakHour, calm: s.calmHour),
            figures: String(localized: "From \(s.days) days with enough heart-rate data."),
            method: String(localized: "Hourly stress of your last 14 days, averaged for each hour of the day."))
    }

    static func weekdayName(_ wd: Int) -> String {
        Calendar.current.standaloneWeekdaySymbols[wd % 7]
    }

    private static func weekday(_ w: BodyInsights.WeekdayReading) -> BodyInsightCard? {
        guard let e = w.lowest ?? w.highest else { return nil }
        let name = weekdayName(e.weekday)
        let headline = w.lowest != nil
            ? String(localized: "\(name) is usually your weakest recovery day.")
            : String(localized: "\(name) is usually your strongest recovery day.")
        let gap = Int(e.gap.rounded())
        return BodyInsightCard(
            kind: .weekday,
            icon: "calendar",
            title: String(localized: "Weekday rhythm"),
            headline: headline,
            number: String(format: "%+d", gap),
            unit: String(localized: "pts vs. other days"),
            tint: StrandPalette.chargeColor,
            visual: .weekdays(means: w.means, low: w.lowest?.weekday, high: w.highest?.weekday),
            figures: String(localized: "\(name) averages \(Int(e.mean.rounded())), the other days \(Int(e.othersMean.rounded()))."),
            method: String(localized: "Average recovery per weekday over the last 26 weeks; a day is named only when it stood out in most weeks."))
    }
}

// MARK: - Card

struct BodyInsightCardView: View {
    let card: BodyInsightCard

    var body: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: card.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StrandPalette.surfaceBase))
                    Text(card.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: card.number)
                            .font(StrandFont.display(40))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(card.unit)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    BodyInsightChart(visual: card.visual, tint: card.tint, large: false)
                        .frame(width: 140, height: 60)
                }
                Text(card.headline)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens details"))
    }
}

// MARK: - Detail sheet

struct BodyInsightDetailSheet: View {
    let card: BodyInsightCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: card.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StrandPalette.surfaceRaised))
                    Text(card.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: card.number)
                        .font(StrandFont.display(56))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(card.unit)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(card.headline)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ZoopCard {
                    BodyInsightChart(visual: card.visual, tint: card.tint, large: true)
                        .frame(height: ZoopMetrics.chartHeight)
                }
                Text(card.figures)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.method)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(ZoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(minWidth: ZoopMetrics.detailSheetMinWidth, minHeight: ZoopMetrics.detailSheetMinHeight)
        #endif
    }
}

// MARK: - Charts

struct BodyInsightChart: View {
    let visual: BodyInsightCard.Visual
    let tint: Color
    let large: Bool

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var muted: Color { StrandPalette.textTertiary.opacity(0.5) }

    var body: some View {
        switch visual {
        case let .line(points, normal, spread):
            lineChart(points, normal: normal, spread: spread)
        case let .weekdays(means, low, high):
            weekdayChart(means, low: low, high: high)
        case let .trajectory(values):
            trajectoryChart(values)
        case let .zones(minutes):
            zoneChart(minutes)
        case let .hours(levels, peak, calm):
            hourChart(levels, peak: peak, calm: calm)
        case let .scatter(points, slope):
            scatterChart(points, slope: slope)
        }
    }

    private func axes<C: View>(_ chart: C) -> some View {
        Group {
            if large {
                chart
            } else {
                chart.chartXAxis(.hidden).chartYAxis(.hidden)
            }
        }
    }

    private func lineChart(_ points: [BodyInsights.DayValue], normal: Double, spread: Double) -> some View {
        let dated = points.compactMap { p in Self.dayParser.date(from: p.day).map { (date: $0, value: p.value) } }
        let values = dated.map(\.value) + [normal - spread, normal + spread]
        let lo = (values.min() ?? 0), hi = (values.max() ?? 1)
        let pad = max(1, (hi - lo) * 0.15)
        return axes(Chart {
            ForEach(dated, id: \.date) { p in
                AreaMark(x: .value("Day", p.date), yStart: .value("Low", normal - spread),
                         yEnd: .value("High", normal + spread))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.15))
            }
            RuleMark(y: .value("Normal", normal))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(dated, id: \.date) { p in
                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: large ? 2.5 : 2))
            }
            if let last = dated.last {
                PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                    .foregroundStyle(tint)
                    .symbolSize(large ? 50 : 24)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad)))
    }

    private func weekdayChart(_ means: [Int: Double], low: Int?, high: Int?) -> some View {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let lo = means.values.min() ?? 0
        return axes(Chart {
            ForEach(1...7, id: \.self) { wd in
                if let m = means[wd] {
                    BarMark(x: .value("Weekday", symbols[wd % 7]), y: .value("Recovery", m))
                        .foregroundStyle(wd == low ? StrandPalette.statusCritical : wd == high ? StrandPalette.chargeColor : muted)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
        }
        .chartYScale(domain: max(0, lo - 15)...100))
    }

    private func trajectoryChart(_ values: [Double?]) -> some View {
        let tol = ActivityCostEngine.tolerance
        return axes(Chart {
            RuleMark(y: .value("Normal", 0))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(Array(values.enumerated()), id: \.offset) { k, v in
                if let v {
                    BarMark(x: .value("Day", k == 0 ? String(localized: "Day 0") : "+\(k)"), y: .value("Gap", v))
                        .foregroundStyle(v >= -tol ? StrandPalette.chargeColor : StrandPalette.statusWarning)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
        })
    }

    @ViewBuilder
    private func zoneChart(_ minutes: [Double]) -> some View {
        if large {
            Chart {
                ForEach(0..<min(5, minutes.count), id: \.self) { i in
                    BarMark(x: .value("Zone", "Z\(i + 1)"), y: .value("Minutes", minutes[i]))
                        .foregroundStyle(StrandPalette.hrZoneColor(i + 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        } else {
            let total = max(0.001, minutes.reduce(0, +))
            let starts = minutes.indices.map { i in minutes[..<i].reduce(0, +) / total }
            Chart {
                ForEach(0..<min(5, minutes.count), id: \.self) { i in
                    BarMark(xStart: .value("From", starts[i]), xEnd: .value("To", starts[i] + minutes[i] / total),
                            y: .value("Mix", "mix"), height: .fixed(14))
                        .foregroundStyle(StrandPalette.hrZoneColor(i + 1))
                }
            }
            .chartXScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    private func hourChart(_ levels: [BodyInsights.HourLevel], peak: Int, calm: Int) -> some View {
        axes(Chart {
            ForEach(levels, id: \.hour) { h in
                BarMark(x: .value("Hour", h.hour), y: .value("Stress", h.level), width: .ratio(0.7))
                    .foregroundStyle(h.hour == peak ? StrandPalette.stressHigh : h.hour == calm ? StrandPalette.stressLow : muted)
            }
        }
        .chartYScale(domain: 0...3))
    }

    private func scatterChart(_ points: [BodyInsights.StrainSensitivity.Pair], slope: Double) -> some View {
        let xs = points.map(\.strain), ys = points.map(\.recovery)
        let mx = xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        let my = ys.isEmpty ? 0 : ys.reduce(0, +) / Double(ys.count)
        let x0 = xs.min() ?? 0, x1 = xs.max() ?? 1
        return axes(Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("Effort", p.strain), y: .value("Recovery", p.recovery))
                    .foregroundStyle(muted)
                    .symbolSize(large ? 30 : 10)
            }
            LineMark(x: .value("Effort", x0), y: .value("Recovery", my + slope * (x0 - mx)), series: .value("Fit", "fit"))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            LineMark(x: .value("Effort", x1), y: .value("Recovery", my + slope * (x1 - mx)), series: .value("Fit", "fit"))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
        }
        .chartYScale(domain: 0...100))
    }
}
