#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// The schedule editor: plan, fixed or flexible start, what happens when the eating window closes,
/// the three reminders, and whether Today shows the card.
struct FastingScheduleSheet: View {
    let model: FastingModel
    @State private var customHours = 16
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                planSection
                timingSection
                Section {
                    Toggle(isOn: Binding(get: { model.autoStart }, set: { model.setAutoStart($0) })) {
                        Text(FastingStrings.autoStartToggle)
                    }
                } footer: {
                    Text(FastingStrings.autoStartNote)
                }
                remindersSection
                Section {
                    Toggle(isOn: Binding(get: { model.showOnToday }, set: { model.setShowOnToday($0) })) {
                        Text(FastingStrings.showOnToday)
                    }
                }
            }
            .navigationTitle(Text(FastingStrings.scheduleTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("zoop.fasting.done") { dismiss() } }
            }
            .onAppear { if model.plan.isCustom { customHours = Int(model.plan.fastingHours) } }
        }
        .presentationDetents([.large])
    }

    private var planSection: some View {
        Section {
            ForEach(FastingPlan.presets) { planRow($0) }
            planRow(FastingPlan.custom(hours: customHours))
            if model.plan.isCustom {
                Stepper(value: $customHours, in: FastingPlan.customHours) {
                    Text(FastingStrings.customHours(customHours))
                }
                .onChange(of: customHours) { _, hours in model.choosePlan(.custom(hours: hours)) }
            }
        } header: {
            Text(FastingStrings.planTitle)
        }
    }

    private var timingSection: some View {
        Section {
            Picker(selection: Binding(get: { model.schedule.mode != .flexible }, set: { model.setFixedStart($0) })) {
                Text(FastingStrings.modeFlexible).tag(false)
                Text(FastingStrings.modeFixed).tag(true)
            } label: {
                Text(FastingStrings.modeLabel)
            }
            .pickerStyle(.segmented)
            if model.schedule.mode != .flexible {
                DatePicker(selection: startTime, displayedComponents: .hourAndMinute) {
                    Text(FastingStrings.fixedStartLabel)
                }
            }
        } footer: {
            Text(model.schedule.mode == .flexible ? FastingStrings.flexibleNote : FastingStrings.fixedNote)
        }
    }

    private var remindersSection: some View {
        Section {
            reminderToggle(.goal, FastingStrings.reminderToggle)
            reminderToggle(.closing, FastingStrings.closingReminderToggle)
            reminderToggle(.start, FastingStrings.startReminderToggle)
            if model.deniedReminder != nil {
                Text(FastingStrings.reminderDenied).font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        } header: {
            Text(FastingStrings.remindersTitle)
        }
    }

    /// The fixed start as a Date today, for the hour-and-minute picker.
    private var startTime: Binding<Date> {
        Binding(
            get: {
                let day = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(byAdding: .minute, value: model.startMinute, to: day) ?? day
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.setStartMinute((c.hour ?? 0) * 60 + (c.minute ?? 0))
            })
    }

    private func reminderToggle(_ reminder: FastingPreferences.Reminder,
                                _ label: LocalizedStringResource) -> some View {
        Toggle(isOn: Binding(get: { model.isOn(reminder) },
                             set: { on in Task { await model.setReminder(reminder, on) } })) {
            Text(label)
        }
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
#endif
