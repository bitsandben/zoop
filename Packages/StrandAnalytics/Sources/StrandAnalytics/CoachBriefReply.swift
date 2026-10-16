import Foundation

// CoachBriefReply.swift - the contract between the morning coach and a cloud provider.
//
// The provider receives the morning's drivers (what moved recovery, with numbers) and the rule-based
// candidates (numbered, each with its action kind). It may only explain the listed drivers and pick and
// reword the candidates, returning plain structured JSON: the app draws the card, so a reply carries
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
        /// The one-line takeaway.
        public let headline: String
        /// Short "because" lines naming the drivers, at most `MorningBriefDrivers.maxDrivers`.
        public let reasons: [String]
        public let picks: [Pick]

        /// The stored brief text: the headline, then one reason per line.
        public var brief: String { ([headline] + reasons.map { "• " + $0 }).joined(separator: "\n") }

        /// Everything the reply puts on screen, for the language check.
        public var allText: String {
            ([headline] + reasons + picks.flatMap { [$0.title, $0.body] }).joined(separator: " ")
        }
    }

    /// Caps on what a reply can put on screen; a model can return anything.
    static let maxBriefLength = 360
    static let maxReasonLength = 140
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

    /// The system prompt: persona, the JSON schema, the rules of the game and the language.
    public static func systemPrompt(languageCode: String) -> String {
        """
        You are a concise, data-driven morning coach inside a fitness-tracker app. You explain WHY the \
        user's recovery is what it is today, using only the facts given. Reply with ONE JSON object and \
        nothing else: no prose, no markdown, no code fences. Schema:
        {"headline": string, "reasons": [string], "suggestions": [{"id": integer, "action": string, "title": string, "body": string}]}
        Rules: "headline" is one short sentence with the recovery score and what it means for today. \
        "reasons" holds one to three short sentences, one per listed driver, in the listed order, each \
        citing that driver's number (for example "You moved a lot in your sleep: 14 bouts instead of 6."). \
        Never add a reason that is not listed and never change a number. If no drivers are listed, \
        "reasons" is empty. "suggestions" holds at most two items chosen ONLY from the numbered \
        candidates, by their id; never invent one. "action" repeats the candidate's action kind exactly. \
        "title" is at most six words, "body" is one concrete sentence tied to today's numbers. No generic \
        advice (no "listen to your body", "stay hydrated" unless a candidate says so), no greetings, no \
        medical diagnosis. All strings are plain text: no markdown, asterisks, emoji, bullet characters \
        or line breaks. Do not repeat advice the user recently declined or was given in the last days.
        \(languageDirective(languageCode: languageCode))
        """
    }

    /// Parses a provider reply against the candidates' action kinds (in prompt order). Nil when there
    /// is no usable brief. A pick whose action does not match its candidate is dropped.
    public static func parse(_ reply: String, candidateActions: [String]) -> Parsed? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let headline = clip(plain(raw.headline ?? raw.brief ?? ""), maxBriefLength)
        guard !headline.isEmpty else { return nil }
        let reasons = (raw.reasons ?? []).map { clip(plain($0), maxReasonLength) }.filter { !$0.isEmpty }
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
        return Parsed(headline: headline, reasons: Array(reasons.prefix(MorningBriefDrivers.maxDrivers)), picks: picks)
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
        let headline: String?
        let brief: String?
        let reasons: [String]?
        let suggestions: [Item]?
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
