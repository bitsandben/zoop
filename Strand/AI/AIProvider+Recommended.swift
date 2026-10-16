import Foundation

// MARK: - Recommended OpenRouter models
//
// The free models the picker offers first, each labelled by what it trades: fast, balanced or thorough.
// Chosen for short coaching text in German and English plus strict JSON for the morning brief.
//
// Default: Gemma 4 26B A4B. A mixture-of-experts model with about 3.8B active parameters, served for
// free by Google AI Studio (stable uptime, `response_format` supported). Artificial Analysis measures
// ~66 tokens/s for it with an Intelligence Index close to the dense Gemma 4 31B, and it answers
// directly unless asked to reason. The previous default, Dots 3 Note (16B active), is a reasoning model:
// it thinks before every reply, which is why it felt slow. Nemotron 3.5 Lightning (3B active) is faster
// still where it is served well, but its free endpoint has been the least available of the set, so it
// is offered, not defaulted. The in-app "Test models" page measures all of them with the user's key.

extension AIProvider {

    struct RecommendedModel: Identifiable, Equatable {
        enum Tier: String { case fast, balanced, thorough }
        let id: String
        let tier: Tier
    }

    static let openRouterRecommended: [RecommendedModel] = [
        .init(id: openRouterDefaultModel, tier: .fast),
        .init(id: "nvidia/nemotron-3.5-lightning:free", tier: .fast),
        .init(id: "google/gemma-4-31b-it:free", tier: .balanced),
        .init(id: "nvidia/nemotron-3-super-120b-a12b:free", tier: .balanced),
        .init(id: openRouterLegacyDefaultModel, tier: .thorough),
        .init(id: "thinkingmachines/inkling:free", tier: .thorough),
    ]

    /// The tier of a recommended model, nil for anything else.
    static func recommendedTier(_ model: String) -> RecommendedModel.Tier? {
        openRouterRecommended.first { $0.id == model }?.tier
    }

    static func tierLabel(_ tier: RecommendedModel.Tier) -> String {
        switch tier {
        case .fast: return String(localized: LocalizedStringResource("zoop.coach.model.tier.fast", defaultValue: "Fast"))
        case .balanced:
            return String(localized: LocalizedStringResource("zoop.coach.model.tier.balanced", defaultValue: "Balanced"))
        case .thorough:
            return String(localized: LocalizedStringResource("zoop.coach.model.tier.thorough", defaultValue: "Thorough"))
        }
    }

    /// "google/gemma-4-26b-a4b-it:free · Fast" for a recommended model, the bare id otherwise.
    static func pickerLabel(_ model: String) -> String {
        guard let tier = recommendedTier(model) else { return model }
        return "\(model) · \(tierLabel(tier))"
    }
}
