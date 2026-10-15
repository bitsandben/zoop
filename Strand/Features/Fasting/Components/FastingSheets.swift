#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Backdate a start, end a fast earlier than "now", or correct an old one. Validation comes from the
/// model (FastingEngine), so the sheet only binds pickers and shows the one reason it can't save.
struct FastingEditSheet: View {
    let model: FastingModel
    @State var draft: FastingDraft
    @Environment(\.dismiss) private var dismiss

    private var isRunning: Binding<Bool> {
        Binding(get: { draft.end == nil },
                set: { draft.end = $0 ? nil : model.now() })
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(selection: $draft.start, in: ...model.now()) { Text(FastingStrings.started) }
                if draft.canRun {
                    Toggle(isOn: isRunning) { Text(FastingStrings.stillRunning) }
                }
                if let end = draft.end {
                    DatePicker(selection: Binding(get: { end }, set: { draft.end = $0 }),
                               in: ...model.now()) { Text(FastingStrings.ended) }
                }
                if let problem = model.problem(with: draft) {
                    Text(problem).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let id = draft.rowID {
                    Button(role: .destructive) {
                        Task { await model.delete(rowID: id); dismiss() }
                    } label: { Text("zoop.fasting.edit.delete") }
                }
            }
            .navigationTitle(Text(draft.rowID == nil ? FastingStrings.startEarlierTitle : FastingStrings.editTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("zoop.fasting.edit.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("zoop.fasting.edit.save") {
                        Task { await model.save(draft); dismiss() }
                    }
                    .disabled(model.problem(with: draft) != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Plan presets, a custom goal, and the opt-in goal reminder.
struct FastingPlanSheet: View {
    let model: FastingModel
    @State private var customHours = 16
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(FastingPlan.presets) { plan in
                        planRow(plan)
                    }
                    planRow(FastingPlan.custom(hours: customHours))
                    if model.plan.isCustom {
                        Stepper(value: $customHours, in: FastingPlan.customHours) {
                            Text(FastingStrings.customHours(customHours))
                        }
                        .onChange(of: customHours) { _, hours in model.choosePlan(.custom(hours: hours)) }
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { model.reminderEnabled },
                                         set: { on in Task { await model.setReminder(on) } })) {
                        Text(FastingStrings.reminderToggle)
                    }
                    if model.reminderDenied {
                        Text(FastingStrings.reminderDenied).font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .navigationTitle(Text(FastingStrings.planTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("zoop.fasting.done") { dismiss() } }
            }
            .onAppear { if model.plan.isCustom { customHours = Int(model.plan.fastingHours) } }
        }
        .presentationDetents([.medium, .large])
    }

    private func planRow(_ plan: FastingPlan) -> some View {
        let selected = plan.isCustom ? model.plan.isCustom : model.plan.id == plan.id
        return Button { model.choosePlan(plan) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.isCustom ? FastingStrings.custom : FastingFormat.planName(plan))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(FastingStrings.split(fasting: Int(plan.fastingHours), eating: Int(plan.eatingHours)))
                        .font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the timer means and what it can't know.
struct FastingAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.l) {
                    ForEach([FastingStrings.footnote, FastingStrings.aboutPhases,
                             FastingStrings.aboutEvidence, FastingStrings.aboutPatterns], id: \.key) { line in
                        Text(line).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ZoopSpacing.gutter)
            }
            .navigationTitle(Text(FastingStrings.aboutTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("zoop.fasting.done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
