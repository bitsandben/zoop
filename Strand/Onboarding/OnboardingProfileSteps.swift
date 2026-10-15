import SwiftUI
import StrandDesign

// MARK: - Step 6: About you
//
// One screen instead of five questions: every answer is a row, and the three numeric ones open a
// wheel in place (like Calendar's date rows), one at a time. Answers write straight to
// `ProfileStore`, so skipping keeps the defaults and going back shows what was entered.

struct OnboardingProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @State private var open: Field?
    @FocusState private var nameFocused: Bool

    private enum Field { case birth, height, weight }
    private var system: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.profile.title"),
                       subtitle: String(localized: "zoop.onboarding.profile.subtitle")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                ListCard {
                    nameRow.listCardRow(isFirst: true)
                    expandable(.birth, label: "zoop.onboarding.profile.birth",
                               value: String(localized: "zoop.onboarding.profile.age \(profile.age)")) {
                        DatePicker("zoop.onboarding.profile.birth", selection: $profile.dateOfBirth,
                                   in: ProfileStore.dateOfBirthRange, displayedComponents: .date)
                            #if os(iOS)
                            .datePickerStyle(.wheel)
                            #endif
                            .labelsHidden()
                    }
                    sexRow
                    expandable(.height, label: "zoop.onboarding.profile.height",
                               value: UnitFormatter.heightFromCentimeters(profile.heightCm, system: system)) {
                        Picker("zoop.onboarding.profile.height", selection: heightBinding) {
                            ForEach(120...230, id: \.self) { cm in
                                Text(UnitFormatter.heightFromCentimeters(Double(cm), system: system)).tag(cm)
                            }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #endif
                        .labelsHidden()
                    }
                    expandable(.weight, label: "zoop.onboarding.profile.weight",
                               value: UnitFormatter.massFromKilograms(profile.weightKg, system: system)) {
                        Picker("zoop.onboarding.profile.weight", selection: weightBinding) {
                            ForEach(60...500, id: \.self) { half in
                                Text(UnitFormatter.massFromKilograms(Double(half) / 2, system: system)).tag(half)
                            }
                        }
                        #if os(iOS)
                        .pickerStyle(.wheel)
                        #endif
                        .labelsHidden()
                    }
                }

                ListCard {
                    HStack {
                        Text("zoop.onboarding.profile.units")
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: ZoopSpacing.m)
                        Picker("zoop.onboarding.profile.units", selection: $unitSystemRaw) {
                            Text("Metric").tag(UnitSystem.metric.rawValue)
                            Text("Imperial").tag(UnitSystem.imperial.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .listCardRow(isFirst: true)
                }

                Text("zoop.onboarding.profile.hrMax \(profile.hrMax)")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .onAppear(perform: seedUnitsFromLocale)
    }

    // MARK: Rows

    private var nameRow: some View {
        HStack {
            Text("zoop.onboarding.profile.name")
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.m)
            TextField("", text: $profile.name,
                      prompt: Text("zoop.onboarding.profile.namePrompt").foregroundStyle(StrandPalette.textTertiary))
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
                .focused($nameFocused)
                .submitLabel(.done)
                #if os(iOS)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
        }
    }

    private var sexRow: some View {
        HStack {
            Text("zoop.onboarding.profile.sex")
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.m)
            // Keys match ProfileStore.sex; "female" also enables cycle awareness later (opt-in).
            Picker("zoop.onboarding.profile.sex", selection: $profile.sex) {
                Text("Female").tag("female")
                Text("Male").tag("male")
                Text("Other").tag("nonbinary")
            }
            .pickerStyle(.menu)
            .tint(StrandPalette.textPrimary)
            .labelsHidden()
            .fixedSize()
        }
        .listCardRow()
    }

    /// A label/value row that reveals its picker underneath when tapped; opening one closes the others.
    private func expandable<P: View>(_ field: Field, label: LocalizedStringKey, value: String,
                                          @ViewBuilder picker: () -> P) -> some View {
        VStack(spacing: ZoopSpacing.s) {
            Button {
                nameFocused = false
                withAnimation(StrandMotion.gentle) { open = open == field ? nil : field }
            } label: {
                HStack {
                    Text(label)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: ZoopSpacing.m)
                    Text(value)
                        .font(ZoopType.body.monospacedDigit())
                        .foregroundStyle(open == field ? StrandPalette.accent : StrandPalette.textPrimary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open == field {
                picker().frame(maxWidth: .infinity)
            }
        }
        .listCardRow()
    }

    // MARK: Bindings

    private var heightBinding: Binding<Int> {
        Binding(get: { Int(profile.heightCm.rounded()) }, set: { profile.heightCm = Double($0) })
    }

    /// Half-kilogram steps held as an index so the wheel has whole tags.
    private var weightBinding: Binding<Int> {
        Binding(get: { Int((profile.weightKg * 2).rounded()) }, set: { profile.weightKg = Double($0) / 2 })
    }

    /// A first-time user gets the units their region uses; anyone who already chose keeps the choice.
    private func seedUnitsFromLocale() {
        guard UserDefaults.standard.object(forKey: UnitPrefs.systemKey) == nil else { return }
        let imperial = Locale.current.measurementSystem == .us
        unitSystemRaw = (imperial ? UnitSystem.imperial : .metric).rawValue
    }
}
