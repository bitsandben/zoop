#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Cycle on Home
//
// The menstrual cycle as a Home card: today's cycle day and phase, when the next period is expected,
// and a bar of the cycle's phases with today marked. Read from logged period starts with the calendar
// method (CycleCalendar), so it works from the first log, without weeks of skin temperature.

/// Converts the store's "yyyy-MM-dd" days to whole day numbers and back.
enum CycleDays {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func number(_ day: String) -> Int? {
        formatter.date(from: day).map { Int(($0.timeIntervalSince1970 / 86_400).rounded(.down)) }
    }

    static func date(_ number: Int) -> Date {
        // Noon local on that calendar day, for display.
        let utc = Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: utc)
        return Calendar.current.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? utc
    }

    static func today() -> Int { number(Repository.localDayKey(Date())) ?? 0 }
}

extension CycleCalendar.Phase {
    var title: String {
        switch self {
        case .menstrual: return String(localized: "Period")
        case .follicular: return String(localized: "Follicular phase")
        case .ovulatory: return String(localized: "Ovulation window")
        case .luteal: return String(localized: "Luteal phase")
        }
    }

    var tint: Color {
        switch self {
        case .menstrual: return StrandPalette.statusCritical
        case .follicular: return StrandPalette.stressLow
        case .ovulatory: return StrandPalette.accent
        case .luteal: return StrandPalette.restColor
        }
    }
}

struct HomeCycleCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var starts: [String] = []

    private var estimate: CycleCalendar.Estimate? {
        CycleCalendar.estimate(periodStarts: starts.compactMap(CycleDays.number), today: CycleDays.today())
    }

    var body: some View {
        NavigationLink(value: TabRoute.cycle) { content }
            .buttonStyle(LiquidPressStyle())
            .task(id: repo.cycleTrackingSeq) { starts = await repo.periodStarts() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            HStack {
                Text("Cycle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let e = estimate {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Day \(e.cycleDay)")
                            .font(StrandFont.display(34))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(e.phase.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(e.phase.tint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(nextLine(e))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(CycleDays.date(e.nextPeriodStart).formatted(.dateTime.day().month(.abbreviated)))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                CycleBar(estimate: e)
                Text(e.cyclesUsed == 0
                     ? String(localized: "Estimate from a 28-day cycle until you log a second period.")
                     : String(localized: "Your cycle averages \(e.cycleLength) days. An estimate, not contraception."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Log the first day of your period to see your cycle day, phase and next period.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Log period")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(StrandPalette.textPrimary))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface())
    }

    private func nextLine(_ e: CycleCalendar.Estimate) -> String {
        switch e.daysUntilNextPeriod {
        case ..<0: return String(localized: "Period \(-e.daysUntilNextPeriod) days late")
        case 0: return String(localized: "Period expected today")
        case 1: return String(localized: "Period tomorrow")
        default: return String(localized: "Period in \(e.daysUntilNextPeriod) days")
        }
    }
}

/// The cycle as a bar of its phases with a marker on today.
private struct CycleBar: View {
    let estimate: CycleCalendar.Estimate

    var body: some View {
        GeometryReader { geo in
            let len = max(estimate.cycleLength, estimate.cycleDay)
            let w = geo.size.width
            let unit = w / CGFloat(len)
            let ov = estimate.ovulationDay
            let segments: [(CycleCalendar.Phase, Int, Int)] = [
                (.menstrual, 1, estimate.periodLength),
                (.follicular, estimate.periodLength + 1, max(estimate.periodLength, ov - 3)),
                (.ovulatory, ov - 2, ov + 1),
                (.luteal, ov + 2, len),
            ]
            ZStack(alignment: .leading) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.2 >= seg.1 {
                        Capsule()
                            .fill(seg.0.tint.opacity(seg.0 == estimate.phase ? 1 : 0.4))
                            .frame(width: max(2, CGFloat(seg.2 - seg.1 + 1) * unit - 3), height: 8)
                            .offset(x: CGFloat(seg.1 - 1) * unit)
                    }
                }
                Circle()
                    .fill(StrandPalette.textPrimary)
                    .frame(width: 14, height: 14)
                    .offset(x: min(w - 14, max(0, (CGFloat(estimate.cycleDay) - 0.5) * unit - 7)))
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Log or remove period starts.
struct CycleLogSheet: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var starts: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("First day of period", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(StrandPalette.accent)
                    Button {
                        Task { await repo.logPeriodStart(day: Repository.localDayKey(date)); await reload() }
                    } label: {
                        Text(starts.contains(Repository.localDayKey(date)) ? "Already logged" : "Log period start")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(starts.contains(Repository.localDayKey(date)))
                }
                if !starts.isEmpty {
                    Section("Logged") {
                        ForEach(starts.reversed(), id: \.self) { day in
                            Text(CycleDays.number(day).map { CycleDays.date($0).formatted(date: .long, time: .omitted) } ?? day)
                        }
                        .onDelete { offsets in
                            let days = offsets.map { Array(starts.reversed())[$0] }
                            Task {
                                for d in days { await repo.deletePeriodStart(day: d) }
                                await reload()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Cycle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await reload() }
        }
    }

    private func reload() async { starts = await repo.periodStarts() }
}
#endif
