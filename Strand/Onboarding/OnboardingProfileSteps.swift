import SwiftUI
import StrandDesign

// MARK: - Onboarding · About you, one question per step
//
// Name, birthday, sex, height and weight are asked one at a time, each with a single large answer and
// one control, rather than as one form. Every answer writes straight to `ProfileStore`, so going back
// shows what was entered and skipping keeps the defaults.

/// The frame every question uses: an icon in a squircle well, the question, a short reason, the answer.
struct OnboardingQuestion<Content: View>: View {
    let icon: String
    let question: String
    let reason: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 56, height: 56)
                        .background(SquircleShape().fill(StrandPalette.surfaceRaised))
                    Text(question)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reason)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

/// The one big answer shown above a picker, e.g. "31 yrs" or "178 cm".
private struct BigAnswer: View {
    let value: String
    var unit: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 64, weight: .bold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            if let unit {
                Text(unit)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Metric / imperial for body measurements, shared by the height and weight steps.
private struct BodyUnitToggle: View {
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    var body: some View {
        Picker("Units", selection: $unitSystemRaw) {
            Text("Metric").tag(UnitSystem.metric.rawValue)
            Text("Imperial").tag(UnitSystem.imperial.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: Name

struct OnboardingNameStep: View {
    @EnvironmentObject private var profile: ProfileStore
    let advance: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingQuestion(icon: "person.fill",
                           question: String(localized: "What should we call you?"),
                           reason: String(localized: "Only used inside the app. You can skip this.")) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("", text: $profile.name, prompt: Text("Your name").foregroundStyle(StrandPalette.textTertiary))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .focused($focused)
                    .submitLabel(.next)
                    .onSubmit(advance)
                    #if os(iOS)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
                Rectangle()
                    .fill(focused ? StrandPalette.accent : StrandPalette.hairline)
                    .frame(height: 2)
                    .animation(.easeOut(duration: 0.2), value: focused)
            }
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)   // after the slide-in settles
                focused = true
            }
        }
    }
}

// MARK: Birthday

struct OnboardingBirthdayStep: View {
    @EnvironmentObject private var profile: ProfileStore

    private var question: String {
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty
            ? String(localized: "When were you born?")
            : String(localized: "Nice to meet you, \(name). When were you born?")
    }

    var body: some View {
        OnboardingQuestion(icon: "birthday.cake.fill",
                           question: question,
                           reason: String(localized: "Your age sets your maximum heart rate, your zones and your Fitness Age.")) {
            VStack(spacing: 8) {
                BigAnswer(value: "\(profile.age)", unit: String(localized: "years"))
                DatePicker("Date of birth", selection: $profile.dateOfBirth,
                           in: ProfileStore.dateOfBirthRange, displayedComponents: .date)
                    #if os(iOS)
                    .datePickerStyle(.wheel)
                    #endif
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Sex

struct OnboardingSexStep: View {
    @EnvironmentObject private var profile: ProfileStore

    private let options: [(key: String, label: String, icon: String)] = [
        ("female", String(localized: "Female"), "figure.stand.dress"),
        ("male", String(localized: "Male"), "figure.stand"),
        ("nonbinary", String(localized: "Other"), "figure.2"),
    ]

    var body: some View {
        OnboardingQuestion(icon: "person.2.fill",
                           question: String(localized: "What's your sex?"),
                           reason: String(localized: "Heart-rate norms, calories and Fitness Age differ by sex. Female also turns on cycle tracking.")) {
            VStack(spacing: 10) {
                ForEach(options, id: \.key) { option in
                    let selected = profile.sex == option.key
                    Button {
                        withAnimation(.snappy) { profile.sex = option.key }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(selected ? StrandPalette.accent : StrandPalette.surfaceBase))
                            Text(option.label)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textTertiary)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(StrandPalette.surfaceRaised)
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(selected ? StrandPalette.accent : .clear, lineWidth: 1.5))
                        )
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: selected)
                }
            }
        }
    }
}

// MARK: Height

struct OnboardingHeightStep: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var system: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private var heightBinding: Binding<Int> {
        Binding(get: { Int(profile.heightCm.rounded()) }, set: { profile.heightCm = Double($0) })
    }

    var body: some View {
        OnboardingQuestion(icon: "ruler.fill",
                           question: String(localized: "How tall are you?"),
                           reason: String(localized: "Used with your weight for calories and your body measurements.")) {
            VStack(spacing: 14) {
                BodyUnitToggle()
                BigAnswer(value: UnitFormatter.heightFromCentimeters(profile.heightCm, system: system))
                Picker("Height", selection: heightBinding) {
                    ForEach(120...230, id: \.self) { cm in
                        Text(UnitFormatter.heightFromCentimeters(Double(cm), system: system)).tag(cm)
                    }
                }
                #if os(iOS)
                .pickerStyle(.wheel)
                #endif
                .labelsHidden()
            }
        }
    }
}

// MARK: Weight

struct OnboardingWeightStep: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var system: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// Half-kilogram steps, held as an index so the wheel has whole tags.
    private var weightBinding: Binding<Int> {
        Binding(get: { Int((profile.weightKg * 2).rounded()) }, set: { profile.weightKg = Double($0) / 2 })
    }

    var body: some View {
        OnboardingQuestion(icon: "scalemass.fill",
                           question: String(localized: "And your weight?"),
                           reason: String(localized: "Calories burned depend on it. Stays on this phone.")) {
            VStack(spacing: 14) {
                BodyUnitToggle()
                BigAnswer(value: UnitFormatter.massFromKilograms(profile.weightKg, system: system))
                Picker("Weight", selection: weightBinding) {
                    ForEach(60...500, id: \.self) { half in
                        Text(UnitFormatter.massFromKilograms(Double(half) / 2, system: system)).tag(half)
                    }
                }
                #if os(iOS)
                .pickerStyle(.wheel)
                #endif
                .labelsHidden()
                HStack(spacing: 8) {
                    Image(systemName: "bolt.heart")
                        .foregroundStyle(StrandPalette.accent)
                    Text("Estimated max heart rate · \(profile.hrMax) bpm")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
