import SwiftUI
import StrandDesign
import WhoopStore

// The training calendar at the top of Workouts: one month of days, each a circle.
//
// A day with saved workouts is a filled circle in the sport's colour carrying the sport's symbol,
// with the count in a small dark dot when there were two or more. A future day with a Lift Log
// program planned on its weekday (`TrainingPlan`) is a dashed outline with the program symbol.
// Today carries a ring. Tapping a day opens a short sheet listing its workouts and planned routine.

struct TrainingCalendarCard: View {
    /// The workouts the Workouts screen already loaded (its whole window, unfiltered).
    let rows: [WorkoutRow]
    /// Open a workout's detail; called after the day sheet has closed.
    var onOpenWorkout: (WorkoutRow) -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: LiftSessionController
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""

    @State private var monthOffset = 0
    @State private var programs: [LiftProgramRow] = []
    @State private var selectedDay: CalendarDay?
    @State private var pendingWorkout: WorkoutRow?
    @State private var pendingStart: LiftProgramRow?

    private var calendar: Calendar { .current }

    /// How far the month chevrons can travel: a year back, three months ahead.
    private static let monthRange = -12...3

    private static let cellSize: CGFloat = 38

    var body: some View {
        let month = monthStart(offset: monthOffset)
        let byDay = workoutsByDay
        let plan = TrainingPlan.decode(planRaw)
        let today = calendar.startOfDay(for: Date())

        ZoopCard {
            VStack(alignment: .leading, spacing: 12) {
                header(month)
                weekdayHeader
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
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
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            step(value.translation.width < 0 ? 1 : -1)
                        }
                )
            }
        }
        .task(id: repo.refreshSeq) { await loadPrograms() }
        .onChange(of: planRaw) { _ in Task { await loadPrograms() } }
        .sheet(item: $selectedDay, onDismiss: runPending) { day in
            TrainingDaySheet(day: day,
                             onOpenWorkout: { row in pendingWorkout = row; selectedDay = nil },
                             onStart: { program in pendingStart = program; selectedDay = nil })
        }
    }

    // MARK: - Header

    private func header(_ month: Date) -> some View {
        HStack(spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(StrandFont.headline)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: ZoopMetrics.compactControlSize, height: ZoopMetrics.compactControlSize)
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
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Cells

    @ViewBuilder
    private func dayCell(_ day: CalendarDay) -> some View {
        let size = Self.cellSize
        ZStack {
            if let lead = day.workouts.first {
                let tint = TrainingCalendarStyle.color(for: lead.sport)
                Circle().fill(tint)
                Image(systemName: sportSymbol(lead.sport))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
            } else if let planned = day.planned.first, day.isFuture || day.isToday {
                Circle()
                    .strokeBorder(StrandPalette.effortColor,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: sportSymbol("Strength"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .accessibilityLabel(planned.name)
            } else {
                Text(verbatim: "\(calendar.component(.day, from: day.date))")
                    .font(StrandFont.subhead.monospacedDigit())
                    .foregroundStyle(day.isFuture ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .padding(3)
        .overlay {
            if day.isToday {
                Circle().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if day.workouts.count > 1 {
                Text(verbatim: "\(day.workouts.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(_ day: CalendarDay) -> String {
        let date = day.date.formatted(date: .complete, time: .omitted)
        if !day.workouts.isEmpty {
            return String(localized: "\(date), \(day.workouts.count) workouts")
        }
        if let planned = day.planned.first, day.isFuture || day.isToday {
            return String(localized: "\(date), planned: \(planned.name)")
        }
        return date
    }

    // MARK: - Model

    /// Every date of `month`, padded with nils so the first lands under its weekday column.
    private func cells(for month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + days.map { Optional($0) }
    }

    private func monthStart(offset: Int) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: Date())
        let thisMonth = calendar.date(from: comps) ?? Date()
        return calendar.date(byAdding: .month, value: offset, to: thisMonth) ?? thisMonth
    }

    /// Workouts keyed by local start-of-day, each day's list longest first so the lead circle shows
    /// the main session.
    private var workoutsByDay: [Date: [WorkoutRow]] {
        var map: [Date: [WorkoutRow]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            map[day, default: []].append(row)
        }
        for key in map.keys {
            map[key]?.sort { ($0.endTs - $0.startTs) > ($1.endTs - $1.startTs) }
        }
        return map
    }

    private func dayModel(_ date: Date, today: Date, byDay: [Date: [WorkoutRow]],
                          plan: TrainingPlan) -> CalendarDay {
        let ids = plan.programIds(on: date, calendar: calendar)
        let planned = programs.filter { ids.contains($0.id) }
        return CalendarDay(date: date,
                           workouts: byDay[date] ?? [],
                           planned: planned,
                           isToday: date == today,
                           isFuture: date > today)
    }

    private func loadPrograms() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
    }

    private func runPending() {
        if let row = pendingWorkout {
            pendingWorkout = nil
            onOpenWorkout(row)
        }
        if let program = pendingStart {
            pendingStart = nil
            Task { await LiftProgramStarter.start(program, repo: repo, session: session) }
        }
    }
}

/// One calendar day and what is on it.
struct CalendarDay: Identifiable {
    let date: Date
    let workouts: [WorkoutRow]
    let planned: [LiftProgramRow]
    let isToday: Bool
    let isFuture: Bool
    var id: Date { date }
}

/// Sport → calendar fill colour, by sport family, from palette tokens only.
enum TrainingCalendarStyle {
    static func color(for sport: String) -> Color {
        guard let type = KnownWorkoutType.resolving(sport) else { return StrandPalette.accent }
        switch type {
        case .strength, .bodybuilding, .weightlifting, .crossfit, .calisthenics, .hiit, .bootCamp,
             .gymnastics:
            return StrandPalette.effortColor
        case .running, .walking, .nordicWalking, .hiking, .treadmillRun, .treadmillWalk, .stairClimber,
             .elliptical, .snowshoeing:
            return StrandPalette.statusPositive
        case .cycling, .indoorCycle, .motocross:
            return StrandPalette.metricCyan
        case .openWaterSwim, .poolSwim, .rowing, .rowMachine, .kayaking, .surfing, .sailing,
             .scubaDiving, .waterPolo, .kiteboarding:
            return StrandPalette.sleepLight
        case .yoga, .pilates, .stretching, .ballet, .dancing, .breakdancing:
            return StrandPalette.metricPurple
        case .boxing, .martialArts, .jiuJitsu, .judo, .muayThai, .fencing:
            return StrandPalette.metricRose
        default:
            return StrandPalette.metricAmber
        }
    }
}

// MARK: - Day sheet

/// What one calendar day holds: its workouts (tap for detail) and any routine planned on it.
struct TrainingDaySheet: View {
    let day: CalendarDay
    var onOpenWorkout: (WorkoutRow) -> Void
    var onStart: (LiftProgramRow) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                    if day.workouts.isEmpty && !showsPlan {
                        Text("Nothing logged on this day.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if !day.workouts.isEmpty {
                        ZoopCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(day.workouts.enumerated()), id: \.offset) { index, row in
                                    if index > 0 { Divider().overlay(StrandPalette.hairline) }
                                    workoutRow(row)
                                }
                            }
                        }
                    }
                    if showsPlan {
                        ForEach(day.planned, id: \.id) { program in
                            plannedRow(program)
                        }
                    }
                }
                .padding(ZoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 420, height: 480)
        #endif
    }

    private var showsPlan: Bool { !day.planned.isEmpty && (day.isFuture || day.isToday) }

    private func workoutRow(_ row: WorkoutRow) -> some View {
        Button { onOpenWorkout(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: sportSymbol(row.sport))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(TrainingCalendarStyle.color(for: row.sport)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle(row))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ZoopMetrics.cardPadding)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ row: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let time = start.formatted(date: .omitted, time: .shortened)
        let minutes = max(0, (row.endTs - row.startTs) / 60)
        return "\(time) · \(minutes) min"
    }

    private func plannedRow(_ program: LiftProgramRow) -> some View {
        ZoopCard {
            HStack(spacing: 12) {
                Image(systemName: sportSymbol("Strength"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(StrandPalette.effortColor,
                                                   style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Planned")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                }
                Spacer(minLength: 0)
                Button("Start") { onStart(program) }
                    .buttonStyle(.noopPrimary)
                    .frame(maxWidth: 96)
            }
        }
    }
}
