import SwiftUI
import StrandAnalytics
import StrandDesign

/// The native questions that used to be an AI interview: one scrolling page of cards, then a single
/// button that sends everything to the provider at once.
struct PlanForm: View {
    let kind: PlanInterview.Kind
    let history: WorkoutHistorySummary
    let ready: Bool
    let onSubmit: ([PlanInterview.Slot: String], String) -> Void

    @State private var plan = PlanFormState()
    @State private var routine = RoutineFormState()
    @State private var levelTouched = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                PlanFormHeader()
                if kind == .plan { planCards } else { routineCards }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.vertical, ZoopSpacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { submitBar }
        .onAppear(perform: applySuggestedLevel)
        .onChange(of: history) { _, _ in applySuggestedLevel() }
    }

    // MARK: Plan

    @ViewBuilder private var planCards: some View {
        ContentCard("zoop.planform.goal") {
            FormChipGroup(options: options(PlanFormState.goalKeys), selection: $plan.goals)
            FormTextField(placeholder: PlanFormat.t("zoop.planform.goal.custom"), text: $plan.goalText)
        }
        ContentCard("zoop.planform.horizon") {
            FormChipGroup(options: [.init(id: "open", label: chip("open")),
                                    .init(id: "target", label: PlanFormat.t("zoop.planform.horizon.target"))],
                          selection: Binding(get: { [plan.openEnded ? "open" : "target"] },
                                             set: { plan.openEnded = $0.contains("open") }),
                          single: true)
            if !plan.openEnded {
                DatePicker(PlanFormat.t("zoop.planform.horizon.target"), selection: $plan.targetDate,
                           in: (Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())...,
                           displayedComponents: .date)
                    .font(ZoopType.body)
                    .tint(StrandPalette.accent)
            }
        }
        ContentCard("zoop.planform.days") {
            FormWeekdays(selected: $plan.weekdays)
            Text(PlanFormat.t("zoop.planform.days.count", "\(plan.weekdays.count)"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        ContentCard("zoop.planform.length") {
            FormChipGroup(options: options(PlanFormState.minuteKeys), selection: single($plan.minutes), single: true)
        }
        ContentCard("zoop.planform.where") {
            FormChipGroup(options: PlanFormState.placeKeys.map { .init(id: $0, label: PlanFormat.t("zoop.planform.place.\($0)")) },
                          selection: $plan.places)
            Text(PlanFormat.t("zoop.planform.equipment"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            FormChipGroup(options: options(PlanFormState.equipmentKeys), selection: $plan.equipment)
        }
        ContentCard("zoop.planform.time") {
            FormChipGroup(options: options(PlanFormState.timeKeys), selection: single($plan.timeOfDay), single: true)
        }
        ContentCard("zoop.planform.level") {
            FormChipGroup(options: options(PlanFormState.levelKeys), selection: single($plan.level), single: true,
                          onToggle: { _ in levelTouched = true })
            historyHint
        }
        ContentCard("zoop.planform.limits") {
            FormTextField(placeholder: PlanFormat.t("zoop.planform.limits.placeholder"), text: $plan.limitations)
        }
    }

    // MARK: Routine

    @ViewBuilder private var routineCards: some View {
        ContentCard("zoop.planform.focus") {
            FormChipGroup(options: options(RoutineFormState.focusKeys), selection: $routine.focus)
        }
        ContentCard("zoop.planform.equipment") {
            FormChipGroup(options: options(RoutineFormState.equipmentKeys), selection: $routine.equipment,
                          onToggle: { tapped in
                              if tapped == "noGear" { routine.equipment = routine.equipment.contains("noGear") ? ["noGear"] : [] }
                              else { routine.equipment.remove("noGear") }
                          })
        }
        ContentCard("zoop.planform.duration") {
            FormChipGroup(options: options(RoutineFormState.minuteKeys), selection: single($routine.minutes), single: true)
        }
        ContentCard("zoop.planform.level") {
            FormChipGroup(options: options(PlanFormState.levelKeys), selection: single($routine.level), single: true,
                          onToggle: { _ in levelTouched = true })
            historyHint
        }
    }

    // MARK: Parts

    @ViewBuilder private var historyHint: some View {
        if !history.isEmpty {
            Text(PlanFormat.t("zoop.planform.level.hint", "\(history.totalSessions)", "\(history.strengthSessions)"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var valid: Bool { kind == .plan ? plan.isValid : routine.isValid }

    private var submitBar: some View {
        VStack(spacing: ZoopSpacing.s) {
            if !ready {
                Text(PlanFormat.t("zoop.planchat.setup"))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZoopButton(kind == .plan ? "zoop.planform.create.plan" : "zoop.planform.create.routine",
                       systemImage: "sparkles", kind: .primary, fullWidth: true) {
                if kind == .plan { onSubmit(plan.answers(), plan.summary()) }
                else { onSubmit(routine.answers(), routine.summary()) }
            }
            .disabled(!valid || !ready)
        }
        .padding(.horizontal, ZoopSpacing.m)
        .padding(.vertical, ZoopSpacing.s)
        .background(StrandPalette.surfaceBase)
    }

    private func applySuggestedLevel() {
        guard !levelTouched else { return }
        plan.level = history.suggestedLevel.rawValue
        routine.level = history.suggestedLevel.rawValue
    }

    private func chip(_ key: String) -> String { PlanFormat.t("zoop.planchat.chip.\(key)") }

    private func options(_ keys: [String]) -> [FormChipGroup.Option] {
        keys.map { .init(id: $0, label: chip($0)) }
    }

    /// A one-value string as the set a single-select chip group edits.
    private func single(_ value: Binding<String>) -> Binding<Set<String>> {
        Binding(get: { [value.wrappedValue] }, set: { if let first = $0.first { value.wrappedValue = first } })
    }
}

/// The privacy line at the top of the form.
private struct PlanFormHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.s) {
            PlanCoachAvatar(size: 32)
            Text(PlanFormat.t("zoop.planchat.privacy"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
