import Foundation
import StrandAnalytics

// MARK: - Model fallback & conversational turns

extension AICoachEngine {

    /// UserDefaults key of the OpenRouter fallback model id (editable in Coach settings).
    static let fallbackModelKey = "zoop.ai.fallbackModel"

    /// The model a request retries on when the chosen OpenRouter model is unavailable. Blank turns
    /// the fallback off.
    var fallbackModel: String {
        get {
            UserDefaults.standard.string(forKey: Self.fallbackModelKey) ?? AIProvider.openRouterDefaultFallback
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                      forKey: Self.fallbackModelKey)
            objectWillChange.send()
        }
    }

    /// Whether `error` says the MODEL is gone (retired preview, renamed id), as opposed to a key, rate
    /// or network problem. Only these are worth retrying on another model.
    static func isModelUnavailable(_ error: Error) -> Bool {
        guard let e = error as? AICoachError else { return false }
        let detail: String
        switch e {
        case .server(let status, let message):
            if status == 404 { return true }
            guard status == 400 || status == 410 else { return false }
            detail = message
        case .emptyReply(let message):
            detail = message
        default:
            return false
        }
        let d = detail.lowercased()
        return ["not a valid model", "model not found", "no endpoints found", "deprecated",
                "is not available", "no longer available", "does not exist"].contains { d.contains($0) }
    }

    /// Runs `operation` on the chosen model; when OpenRouter reports that model unavailable, runs it
    /// once more on `fallbackModel` and remembers the failure for the settings note. The retry happens
    /// only before any text arrived (an unavailable model fails at the request), so no reply is doubled.
    func withModelFallback<T>(_ operation: (String) async throws -> T) async throws -> T {
        let chosen = model
        do {
            let result = try await operation(chosen)
            if modelFallbackNote == chosen { modelFallbackNote = nil }
            return result
        } catch {
            let fallback = fallbackModel
            guard provider == .openRouter, !fallback.isEmpty, fallback != chosen,
                  Self.isModelUnavailable(error) else { throw error }
            let result = try await operation(fallback)
            modelFallbackNote = chosen
            return result
        }
    }

    /// One conversational turn with its own system prompt, outside the Coach transcript: only
    /// `systemPrompt` and `messages` leave the device. Used by the plan and routine builder.
    ///
    /// Returns the visible text with any reasoning split off, plus how long the model took.
    func converse(systemPrompt: String,
                  messages: [(role: ChatMessage.Role, content: String)]) async throws -> CoachTurnReply {
        guard CoachBriefScheduler.coachMasterEnabled, isConfigured, let key = resolvedKey else {
            throw AICoachError.noKey
        }
        let started = Date()
        let prompt = CoachLanguage.withDirective(systemPrompt)
        let client = provider.client
        let session = self.session
        let raw: (text: String, reasoning: String?) = try await withModelFallback { model in
            if let openAI = client as? OpenAIClient {
                return try await openAI.sendDetailed(key: key, model: model, systemPrompt: prompt,
                                                     messages: messages, session: session)
            }
            return (try await client.send(key: key, model: model, systemPrompt: prompt,
                                          messages: messages, session: session), nil)
        }
        let split = CoachReplyGuard.splitThinking(raw.text)
        return CoachTurnReply(text: split.text,
                              reasoning: [raw.reasoning, split.thinking].compactMap { $0 }.first,
                              seconds: Date().timeIntervalSince(started))
    }
}

/// A conversational reply: the text to show, the model's reasoning when it sent any, and the time taken.
struct CoachTurnReply: Equatable {
    var text: String
    var reasoning: String?
    var seconds: TimeInterval
}
