import SwiftUI
import StrandDesign

// MARK: - Step 7: Goals

/// What the user trains for. Captured here for the Training screen (Zoop 2.0 WP-12), which does not
/// read it yet. It must never change a score: it may only order guidance.
enum TrainingFocus: String, CaseIterable, Identifiable {
    case recovery, endurance, strength, weight
    var id: String { rawValue }
    static let storageKey = "zoop.profile.trainingFocus"

    var icon: String {
        switch self {
        case .recovery:  return "leaf"
        case .endurance: return "figure.run"
        case .strength:  return "dumbbell"
        case .weight:    return "scalemass"
        }
    }

    var title: String {
        switch self {
        case .recovery:  return String(localized: "zoop.onboarding.goals.focus.recovery")
        case .endurance: return String(localized: "zoop.onboarding.goals.focus.endurance")
        case .strength:  return String(localized: "zoop.onboarding.goals.focus.strength")
        case .weight:    return String(localized: "zoop.onboarding.goals.focus.weight")
        }
    }
}

struct OnboardingGoalsStep: View {
    @AppStorage(TrainingFocus.storageKey) private var focusRaw = TrainingFocus.recovery.rawValue
    #if os(iOS)
    // The sleep planner's goal: bedtime, the Home card and the wind-down reminder already follow it,
    // so onboarding writes that one key rather than a second "sleep goal" that could disagree.
    @AppStorage(SleepGoal.storageKey) private var sleepGoalRaw = SleepGoal.peak.rawValue
    #endif

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.goals.title"),
                       subtitle: String(localized: "zoop.onboarding.goals.subtitle")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                #if os(iOS)
                section("zoop.onboarding.goals.sleep") {
                    ForEach(Array(SleepGoal.allCases.enumerated()), id: \.element) { i, goal in
                        OnboardingChoiceRow(icon: sleepIcon(goal), title: goal.title,
                                            detail: sleepDetail(goal),
                                            selected: sleepGoalRaw == goal.rawValue) {
                            sleepGoalRaw = goal.rawValue
                        }
                        .listCardRow(isFirst: i == 0)
                    }
                }
                #endif
                section("zoop.onboarding.goals.focus") {
                    ForEach(Array(TrainingFocus.allCases.enumerated()), id: \.element) { i, focus in
                        OnboardingChoiceRow(icon: focus.icon, title: focus.title,
                                            selected: focusRaw == focus.rawValue) {
                            focusRaw = focus.rawValue
                        }
                        .listCardRow(isFirst: i == 0)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            ListCard { rows() }
        }
    }

    #if os(iOS)
    private func sleepIcon(_ goal: SleepGoal) -> String {
        switch goal {
        case .peak:    return "moon.stars"
        case .perform: return "moon"
        case .getBy:   return "moon.zzz"
        }
    }

    /// The share of tonight's sleep need each goal plans for, as the planner computes it.
    private func sleepDetail(_ goal: SleepGoal) -> String {
        String(localized: "zoop.onboarding.goals.sleep.share \(goal.fraction.formatted(.percent.precision(.fractionLength(0))))")
    }
    #endif
}
