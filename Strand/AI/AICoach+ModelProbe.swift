import Foundation

// MARK: - Model probe ("Test models")
//
// Sends one tiny brief-shaped prompt to a model with the user's own key and reports how long the reply
// took and whether it came back as the JSON object the morning brief needs. Only the fixed sample
// below leaves the device: no metrics, no transcript. No fallback: the point is to measure THIS model.

struct CoachModelProbe: Equatable, Identifiable {
    let model: String
    let seconds: TimeInterval?
    let validJSON: Bool
    let error: String?
    var id: String { model }
}

extension AICoachEngine {

    static let probeSystemPrompt = """
    Reply with ONE JSON object and nothing else: {"headline": string, "reasons": [string]}. \
    One short sentence each, plain text, citing the numbers given.
    """

    static var probePrompt: String {
        CoachLanguage.code.hasPrefix("de")
            ? "Erholung 41 (normal 55–78). Ruhepuls 6 bpm über normal. 14 Bewegungsphasen statt 6. Antworte auf Deutsch."
            : "Recovery 41 (usual 55–78). Resting HR 6 bpm above normal. 14 movement bouts instead of 6. Reply in English."
    }

    /// One probe of `model`. Never throws: a failure is part of the result.
    func probe(model: String) async -> CoachModelProbe {
        guard CoachBriefScheduler.coachMasterEnabled, isConfigured, let key = resolvedKey else {
            return CoachModelProbe(model: model, seconds: nil, validJSON: false,
                                   error: AICoachError.noKey.errorDescription)
        }
        let client = provider.client
        let started = Date()
        do {
            let text: String
            if let openAI = client as? OpenAIClient {
                text = try await openAI.sendDetailed(key: key, model: model, systemPrompt: Self.probeSystemPrompt,
                                                     messages: [(.user, Self.probePrompt)], session: session,
                                                     jsonMode: true).text
            } else {
                text = try await client.send(key: key, model: model, systemPrompt: Self.probeSystemPrompt,
                                             messages: [(.user, Self.probePrompt)], session: session)
            }
            return CoachModelProbe(model: model, seconds: Date().timeIntervalSince(started),
                                   validJSON: Self.isBriefJSON(text), error: nil)
        } catch {
            let message = (error as? AICoachError)?.errorDescription ?? error.localizedDescription
            return CoachModelProbe(model: model, seconds: nil, validJSON: false, error: message)
        }
    }

    /// The reply is (or contains) one JSON object with a non-empty "headline" string.
    static func isBriefJSON(_ reply: String) -> Bool {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headline = obj["headline"] as? String else { return false }
        return !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The models the test page measures: the recommended set for OpenRouter, the built-in list
    /// otherwise, with the current choice always included.
    var probeCandidates: [String] {
        var list = provider == .openRouter ? AIProvider.openRouterRecommended.map(\.id)
            : Array(provider.modelOptions.prefix(6))
        if !model.isEmpty, !list.contains(model) { list.insert(model, at: 0) }
        return list
    }
}
