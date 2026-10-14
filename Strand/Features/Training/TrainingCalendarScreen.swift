import SwiftUI
import StrandDesign
import WhoopStore

/// Pushed from the week card's "Month" button.
struct TrainingCalendarRoute: Hashable {}

// MARK: - Month calendar
//
// One month of days, each a circle: a day with sessions is filled in the sport's colour with its symbol
// (the count in a small dot from two sessions up); a day with a Lift Log routine planned on its weekday
// is a dashed outline. Tapping a day opens its sheet: the sessions, and for today or a future day the
// planned routine with a Start button. Below the grid, the routines themselves: tap one to choose its
// weekdays, or generate a new one.

struct TrainingCalendarScreen: View {
    @ObservedObject var model: TrainingViewModel

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var liftSession: LiftSessionController
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""

    @State private var monthOffset = 0
    @State private var selectedDay: TrainingWeek.Day?
    @State private var pendingStart: LiftProgramRow?
    @State private var planning: PlanTarget?
    @State private var generating = false

    private struct PlanTarget: Identifiable {
        let program: LiftProgramRow
        var id: String { program.id }
    }

    private var calendar: Calendar { .current }
    /// A year back, three months ahead.
    private static let monthRange = -12...3
    private static let cellSize: CGFloat = 38

    var body: some View {
        ScreenScaffold(title: "\(TrainingStrings.calendarTitle)") {
            monthCard
            routinesCard
        }
        .sheet(item: $selectedDay, onDismiss: startPendingRoutine) { day in
            TrainingDaySheet(day: day) { program in
                pendingStart = program
                selectedDay = nil
            }
            .environmentObject(repo)
        }
        .sheet(item: $planning) { target in
            LiftProgramPlanSheet(program: target.program)
        }
        .sheet(isPresented: $generating) {
            LiftRoutineGenerateSheet { await model.refresh() }
        }
        .onChangeCompat(of: planRaw) { model.updatePlan(raw: $0) }
    }

    // MARK: Month

    private var monthCard: some View {
        let month = monthStart(offset: monthOffset)
        let byDay = sessionsByDay
        let plan = TrainingPlan.decode(planRaw)
        let today = calendar.startOfDay(for: Date())
        return ContentCard {
            header(month)
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: ZoopSpacing.s) {
                ForEach(cells(for: month), id: \.self) { date in
                    if let date {
                        let day = dayModel(date, today: today, byDay: byDay, plan: plan)
                        Button { selectedDay = day } label: { dayCell(day) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(day))
                    } else {
                        Color.clear.frame(height: Self.cellSize)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                step(value.translation.width < 0 ? 1 : -1)
            })
        }
    }

    private func header(_ month: Date) -> some View {
        HStack(spacing: ZoopSpacing.s) {
            Text(month.formatted(Date.FormatStyle().month(.wide).year().locale(AppLanguage.activeLocale)))
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            chevron("chevron.left", enabled: monthOffset > Self.monthRange.lowerBound) { step(-1) }
                .accessibilityLabel("Previous month")
            chevron("chevron.right", enabled: monthOffset < Self.monthRange.upperBound) { step(1) }
                .accessibilityLabel("Next month")
        }
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(StrandPalette.surfaceRaised))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        let next = monthOffset + delta
        guard Self.monthRange.contains(next) else { return }
        withAnimation(.easeOut(duration: 0.2)) { monthOffset = next }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(LiftProgramPlanSheet.orderedWeekdays, id: \.self) { day in
                Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Cells

    private func dayCell(_ day: TrainingWeek.Day) -> some View {
        ZStack {
            if let lead = day.sessions.first {
                Circle().fill(TrainingCalendarStyle.color(for: lead.sport))
                Image(systemName: sportSymbol(lead.sport))
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
            } else if !day.planned.isEmpty, day.isFuture || day.isToday {
                Circle().strokeBorder(StrandPalette.effortColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: sportSymbol("Strength"))
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.effortColor)
            } else {
                Text(verbatim: "\(calendar.component(.day, from: day.date))")
                    .font(ZoopType.caption.monospacedDigit())
                    .foregroundStyle(day.isFuture ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            }
        }
        .frame(width: Self.cellSize, height: Self.cellSize)
        .padding(3)
        .overlay {
            if day.isToday { Circle().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if day.sessions.count > 1 {
                Text(verbatim: "\(day.sessions.count)")
                    .font(ZoopType.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(3)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(_ day: TrainingWeek.Day) -> String {
        let date = day.date.formatted(date: .complete, time: .omitted)
        if !day.sessions.isEmpty { return "\(date), \(TrainingStrings.sessionCount(day.sessions.count))" }
        if let planned = day.planned.first, day.isFuture || day.isToday {
            return "\(date), \(String(localized: "Planned")): \(planned.name)"
        }
        return date
    }

    // MARK: Model

    /// Every date of `month`, padded with nils so the first lands under its weekday column.
    private func cells(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + days.map { Optional($0) }
    }

    private func monthStart(offset: Int) -> Date {
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return calendar.date(byAdding: .month, value: offset, to: thisMonth) ?? thisMonth
    }

    /// Sessions keyed by local start-of-day, longest first so the lead circle shows the main session.
    private var sessionsByDay: [Date: [WorkoutRow]] {
        var map: [Date: [WorkoutRow]] = [:]
        for row in model.rows {
            map[calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row.startTs))), default: []].append(row)
        }
        return map.mapValues { $0.sorted { ($0.endTs - $0.startTs) > ($1.endTs - $1.startTs) } }
    }

    private func dayModel(_ date: Date, today: Date, byDay: [Date: [WorkoutRow]], plan: TrainingPlan) -> TrainingWeek.Day {
        let ids = plan.programIds(on: date, calendar: calendar)
        return TrainingWeek.Day(date: date, sessions: byDay[date] ?? [], effort: nil,
                                planned: model.programs.filter { ids.contains($0.id) },
                                isToday: date == today, isFuture: date > today)
    }

    private func startPendingRoutine() {
        guard let program = pendingStart else { return }
        pendingStart = nil
        Task { await LiftProgramStarter.start(program, repo: repo, session: liftSession) }
    }

    // MARK: Routines

    private var routinesCard: some View {
        let plan = TrainingPlan.decode(planRaw)
        return ContentCard {
            Text(TrainingStrings.routinesTitle)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            if model.programs.isEmpty {
                Text(TrainingStrings.noRoutines)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.programs.enumerated()), id: \.element.id) { index, program in
                Button { planning = PlanTarget(program: program) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.name).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                            Text(weekdaySummary(plan.weekdays[program.id] ?? []))
                                .font(ZoopType.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listCardRow(isFirst: index == 0)
            }
            Button { generating = true } label: {
                Label(TrainingStrings.generateRoutine, systemImage: "sparkles")
            }
            .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    private func weekdaySummary(_ days: [Int]) -> String {
        guard !days.isEmpty else { return TrainingStrings.noWeekdays }
        let names = LiftProgramPlanSheet.orderedWeekdays.filter(days.contains)
            .map { calendar.shortStandaloneWeekdaySymbols[$0 - 1] }
        return names.joined(separator: ", ")
    }
}
