#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Cycle screen
//
// The menstrual cycle as a month calendar: each day carries its phase as a band, logged period days are
// marked, projected days are dimmed, and today is ringed. The header gives the cycle day, the phase and
// the window the next period is expected in; the phase card below says what each phase is.

struct CycleScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var starts: [String] = []
    @State private var monthOffset = 0
    @State private var showLog = false
    @State private var selectedPhase: CycleCalendar.Phase?

    private var startNumbers: [Int] { starts.compactMap(CycleDays.number) }
    private var today: Int { CycleDays.today() }
    private var estimate: CycleCalendar.Estimate? {
        CycleCalendar.estimate(periodStarts: startNumbers, today: today)
    }

    var body: some View {
        ScreenScaffold(title: "Cycle") {
            VStack(alignment: .leading, spacing: ZoopMetrics.sectionSpacing) {
                header
                calendarCard
                logRow
                if let e = estimate { phaseCard(current: e.phase) }
            }
        }
        .task(id: repo.cycleTrackingSeq) { starts = await repo.periodStarts() }
        .sheet(isPresented: $showLog) {
            CycleLogSheet()
                .environmentObject(repo)
                .noopSheetPresentation(largeFirst: true)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let e = estimate {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Cycle day \(e.cycleDay)")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 22)
                    Text(e.phase.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(e.phase.tint)
                }
                if let w = CycleCalendar.nextPeriodWindow(periodStarts: startNumbers, today: today) {
                    Text(windowLine(w))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if e.cyclesUsed < 2 {
                    Label("Still learning your cycle. Predictions sharpen with each period you log.",
                          systemImage: "sparkles")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        } else {
            Text("Log the first day of your period to start. Zoop learns your cycle from what you log.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func windowLine(_ w: ClosedRange<Int>) -> String {
        if w.upperBound < 0 { return String(localized: "Period is late") }
        let lo = max(0, w.lowerBound)
        return lo == w.upperBound
            ? String(localized: "Next period in \(lo) days")
            : String(localized: "Next period in \(lo)–\(w.upperBound) days")
    }

    // MARK: Calendar

    private var monthStart: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return cal.date(byAdding: .month, value: monthOffset, to: base) ?? base
    }

    private var calendarCard: some View {
        let cal = Calendar(identifier: .iso8601)   // weeks start on Monday
        let first = monthStart
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = (cal.component(.weekday, from: first) + 5) % 7
        let cells: [Int?] = Array(repeating: nil, count: leading) + (1...daysInMonth).map { Optional($0) }
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(spacing: ZoopMetrics.space3) {
            HStack {
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                Text(first.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 140)
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                Spacer()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(Array(cal.veryShortStandaloneWeekdaySymbols.enumerated().map { $0 }), id: \.offset) { i, _ in
                    let symbols = cal.shortStandaloneWeekdaySymbols
                    Text(symbols[(i + 1) % 7])
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let day = i < row.count ? row[i] : nil
                        dayCell(day, row: row, index: i, first: first)
                    }
                }
            }
            legend
        }
        .padding(16)
        .background(ZoopPanelSurface())
    }

    private func dayNumber(_ dayOfMonth: Int, first: Date) -> Int? {
        let date = Calendar.current.date(byAdding: .day, value: dayOfMonth - 1, to: first) ?? first
        return CycleDays.number(Repository.localDayKey(date))
    }

    private func info(_ dayOfMonth: Int?, first: Date) -> CycleCalendar.DayInfo? {
        guard let d = dayOfMonth, let n = dayNumber(d, first: first) else { return nil }
        return CycleCalendar.dayInfo(n, periodStarts: startNumbers, today: today)
    }

    @ViewBuilder
    private func dayCell(_ dayOfMonth: Int?, row: [Int?], index: Int, first: Date) -> some View {
        let me = info(dayOfMonth, first: first)
        let prev = index > 0 ? info(row[index - 1], first: first) : nil
        let next = index < row.count - 1 ? info(row[index + 1], first: first) : nil
        let joinsLeft = me != nil && prev?.phase == me?.phase
        let joinsRight = me != nil && next?.phase == me?.phase
        let isToday = dayOfMonth.flatMap { dayNumber($0, first: first) } == today
        ZStack {
            if let me {
                // A band that runs across consecutive days of one phase, rounded where the phase changes.
                UnevenRoundedRectangle(topLeadingRadius: joinsLeft ? 0 : 18, bottomLeadingRadius: joinsLeft ? 0 : 18,
                                       bottomTrailingRadius: joinsRight ? 0 : 18, topTrailingRadius: joinsRight ? 0 : 18)
                    .fill(me.phase.tint.opacity(me.predicted ? 0.28 : 0.75))
                    .frame(height: 36)
                if me.loggedPeriod {
                    Circle().fill(StrandPalette.statusCritical).frame(width: 30, height: 30)
                }
            }
            if let d = dayOfMonth {
                Text("\(d)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(me?.predicted == true || me == nil ? StrandPalette.textSecondary : StrandPalette.textPrimary)
            }
            if isToday {
                Circle().stroke(StrandPalette.textPrimary, lineWidth: 2).frame(width: 40, height: 40)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
    }

    private var legend: some View {
        let phases: [CycleCalendar.Phase] = [.menstrual, .follicular, .ovulatory, .luteal]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(phases, id: \.self) { p in
                HStack(spacing: 8) {
                    Capsule().fill(p.tint).frame(width: 18, height: 8)
                    Text(p.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Log + phases

    private var logRow: some View {
        Button { showLog = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                Text("Log period data")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(StrandPalette.textPrimary))
            }
            .padding(14)
            .background(ZoopPanelSurface())
        }
        .buttonStyle(LiquidPressStyle())
    }

    private func phaseCard(current: CycleCalendar.Phase) -> some View {
        let phases: [CycleCalendar.Phase] = [.menstrual, .follicular, .ovulatory, .luteal]
        let shown = selectedPhase ?? current
        return VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Text("Phases")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: 6) {
                ForEach(phases, id: \.self) { p in
                    Button { selectedPhase = p } label: {
                        Text(String(p.title.prefix(1)))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(p == shown ? p.tint : StrandPalette.textSecondary)
                            .frame(maxWidth: p == shown ? .infinity : 44, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(p == shown ? p.tint.opacity(0.18) : StrandPalette.surfaceBase))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(shown.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(shown.tint)
            Text(shown.summary)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(ZoopPanelSurface())
    }
}

extension CycleCalendar.Phase {
    /// What the phase is, in a few plain sentences.
    var summary: String {
        switch self {
        case .menstrual:
            return String(localized: "Bleeding, usually 3 to 7 days. Oestrogen and progesterone are low; energy can dip early on.")
        case .follicular:
            return String(localized: "Oestrogen rises as an egg matures. Resting heart rate tends to be lowest and HRV highest in this phase.")
        case .ovulatory:
            return String(localized: "Around ovulation, about 14 days before the next period. A short window, often with peak energy.")
        case .luteal:
            return String(localized: "Progesterone rises. Skin temperature and resting heart rate often go up and HRV down until the next period.")
        }
    }
}
#endif
