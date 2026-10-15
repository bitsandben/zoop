import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Manual workout sheet
//
// Add a workout tracked elsewhere, or edit a logged one, as a settings-style form: the sport (icon, name,
// searchable picker), when (date, start, duration with the end it implies), the optional numbers, and a
// preview of the Effort the session will carry. State and rules live in `ManualWorkoutForm`; the row is
// validated by `WorkoutSource.buildManualRow` and persisted by the caller (`Repository.saveManualWorkout`).
// Captured fields on an edited row (max HR, Effort, zones) are carried over, so editing a live-tracked
// session's sport or time never wipes its real Effort.

struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a new manual workout.
    let editing: WorkoutRow?
    /// Called with the validated row (and the original, when editing) once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: ManualWorkoutForm
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    private enum NumberField: Hashable { case distance, calories, avgHr }
    @FocusState private var focusedField: NumberField?

    init(editing: WorkoutRow? = nil, onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // @AppStorage is not readable before init, so read the distance unit straight from the defaults.
        let body = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let system = UnitPrefs.resolveDistance(
            system: body, override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        _form = State(initialValue: ManualWorkoutForm(editing: editing, distanceSystem: system))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                    sportCard
                    timeGroup
                    detailsGroup
                    ManualEffortPreview(preview: preview, scale: UnitPrefs.resolveEffortScale(effortScaleRaw))
                    if let note = form.validationNote() { noteRow(note, color: StrandPalette.statusWarning) }
                    if form.avgHrEditedNote {
                        noteRow(String(localized: "Avg HR is shown as typed. The HR graph, zones and Effort stay from the recorded session."),
                                color: StrandPalette.textSecondary)
                    }
                }
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.top, ZoopSpacing.s)
                .padding(.bottom, ZoopSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(editing == nil ? ManualWorkoutStrings.addTitle : ManualWorkoutStrings.editTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(form.builtRow == nil)
                        .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
                }
            }
            .keyboardDoneToolbar($focusedField)
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 460, height: 640)
        #endif
    }

    // MARK: Sport

    private var sportCard: some View {
        ListCard {
            NavigationLink { ManualSportPicker(sport: $form.sport) } label: {
                HStack(spacing: ZoopSpacing.m) {
                    WorkoutTypeIcon(workoutType: form.sport.isEmpty ? "Other" : form.sport, size: 26,
                                    weight: .semibold, color: StrandPalette.effortColor)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                            .fill(StrandPalette.surfaceInset))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ManualWorkoutStrings.sport).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                        Text(form.sport.isEmpty ? ManualWorkoutStrings.chooseSport : WorkoutSource.displaySport(form.sport))
                            .font(ZoopType.headline)
                            .foregroundStyle(form.sport.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    }
                    Spacer(minLength: ZoopSpacing.s)
                    Image(systemName: "chevron.right").font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .listCardRow(isFirst: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Time

    private var timeGroup: some View {
        ZoopSettingsGroup(LocalizedStringKey(ManualWorkoutStrings.whenTitle)) {
            ZoopSettingsRow(LocalizedStringKey(ManualWorkoutStrings.date), systemImage: "calendar", isFirst: true) {
                DatePicker("", selection: startBinding, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel(Text(ManualWorkoutStrings.date))
            }
            ZoopSettingsRow("Start", systemImage: "clock") {
                DatePicker("", selection: startBinding, in: ...Date(), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel("Start date and time")
            }
            ZoopSettingsRow("Duration", systemImage: "timer",
                            note: LocalizedStringKey(ManualWorkoutStrings.endsAt(form.endText))) {
                Stepper(value: $form.durationMinutes, in: 1...(24 * 60), step: 5) {
                    Text(verbatim: form.durationText).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                }
                .fixedSize()
                .accessibilityLabel("Duration in minutes")
            }
        }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { form.start }, set: { form.moveStart(to: $0) })
    }

    // MARK: Optional numbers

    private var detailsGroup: some View {
        ZoopSettingsGroup(LocalizedStringKey(ManualWorkoutStrings.optionalTitle),
                          footer: LocalizedStringKey(ManualWorkoutStrings.optionalFooter)) {
            numberRow("Distance", icon: "point.topleft.down.to.point.bottomright.curvepath", text: $form.distanceText,
                      unit: UnitFormatter.distanceUnit(form.distanceSystem), field: .distance, isFirst: true)
            numberRow("Calories", icon: "flame", text: $form.kcalText, unit: "kcal", field: .calories)
            numberRow("Avg HR", icon: "heart", text: $form.avgHrText, unit: "bpm", field: .avgHr)
        }
    }

    private func numberRow(_ label: LocalizedStringKey, icon: String, text: Binding<String>, unit: String,
                           field: NumberField, isFirst: Bool = false) -> some View {
        ZoopSettingsRow(label, systemImage: icon, isFirst: isFirst) {
            HStack(spacing: ZoopSpacing.xs) {
                TextField("", text: text, prompt: Text("optional"))
                    .multilineTextAlignment(.trailing)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .numericKeyboard()
                    .focused($focusedField, equals: field)
                    .frame(maxWidth: 110)
                    .accessibilityLabel(Text(label))
                Text(verbatim: unit).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func noteRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(ZoopType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ZoopSpacing.xs)
    }

    // MARK: Effort

    @EnvironmentObject private var profile: ProfileStore

    private var preview: ManualWorkoutForm.EffortPreview {
        form.effortPreview(hrMax: profile.hrMax, sex: profile.sex, method: PuffinExperiment.effortMethod)
    }

    private func save() {
        guard let row = form.builtRow else { return }
        // A confirmed save is a real selection: fold the sport into the recents (#297).
        RecentSportsPrefs.recordSelection(row.sport)
        onSave(row, editing)
        dismiss()
    }
}

/// The Effort the session will carry: an estimate from the typed average heart rate, the Effort captured
/// live, or a note that the strap's heart rate will score it after saving.
private struct ManualEffortPreview: View {
    let preview: ManualWorkoutForm.EffortPreview
    let scale: EffortScale

    var body: some View {
        ContentCard(LocalizedStringKey(ManualWorkoutStrings.effortTitle)) {
            switch preview {
            case .estimated(let stored), .captured(let stored):
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                    Text(verbatim: TrainingEffort.text(stored, scale: scale))
                        .font(ZoopType.metric)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(TrainingEffort.band(forStored: stored).text)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(preview == .captured(stored) ? ManualWorkoutStrings.effortCaptured : ManualWorkoutStrings.effortEstimated)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .fromStrap:
                Text(ManualWorkoutStrings.effortFromStrap)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Add") {
    ManualWorkoutSheet { _, _ in }
        .environmentObject(ProfileStore())
        .preferredColorScheme(.dark)
}
#endif
