#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - What your nights show
//
// At most two interpretations `SleepInsights` can make from the stored nights, and only those that
// found a real difference. Regularity and the weekend shift live in the rhythm card, and debt in its
// own row, so none of them repeats here. Each card opens a sheet with the larger chart and the method.

struct SleepInsightsSection: View {
    @EnvironmentObject private var repo: Repository
    @State private var report: SleepInsights.Report?
    @State private var detail: SleepInsightKind?

    static let maxShown = 2

    var body: some View {
        let kinds = report.map(SleepInsightKind.shown) ?? []
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if let report, !kinds.isEmpty {
                SleepSectionTitle(LocalizedStringResource("zoop.sleep.insights.title", defaultValue: "What your nights show"))
                ForEach(kinds) { kind in
                    Button { detail = kind } label: { SleepInsightCard(kind: kind, report: report) }
                        .buttonStyle(.plain)
                }
            }
        }
        .task(id: repo.refreshSeq) {
            report = SleepInsights.report(Self.nights(sleeps: repo.sleeps, days: repo.days))
        }
        .sheet(item: $detail) { kind in
            if let report {
                SleepInsightDetailSheet(kind: kind, report: report).presentationDetents([.large])
            }
        }
    }

    /// Main nights (at least three hours in bed), joined to the daily row of their wake day for time
    /// asleep and the next-morning recovery.
    static func nights(sleeps: [CachedSleepSession], days: [DailyMetric]) -> [SleepInsights.Night] {
        var rows: [String: DailyMetric] = [:]
        for d in days { rows[d.day] = d }
        let cal = Calendar.current
        // The engine looks back at most 90 nights; the margin covers naps and split nights.
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

    /// Minutes to the first staged sleep, only for a night with a real timeline that was not staged on
    /// sparse motion.
    private static func latency(_ s: CachedSleepSession, start: Int) -> Double? {
        guard s.stagingSparse != true,
              let decoded = SleepScreen.decodeSegments(s.stagesJSON, sessionStart: start),
              decoded.intervals.count >= 2 else { return nil }
        return SleepLatency.minutes(segments: decoded.intervals.map { ($0.start, $0.end, $0.stage != .awake) })
    }
}

// MARK: - Kinds and copy

enum SleepInsightKind: String, CaseIterable, Identifiable {
    case latency, sleepNeed, bedtime
    var id: String { rawValue }

    /// The kinds that found a difference worth naming, at most `maxShown`.
    static func shown(_ r: SleepInsights.Report) -> [SleepInsightKind] {
        Array(allCases.filter { $0.isSignificant(in: r) }.prefix(SleepInsightsSection.maxShown))
    }

    func isSignificant(in r: SleepInsights.Report) -> Bool {
        switch self {
        case .latency: return r.latency.map { $0.trend != .steady } ?? false
        case .sleepNeed: return r.sleepNeed.map { !$0.isFlat } ?? false
        case .bedtime: return r.bedtime.map { !$0.isFlat } ?? false
        }
    }

    var title: String {
        switch self {
        case .latency: return String(localized: "Falling asleep")
        case .sleepNeed: return String(localized: "Sleep for recovery")
        case .bedtime: return String(localized: "Best bedtime")
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
        }
    }

    /// The one sentence the card and the sheet share, so the two cannot disagree.
    func headline(_ r: SleepInsights.Report) -> String? {
        switch self {
        case .latency:
            guard let l = r.latency else { return nil }
            let d = Int(abs(l.deltaMin).rounded())
            switch l.trend {
            case .faster: return String(localized: "Over the last 7 nights you fell asleep \(d) min faster than usual.")
            case .slower: return String(localized: "Over the last 7 nights you took \(d) min longer than usual to fall asleep.")
            case .steady: return String(localized: "Over the last 7 nights you fell asleep about as fast as usual.")
            }
        case .sleepNeed:
            guard let n = r.sleepNeed else { return nil }
            let value = SleepInsightFormat.duration(n.best.center)
            return String(localized: "You recover best after about \(value) of sleep.")
        case .bedtime:
            guard let b = r.bedtime else { return nil }
            let lo = SleepInsightFormat.clock(b.best.lower), hi = SleepInsightFormat.clock(b.best.upper)
            return String(localized: "Your best recoveries follow bedtimes between \(lo) and \(hi).")
        }
    }
}

enum SleepInsightFormat {
    static func duration(_ minutes: Double) -> String {
        SleepReadouts.durationText(seconds: minutes * 60)
    }

    /// Signed minutes from midnight as a local clock time.
    static func clock(_ signed: Double) -> String {
        let c = Int(SleepInsights.clock(fromSigned: signed).rounded())
        let start = Calendar.current.startOfDay(for: Date())
        return AppClock.hourMinuteFormatter().string(from: start.addingTimeInterval(Double(c * 60)))
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
#endif
