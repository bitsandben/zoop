import Foundation

// CoachBriefReply.swift - the contract between the morning coach and a cloud provider.
//
// The provider receives the rule-based candidates (numbered, each with its action kind) and may only
// pick and reword them, returning plain structured JSON: the app draws the card, so a reply carries
// no markdown, no emoji and no styling of its own. Anything malformed falls back to the rules
// wholesale: a half-parsed reply would mix two voices in one card.

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

        /// Everything the reply puts on screen, for the language check.
        public var allText: String {
            ([brief] + picks.flatMap { [$0.title, $0.body] }).joined(separator: " ")
        }
    }

    /// Caps on what a reply can put on screen; a model can return anything.
    static let maxBriefLength = 360
    static let maxTitleLength = 60
    static let maxBodyLength = 160

    /// The explicit language line every coach prompt carries, in the target language itself as well
    /// as in English so the instruction cannot be missed.
    public static func languageDirective(languageCode: String) -> String {
        switch languageCode.lowercased().prefix(2) {
        case "de":
            return "Antworte ausschließlich auf Deutsch, auch wenn die Daten oder Anweisungen englisch sind. "
                + "(Reply only in German.)"
        default:
            return "Reply only in English."
        }
    }

    /// The system prompt: the JSON schema, the rules of the game and the language, nothing else.
    public static func systemPrompt(languageCode: String) -> String {
        """
        You are a calm, practical morning coach inside a fitness-tracker app. Reply with ONE JSON object \
        and nothing else: no prose, no markdown, no code fences. Schema:
        {"brief": string, "suggestions": [{"id": integer, "action": string, "title": string, "body": string}]}
        Rules: "brief" is two or three short sentences about today, citing the numbers given. \
        "suggestions" holds one to three items chosen ONLY from the numbered candidates, by their id; \
        never invent a new one. "action" repeats the candidate's action kind exactly as listed. \
        "title" is at most six words, "body" is one sentence. All strings are plain text: no markdown, \
        no asterisks, no emoji, no bullet characters, no line breaks. The app styles the buttons itself. \
        Do not repeat advice the user recently declined.
        \(languageDirective(languageCode: languageCode))
        """
    }

    /// Parses a provider reply against the candidates' action kinds (in prompt order). Nil when there
    /// is no usable brief. A pick whose action does not match its candidate is dropped.
    public static func parse(_ reply: String, candidateActions: [String]) -> Parsed? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let brief = clip(plain(raw.brief), maxBriefLength)
        guard !brief.isEmpty else { return nil }
        var seen = Set<Int>()
        var picks: [Pick] = []
        for item in raw.suggestions ?? [] {
            guard let id = item.id, candidateActions.indices.contains(id), !seen.contains(id) else { continue }
            if let action = item.action, action != candidateActions[id] { continue }
            let title = clip(plain(item.title ?? ""), maxTitleLength)
            let body = clip(plain(item.body ?? ""), maxBodyLength)
            guard !title.isEmpty, !body.isEmpty else { continue }
            seen.insert(id)
            picks.append(Pick(index: id, title: title, body: body))
            if picks.count == CoachMorningRules.maxSuggestions { break }
        }
        return Parsed(brief: brief, picks: picks)
    }

    /// Strips what a model uses to style text: markdown marks, list bullets, emoji and line breaks.
    public static func plain(_ s: String) -> String {
        let marks: Set<Character> = ["*", "_", "#", "`", "~", ">", "•"]
        var out = String(s.filter { !marks.contains($0) }.unicodeScalars.filter { !isEmoji($0) })
        out = out.replacingOccurrences(of: "\n", with: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix("- ") { out = String(out.dropFirst(2)) }
        return out
    }

    private static func isEmoji(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isEmojiPresentation { return true }
        // Variation selector and joiner left behind by multi-scalar emoji.
        if s.value == 0xFE0F || s.value == 0x200D { return true }
        return s.properties.isEmoji && s.value > 0x2100
    }

    private struct Raw: Decodable {
        struct Item: Decodable { let id: Int?; let action: String?; let title: String?; let body: String? }
        let brief: String
        let suggestions: [Item]?
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
