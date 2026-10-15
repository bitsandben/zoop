import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// The day sheet behind a tap on the week strip: that day's workouts (tap for detail) and any Lift Log
// routine planned for today, with a Start button.

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
    let day: TrainingWeek.Day
    var onStart: (LiftProgramRow) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                    if day.sessions.isEmpty && !showsPlan {
                        Text("Nothing logged on this day.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if !day.sessions.isEmpty {
                        ZoopCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(day.sessions.enumerated()), id: \.offset) { index, row in
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
                        ForEach(day.plannedSessions) { session in
                            plannedSessionRow(session)
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

    private var showsPlan: Bool {
        (!day.planned.isEmpty || !day.plannedSessions.isEmpty) && (day.isToday || day.isFuture)
    }

    /// A session of the coach-built plan: what, how long, when.
    private func plannedSessionRow(_ session: PlanSession) -> some View {
        let tint = TrainingCalendarStyle.color(for: session.sport)
        return ContentCard {
            HStack(spacing: ZoopSpacing.m) {
                Image(systemName: sportSymbol(session.sport))
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(PlanFormat.sessionDetail(session))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func workoutRow(_ row: WorkoutRow) -> some View {
        // The detail pushes inside the sheet's own stack, so closing the sheet returns to the page.
        NavigationLink {
            WorkoutDetailView(row: row, presentation: .pushed)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: sportSymbol(row.sport))
                    .font(StrandFont.ui(15, weight: .semibold))
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
                    .font(StrandFont.ui(12, weight: .semibold))
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
                    .font(StrandFont.ui(14, weight: .semibold))
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
