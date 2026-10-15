import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Training
//
// The Training page, in the order of the questions it answers: what did I do (last 7 days), how loaded am
// I (fitness and fatigue, weekly gauges), what did the weights and muscles take (strength), and the log of
// sessions. Everything it reads comes from `TrainingViewModel`; every Effort figure goes through
// `TrainingEffort` so one scale, the user's, is used throughout.

struct TrainingScreen: View {
    @EnvironmentObject private var repo: Repository
    /// The only live-updating object this page needs is isolated in `WorkoutStartControl`: `AppModel`
    /// publishes the heart rate about once a second, and observing it here would re-run the whole page
    /// on every tick.
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var liftSession: LiftSessionController

    @StateObject private var model: TrainingViewModel

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""

    @State private var daySheet: TrainingWeek.Day?
    /// The routine chosen in the day sheet, started once the sheet has closed.
    @State private var pendingStart: LiftProgramRow?

    /// True when this page is the Training tab root, whose header opens the Lift Log and the interval timer.
    private let asTrainingTab: Bool

    init(previewRows: [WorkoutRow]? = nil, asTrainingTab: Bool = false) {
        self.asTrainingTab = asTrainingTab
        _model = StateObject(wrappedValue: TrainingViewModel(previewRows: previewRows))
    }

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var format: TrainingFormat {
        TrainingFormat(distanceSystem: UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw))
    }

    var body: some View {
        ScreenScaffold(title: asTrainingTab ? "Training" : "Workouts",
                       onRefresh: { await repo.refresh() },
                       lazy: true,
                       trailing: { trainingLinks }) {
            content
        }
        .task(id: repo.refreshSeq) {
            model.attach(repo: repo, profile: profile, intelligence: intelligence)
            await model.refresh()
        }
        .onAppear { model.updatePlan(raw: planRaw) }
        .onChangeCompat(of: planRaw) { model.updatePlan(raw: $0) }
        .navigationDestination(for: TrainingRoute.self) { route in
            if let row = model.row(startTs: route.startTs, sport: route.sport) {
                WorkoutDetailView(row: row, presentation: .pushed)
            }
        }
        .navigationDestination(for: TrainingCalendarRoute.self) { _ in
            TrainingCalendarScreen(model: model)
        }
        .sheet(item: $model.editor) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                model.save(row, replacing: replacing, isCopy: target.isCopy)
            }
        }
        .sheet(item: $daySheet, onDismiss: startPendingRoutine) { day in
            TrainingDaySheet(day: day) { program in
                pendingStart = program
                daySheet = nil
            }
            .environmentObject(repo)
        }
        // Name the merged session when every selected row is a bare detected bout (there is no sport to
        // inherit). Reuses the "Start a workout" sport browser.
        .workoutSelectionCover(item: $model.mergeSportPrompt) { target in
            StartWorkoutSheet(title: String(localized: "Name the merged session"),
                              subtitle: String(localized: "These sessions have no sport label yet. Pick one for the merged session."),
                              actionVerb: String(localized: "Merge")) { name in
                model.performMerge(target.rows, sport: name)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !model.loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, ZoopSpacing.xxl)
        } else if model.rows.isEmpty {
            emptyState
        } else {
            actionRow
            if let note = model.postLogNote { PostLogNote(text: note) }
            if let week = model.week {
                TrainingWeekCard(week: week, effortScale: effortScale, format: format) { daySheet = $0 }
            }
            TrainingFitnessCard(load: model.load, cardio: model.cardio, effortScale: effortScale)
            if let cardio = model.cardio {
                TrainingLoadGauges(cardio: cardio, muscular: model.lift.muscular, effortScale: effortScale)
            }
            // Muscle load covers every sport, so it shows whenever anything was trained in the last four
            // weeks, including the "all recovered" state after a quiet stretch.
            if model.showsMuscleCard {
                MuscleLoadCard(result: model.lift.muscleLoad, computedAt: model.lift.computedAt)
            }
            TrainingStrengthSection(snapshot: model.lift, unitSystem: unitSystem)
            #if os(iOS)
            RouteHeatEntry()
            #endif
            MindfulnessSection(workouts: model.rows)
            TrainingSessionsSection(model: model, effortScale: effortScale, format: format)
        }
    }

    /// No sessions at all: one explanation and the two ways to get one. The week and load cards stay out
    /// so nothing on the page contradicts the explanation.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            ContentCard {
                Text(TrainingStrings.emptyTitle)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(TrainingStrings.emptyBody)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            MindfulnessSection(workouts: model.rows)
        }
    }

    /// Start a live workout, or add one tracked elsewhere. Equal widths, like the cards below.
    private var actionRow: some View {
        HStack(spacing: ZoopSpacing.m) {
            WorkoutStartControl().frame(maxWidth: .infinity)
            ZoopButton("Add", systemImage: "plus", kind: .secondary, fullWidth: true) {
                model.editor = .init(editing: nil)
            }
            .accessibilityLabel("Add a workout")
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header links

    /// The Training tab header's round buttons: Live heart rate, Lift Log and Intervals. Empty elsewhere, and on macOS,
    /// where both have their own sidebar rows.
    @ViewBuilder private var trainingLinks: some View {
        #if os(iOS)
        if asTrainingTab {
            HStack(spacing: ZoopSpacing.m) {
                headerLink(.live, icon: "waveform.path.ecg", label: LocalizedStringKey("zoop.today.quick.liveHR"))
                headerLink(.liftLog, icon: "dumbbell.fill", label: "Lift Log")
                headerLink(.intervals, icon: "timer", label: "Intervals")
            }
        }
        #endif
    }

    #if os(iOS)
    private func headerLink(_ route: TabRoute, icon: String, label: LocalizedStringKey) -> some View {
        NavigationLink(value: route) {
            Image(systemName: icon)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 42, height: 42)
                .background(Circle().fill(StrandPalette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
    #endif

    private func startPendingRoutine() {
        guard let program = pendingStart else { return }
        pendingStart = nil
        Task { await LiftProgramStarter.start(program, repo: repo, session: liftSession) }
    }
}

/// The transient "sessions like this usually..." line shown after a manual save or relabel.
private struct PostLogNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.s) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.effortColor)
                .accessibilityHidden(true)
            Text(text)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(ZoopSpacing.m)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous).fill(StrandPalette.surfaceRaised))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}
