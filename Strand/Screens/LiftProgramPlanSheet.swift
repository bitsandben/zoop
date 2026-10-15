import SwiftUI
import StrandDesign
import WhoopStore

/// Pick the weekdays a Lift Log program is planned on. The schedule feeds the dashed circles on the
/// training calendar; it is stored in `TrainingPlan` and never touches the workout history.
struct LiftProgramPlanSheet: View {
    let program: LiftProgramRow

    @Environment(\.dismiss) private var dismiss
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""
    @State private var days: Set<Int> = []
    @State private var items: [LiftProgramItemRow] = []
    @State private var lines: [LiftProgressionAdvisor.Line] = []
    @EnvironmentObject private var repo: Repository

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                Text(program.name)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Planned days show as dashed circles in your training calendar.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(Self.orderedWeekdays, id: \.self) { day in
                        dayToggle(day)
                    }
                }
                .padding(.top, 4)
                nextTimeList
                Spacer(minLength: 0)
            }
            .padding(ZoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 420, height: 260)
        #endif
        .onAppear { days = TrainingPlan.decode(planRaw).days(for: program.id) }
        .task { await loadProgression() }
    }

    // MARK: Next time

    /// Per exercise: what progression suggests for the next session, and any line today's muscle
    /// recovery will skip or lighten. Only lines with something to say are listed.
    @ViewBuilder private var nextTimeList: some View {
        let rows = items.compactMap { item -> (String, String)? in
            guard let line = lines.first(where: { $0.itemId == item.id }) else { return nil }
            if line.recovery != .keep, let group = line.group, let pct = line.percentRecovered {
                let key = line.recovery == .skip ? "zoop.lift.recovery.skip" : "zoop.lift.recovery.reduce"
                return (item.exercise, PlanFormat.t(key, group.displayName, "\(pct)"))
            }
            return line.advice.map { (item.exercise, PlanFormat.nextTime($0)) }
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                ForEach(rows, id: \.0) { exercise, text in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(text)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .padding(.top, ZoopSpacing.m)
        }
    }

    private func loadProgression() async {
        guard let store = await repo.storeHandle() else { return }
        items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        lines = await LiftProgressionAdvisor.lines(for: items, repo: repo)
    }

    /// Weekday numbers (1 = Sunday) in the locale's week order, so a German week starts on Monday.
    static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func dayToggle(_ day: Int) -> some View {
        let on = days.contains(day)
        let symbol = Calendar.current.veryShortStandaloneWeekdaySymbols[day - 1]
        let name = Calendar.current.standaloneWeekdaySymbols[day - 1]
        return Button {
            if on { days.remove(day) } else { days.insert(day) }
        } label: {
            Text(symbol)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Circle().fill(on ? StrandPalette.effortColor : StrandPalette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func save() {
        var plan = TrainingPlan.decode(planRaw)
        plan.set(days, for: program.id)
        planRaw = plan.encoded()
        dismiss()
    }
}
