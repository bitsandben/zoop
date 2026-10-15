import Foundation
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - System prompt & suggestions

extension AICoachEngine {
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    sleep duration and its deep/REM/light breakdown, sleep efficiency, HRV, resting heart rate) and \
    recent workouts. Charge is the daily recovery/readiness score, effort is the daily cardiovascular \
    load score, and rest is the nightly sleep-quality score. A dash in the data means that value was \
    NOT MEASURED that day — say so rather than treating it as a zero. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Cite the user's ACTUAL numbers and give one concrete next step - specific and warm, like a \
    coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Keep every reply SHORT: at most 3 short sentences, unless the user explicitly asks for detail or \
    a plan. No headings, no preamble, no summary of the question. **Bold** a key number at most. \
    A small table only for a training plan. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Contextual suggestion chips for the composer, derived from today's bands via `CoachSuggestions`.
    /// Reads only on-device `repo.days`; pure, byte-identical to the Android twin. Returns the stable
    /// generic fallback when there is no usable data for today.
    /// The chips are English catalogue keys, shown (and sent) in the app language.
    var suggestions: [String] {
        CoachSuggestions.suggestions(for: repo.days.last, recent: repo.days).map(CoachLanguage.localizedPrompt)
    }

    /// K7: Follow-up suggestion chips shown after each assistant reply. These are generic
    /// conversational follow-ups (not data-derived) so the user can dig deeper without typing.
    /// The English keys are byte-identical to the Android twin's `followUpSuggestions`; shown in the
    /// app language through the String Catalog.
    static var followUpSuggestions: [String] { followUpKeys.map(CoachLanguage.localizedPrompt) }
    static let followUpKeys: [String] = [
        "Tell me more about that",
        "What should I do next?",
        "How does today compare to this week?",
        "Give me a specific action plan",
    ]

    /// K12: Rough token estimate for the next send, based on the current draft + context size.
    /// Uses the standard ~4 chars/token heuristic. This is an estimate only — actual token counts
    /// vary by tokenizer. Returns nil when the engine isn't configured (no context to estimate).
    func estimatedTokens(forDraft draft: String) -> Int? {
        guard isConfigured else { return nil }
        // Estimate the context size: system prompt + data context (rough — we don't build the
        // full context here to avoid a DB read on every keystroke). Use the last known context
        // size or a reasonable default.
        let systemPromptTokens = systemPrompt.count / 4
        // The data context is typically ~2000-4000 chars depending on the user's data.
        // Use a conservative estimate of 3000 chars (750 tokens) when consent is on.
        let contextTokens = dataConsent ? 750 : 50
        // History tokens: sum of all message texts in the windowed history.
        let historyTokens = windowedMessages().reduce(0) { $0 + $1.text.count / 4 }
        let draftTokens = draft.count / 4
        return systemPromptTokens + contextTokens + historyTokens + draftTokens
    }
}
