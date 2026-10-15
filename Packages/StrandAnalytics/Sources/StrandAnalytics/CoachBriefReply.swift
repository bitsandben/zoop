import Foundation

// CoachBriefReply.swift - the contract between the morning coach and a cloud provider.
//
// The provider receives the rule-based candidates (numbered) and may only pick and reword them, so
// every action stays one the app can carry out. Anything malformed falls back to the rules wholesale:
// a half-parsed reply would mix two voices in one card.

public enum CoachBriefReply {

    public struct Pick: Equatable, Sendable {
        /// Index into the candidates the prompt listed.
        public let index: Int
        public let title: String
        public let body: String
    }

    public struct Parsed: Equatable, Sendable {
        public let brief: String
        public let picks: [Pick]
    }

    /// Caps on what a reply can put on screen; a model can return anything.
    static let maxBriefLength = 360
    static let maxTitleLength = 60
    static let maxBodyLength = 160

    /// The system prompt: the JSON schema and the rules of the game, nothing else.
    public static func systemPrompt(language: String) -> String {
        """
        You are a calm, practical morning coach inside a fitness-tracker app. Reply with ONE JSON object \
        and nothing else, no prose and no markdown fences. Schema:
        {"brief": string, "suggestions": [{"id": integer, "title": string, "body": string}]}
        Rules: "brief" is two or three short sentences about today, citing the numbers given. \
        "suggestions" holds one to three items chosen ONLY from the numbered candidates, by their id; \
        never invent a new one. "title" is at most six words, "body" is one sentence. \
        Do not repeat advice the user recently declined. Write in the language with code "\(language)".
        """
    }

    /// Parses a provider reply against `candidateCount` candidates. Nil when there is no usable brief.
    public static func parse(_ reply: String, candidateCount: Int) -> Parsed? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let brief = clip(raw.brief, maxBriefLength)
        guard !brief.isEmpty else { return nil }
        var seen = Set<Int>()
        var picks: [Pick] = []
        for item in raw.suggestions ?? [] {
            guard let id = item.id, (0..<candidateCount).contains(id), !seen.contains(id) else { continue }
            let title = clip(item.title ?? "", maxTitleLength)
            let body = clip(item.body ?? "", maxBodyLength)
            guard !title.isEmpty, !body.isEmpty else { continue }
            seen.insert(id)
            picks.append(Pick(index: id, title: title, body: body))
            if picks.count == CoachMorningRules.maxSuggestions { break }
        }
        return Parsed(brief: brief, picks: picks)
    }

    private struct Raw: Decodable {
        struct Item: Decodable { let id: Int?; let title: String?; let body: String? }
        let brief: String
        let suggestions: [Item]?
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
