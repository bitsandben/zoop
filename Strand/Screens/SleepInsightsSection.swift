#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Sleep insights section (Zoop)
//
// "What your nights show": one flat card per interpretation `SleepInsights` can make from the stored
// nights (time to fall asleep, the sleep length and bedtime the wearer recovers best after, whether a
// regular bedtime pays off, and the weekend shift). Each card opens a detail sheet with the larger chart
// and one sentence on how it is computed.
//
// Standalone: it reads the repository from the environment, so it can be mounted on the Sleep screen or
// on any other tab. Sleep debt is not repeated here; `SleepDebtLedgerCard` already shows it.

struct SleepInsightsSection: View {
    @EnvironmentObject private var repo: Repository
    @State private var report: SleepInsights.Report?
    @State private var detail: SleepInsightKind?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            SectionHeader("What your nights show")
            if let report {
                if report.isEmpty {
                    ZoopCard {
                        Text("Insights appear after about two weeks of nights with a recovery score.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(SleepInsightKind.allCases) { kind in
                        if kind.isAvailable(in: report) {
                            Button { detail = kind } label: {
                                SleepInsightCard(kind: kind, report: report)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: repo.refreshSeq) {
            report = SleepInsights.report(Self.nights(sleeps: repo.sleeps, days: repo.days))
        }
        .sheet(item: $detail) { kind in
            if let report {
                SleepInsightDetailSheet(kind: kind, report: report)
                    .presentationDetents([.large])
            }
        }
    }

    /// Main nights (at least three hours in bed) from the stored sessions, joined to the daily row of
    /// their wake day for time asleep and the next-morning recovery.
    static func nights(sleeps: [CachedSleepSession], days: [DailyMetric]) -> [SleepInsights.Night] {
        var rows: [String: DailyMetric] = [:]
        for d in days { rows[d.day] = d }
        let cal = Calendar.current
        // The engine looks back at most 90 nights; a margin covers naps and split nights.
        return sleeps.suffix(240).compactMap { s in
            let start = s.effectiveStartTs
            let inBed = Double(s.endTs - start) / 60
            guard inBed >= 180 else { return nil }
            let wakeDate = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            let key = Repository.localDayKey(wakeDate)
            let row = rows[key]
            let bed = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(start)))
            let efficiencyAsleep = s.efficiency.map { e in inBed * (e > 1.5 ? e / 100 : e) }
            let weekday = cal.component(.weekday, from: wakeDate)
            return SleepInsights.Night(
                wakeDay: key,
                bedtimeClockMin: Double((bed.hour ?? 0) * 60 + (bed.minute ?? 0)),
                inBedMin: inBed,
                asleepMin: row?.totalSleepMin ?? efficiencyAsleep,
                latencyMin: latency(s, start: start),
                recovery: row?.recovery,
                isFreeDay: weekday == 1 || weekday == 7)
        }
    }

    /// Minutes to the first staged sleep, only for a night with a real timeline (imported nights store
    /// stage totals without one) that was not staged on sparse motion.
    private static func latency(_ s: CachedSleepSession, start: Int) -> Double? {
        guard s.stagingSparse != true,
              let decoded = SleepView.decodeSegments(s.stagesJSON, sessionStart: start),
              decoded.intervals.count >= 2 else { return nil }
        return SleepLatency.minutes(segments: decoded.intervals.map { ($0.start, $0.end, $0.stage != .awake) })
    }
}

// MARK: - Kinds and copy

enum SleepInsightKind: String, CaseIterable, Identifiable {
    case latency, sleepNeed, bedtime, consistency, weekendShift
    var id: String { rawValue }

    func isAvailable(in r: SleepInsights.Report) -> Bool {
        switch self {
        case .latency: return r.latency != nil
        case .sleepNeed: return r.sleepNeed != nil
        case .bedtime: return r.bedtime != nil
        case .consistency: return r.consistency != nil
        case .weekendShift: return r.weekendShift != nil
        }
    }

    var title: String {
        switch self {
        case .latency: return String(localized: "Falling asleep")
        case .sleepNeed: return String(localized: "Sleep for recovery")
        case .bedtime: return String(localized: "Best bedtime")
        case .consistency: return String(localized: "Regular bedtime")
        case .weekendShift: return String(localized: "Weekend shift")
        }
    }

    var method: String {
        switch self {
        case .latency:
            return String(localized: "The median time from the start of the night to the first staged sleep over your last 30 nights, compared with the median of the last 7.")
        case .sleepNeed:
            return String(localized: "Nights from the last 90 days are grouped by time asleep in 30-minute steps, each bar is the average recovery the next morning, and the shortest step within 5 points of the best one is named.")
        case .bedtime:
            return String(localized: "Nights from the last 90 days are grouped by bedtime in 30-minute steps, and each bar is the average recovery the next morning, counting steps with at least 3 nights.")
        case .consistency:
            return String(localized: "Nights within 30 minutes of your median bedtime count as regular, and the bars compare the average recovery after regular and other nights over the last 90 days.")
        case .weekendShift:
            return String(localized: "The midpoint between bedtime and wake time, averaged over nights before Saturday and Sunday and over the other nights of the last six weeks.")
        }
    }
}

/// Number + sentence for one insight, shared by the card and the sheet so the two cannot disagree.
private struct SleepInsightCopy {
    let value: String
    let caption: String
    let headline: String

    init?(_ kind: SleepInsightKind, _ r: SleepInsights.Report) {
        switch kind {
        case .latency:
            guard let l = r.latency else { return nil }
            value = Fmt.duration(l.typicalMin)
            caption = String(localized: "typical")
            let d = Int(abs(l.deltaMin).rounded())
            switch l.trend {
            case .faster: headline = String(localized: "Over the last 7 nights you fell asleep \(d) min faster than usual.")
            case .slower: headline = String(localized: "Over the last 7 nights you took \(d) min longer than usual to fall asleep.")
            case .steady: headline = String(localized: "Over the last 7 nights you fell asleep about as fast as usual.")
            }
        case .sleepNeed:
            guard let n = r.sleepNeed else { return nil }
            if n.isFlat {
                let lo = Fmt.duration(n.bins.first?.lower ?? n.best.lower)
                let hi = Fmt.duration(n.bins.last?.upper ?? n.best.upper)
                value = "\(lo)–\(hi)"
                caption = String(localized: "asleep")
                headline = String(localized: "Your recovery barely changes with sleep length between \(lo) and \(hi).")
            } else {
                value = Fmt.duration(n.best.center)
                caption = String(localized: "asleep")
                headline = String(localized: "You recover best after about \(value) of sleep.")
            }
        case .bedtime:
            guard let b = r.bedtime else { return nil }
            let lo = Fmt.clock(b.best.lower), hi = Fmt.clock(b.best.upper)
            value = "\(lo)–\(hi)"
            caption = String(localized: "bedtime")
            headline = b.isFlat
                ? String(localized: "Your bedtime makes little difference to your recovery so far.")
                : String(localized: "Your best recoveries follow bedtimes between \(lo) and \(hi).")
        case .consistency:
            guard let c = r.consistency else { return nil }
            let d = Int(abs(c.deltaPts).rounded())
            value = Fmt.signedPoints(c.deltaPts)
            caption = String(localized: "recovery points")
            switch c.effect {
            case .regularBetter:
                headline = String(localized: "After nights within 30 min of your usual bedtime you recover \(d) points better.")
            case .irregularBetter:
                headline = String(localized: "Nights away from your usual bedtime have recovered \(d) points better so far.")
            case .none:
                headline = String(localized: "A regular bedtime makes no clear difference to your recovery yet.")
            }
        case .weekendShift:
            guard let w = r.weekendShift else { return nil }
            let mag = Fmt.duration(abs(w.shiftMin))
            value = mag
            caption = w.shiftMin >= 0 ? String(localized: "later on weekends") : String(localized: "earlier on weekends")
            if abs(w.shiftMin) < 15 {
                headline = String(localized: "Your sleep timing stays steady between weekdays and weekends.")
            } else if w.shiftMin > 0 {
                headline = String(localized: "On weekends your sleep shifts \(mag) later than on weekdays.")
            } else {
                headline = String(localized: "On weekends your sleep shifts \(mag) earlier than on weekdays.")
            }
        }
    }
}

private enum Fmt {
    static func duration(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m) min") }
        if m % 60 == 0 { return String(localized: "\(m / 60) h") }
        return String(localized: "\(m / 60) h \(m % 60) min")
    }

    /// Signed minutes from midnight as a local clock time.
    static func clock(_ signed: Double) -> String {
        let c = Int(SleepInsights.clock(fromSigned: signed).rounded())
        var comps = DateComponents()
        comps.hour = (c / 60) % 24
        comps.minute = c % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.activeLocale))
    }

    static func signedPoints(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : r < 0 ? "−\(abs(r))" : "0"
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date { dayParser.date(from: day) ?? Date() }
}

// MARK: - Card

private struct SleepInsightCard: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report

    var body: some View {
        if let copy = SleepInsightCopy(kind, report) {
            ZoopCard {
                VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: kind.title).strandOverline()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                        Text(verbatim: copy.value)
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(verbatim: copy.caption)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text(verbatim: copy.headline)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SleepInsightChart(kind: kind, report: report, large: false)
                        .frame(height: 72)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the details"))
        }
    }
}

// MARK: - Detail sheet

private struct SleepInsightDetailSheet: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let copy = SleepInsightCopy(kind, report) {
                    VStack(alignment: .leading, spacing: ZoopMetrics.sectionSpacing) {
                        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                            HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                                Text(verbatim: copy.value)
                                    .font(StrandFont.number(40))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Text(verbatim: copy.caption)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Text(verbatim: copy.headline)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ZoopCard {
                            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                                SleepInsightChart(kind: kind, report: report, large: true)
                                    .frame(height: ZoopMetrics.chartHeight)
                                Divider().overlay(StrandPalette.hairline)
                                footer
                            }
                        }
                        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                            Text("How it's computed").strandOverline()
                            Text(verbatim: kind.method)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(ZoopMetrics.screenPadding)
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(verbatim: kind.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch kind {
        case .latency:
            if let l = report.latency {
                ChartFooter([("Typical", Fmt.duration(l.typicalMin)),
                             ("Last 7 nights", Fmt.duration(l.recentMin)),
                             ("Nights", "\(l.nightCount)")])
            }
        case .sleepNeed:
            if let n = report.sleepNeed {
                ChartFooter([("Best recovery", "\(Int(n.best.meanRecovery.rounded()))"),
                             ("Range", "\(Int(n.spreadPts.rounded()))"),
                             ("Nights", "\(n.nightCount)")])
            }
        case .bedtime:
            if let b = report.bedtime {
                ChartFooter([("Best recovery", "\(Int(b.best.meanRecovery.rounded()))"),
                             ("Range", "\(Int(b.spreadPts.rounded()))"),
                             ("Nights", "\(b.nightCount)")])
            }
        case .consistency:
            if let c = report.consistency {
                ChartFooter([("Usual bedtime", Fmt.clock(c.usualBedtimeSignedMin)),
                             ("Regular nights", "\(c.regularCount)"),
                             ("Other nights", "\(c.irregularCount)")])
            }
        case .weekendShift:
            if let w = report.weekendShift {
                ChartFooter([("Weekdays", Fmt.clock(w.workdayMidSleepSignedMin)),
                             ("Weekends", Fmt.clock(w.freeDayMidSleepSignedMin)),
                             ("Nights", "\(w.workdayCount + w.freeDayCount)")])
            }
        }
    }
}

// MARK: - Charts

private struct SleepInsightChart: View {
    let kind: SleepInsightKind
    let report: SleepInsights.Report
    let large: Bool

    private var highlight: Color { StrandPalette.restColor }
    private var muted: Color { StrandPalette.textTertiary.opacity(0.45) }

    var body: some View {
        switch kind {
        case .latency: latencyChart
        case .sleepNeed: binChart(report.sleepNeed, label: { Fmt.duration($0) })
        case .bedtime: binChart(report.bedtime, label: { Fmt.clock($0) })
        case .consistency: consistencyChart
        case .weekendShift: weekendChart
        }
    }

    // 30 nights of latency as dots, the typical value as a dashed line, the recent median as a solid one.
    @ViewBuilder
    private var latencyChart: some View {
        if let l = report.latency {
            let recent = Set(l.recentDays)
            let recentDates = l.recentDays.map(Fmt.date)
            Chart {
                ForEach(l.series, id: \.day) { p in
                    PointMark(x: .value("Night", Fmt.date(p.day)), y: .value("Minutes", p.value))
                        .foregroundStyle(recent.contains(p.day) ? highlight : muted)
                        .symbolSize(large ? 40 : 18)
                }
                RuleMark(y: .value("Typical", l.typicalMin))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let first = recentDates.first, let last = recentDates.last {
                    RuleMark(xStart: .value("From", first), xEnd: .value("To", last),
                             y: .value("Last 7 nights", l.recentMin))
                        .foregroundStyle(highlight)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .chartXAxis(large ? .automatic : .hidden)
            .chartYAxis(large ? .automatic : .hidden)
            .accessibilityLabel(Text("Time to fall asleep over the last \(l.nightCount) nights"))
        }
    }

    // Average next-morning recovery per 30-minute bin, the named bin highlighted.
    @ViewBuilder
    private func binChart(_ b: SleepInsights.BinnedRecovery?, label: @escaping (Double) -> String) -> some View {
        if let b {
            Chart(b.bins) { bin in
                BarMark(x: .value("Bin", label(bin.lower)), y: .value("Recovery", bin.meanRecovery))
                    .foregroundStyle(bin.lower == b.best.lower && !b.isFlat ? highlight : muted)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .annotation(position: .top) {
                        if large {
                            Text(verbatim: "\(Int(bin.meanRecovery.rounded()))")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
            }
            .chartXAxis(large ? .automatic : .hidden)
            .chartYAxis(large ? .automatic : .hidden)
            .chartYScale(domain: 0...100)
        }
    }

    // Small: two bars, regular vs other nights. Large: every night's bedtime deviation against recovery.
    @ViewBuilder
    private var consistencyChart: some View {
        if let c = report.consistency {
            if large {
                Chart {
                    ForEach(Array(c.points.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value("Minutes from usual bedtime", p.deviationMin),
                                  y: .value("Recovery", p.recovery))
                            .foregroundStyle(p.deviationMin <= SleepInsights.regularToleranceMin ? highlight : muted)
                            .symbolSize(40)
                    }
                    RuleMark(x: .value("Tolerance", SleepInsights.regularToleranceMin))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 0...100)
            } else {
                Chart {
                    BarMark(x: .value("Recovery", c.regularMeanRecovery), y: .value("Group", String(localized: "Regular")))
                        .foregroundStyle(highlight)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    BarMark(x: .value("Recovery", c.irregularMeanRecovery), y: .value("Group", String(localized: "Other nights")))
                        .foregroundStyle(muted)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .chartXScale(domain: 0...100)
                .chartXAxis(.hidden)
            }
        }
    }

    // Mid-sleep per night; weekends highlighted, each group's average as a dashed line.
    @ViewBuilder
    private var weekendChart: some View {
        if let w = report.weekendShift {
            Chart {
                ForEach(w.series, id: \.day) { p in
                    PointMark(x: .value("Night", Fmt.date(p.day)), y: .value("Mid-sleep", p.midSleepSignedMin))
                        .foregroundStyle(p.isFreeDay ? highlight : muted)
                        .symbolSize(large ? 40 : 18)
                }
                RuleMark(y: .value("Weekdays", w.workdayMidSleepSignedMin))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("Weekends", w.freeDayMidSleepSignedMin))
                    .foregroundStyle(highlight)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis(large ? .automatic : .hidden)
            .chartYAxis {
                if large {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let m = v.as(Double.self) { Text(verbatim: Fmt.clock(m)) }
                        }
                    }
                }
            }
        }
    }
}
#endif
