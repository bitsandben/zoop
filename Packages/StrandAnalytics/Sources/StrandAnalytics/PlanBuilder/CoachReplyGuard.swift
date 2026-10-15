import Foundation

/// Keeps a conversational coach turn short whatever the model sends: reasoning blocks split off,
/// markdown headings and list markers dropped, at most `maxSentences` sentences and `maxChars`
/// characters. When something has to go, the closing question survives, since it is what the user
/// answers next.
public enum CoachReplyGuard {

    public static let defaultMaxSentences = 2
    public static let defaultMaxChars = 220

    /// Splits `<think>…</think>` (or `<thinking>…</thinking>`) reasoning off a reply.
    public static func splitThinking(_ raw: String) -> (text: String, thinking: String?) {
        var text = raw
        var thoughts: [String] = []
        for (open, close) in [("<think>", "</think>"), ("<thinking>", "</thinking>")] {
            while let start = text.range(of: open) {
                if let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                    thoughts.append(String(text[start.upperBound..<end.lowerBound]))
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    // An unclosed block: everything after it is reasoning.
                    thoughts.append(String(text[start.upperBound...]))
                    text.removeSubrange(start.lowerBound..<text.endIndex)
                }
            }
        }
        let thinking = thoughts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), thinking.isEmpty ? nil : thinking)
    }

    /// The reply flattened to plain prose and cut to the limits.
    public static func shorten(_ raw: String, maxSentences: Int = defaultMaxSentences,
                               maxChars: Int = defaultMaxChars) -> String {
        let flat = flatten(splitThinking(raw).text)
        var sentences = split(flat)
        guard !sentences.isEmpty else { return "" }
        if sentences.count > maxSentences {
            // Keep the opening acknowledgement and the last question.
            let question = sentences.last { $0.hasSuffix("?") } ?? sentences[sentences.count - 1]
            sentences = Array(sentences.prefix(max(0, maxSentences - 1))) + [question]
        }
        var text = sentences.joined(separator: " ")
        while text.count > maxChars, sentences.count > 1 {
            sentences.removeFirst()
            text = sentences.joined(separator: " ")
        }
        if text.count > maxChars { text = truncate(text, to: maxChars) }
        return text
    }

    /// Markdown structure out, whitespace collapsed.
    static func flatten(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            for marker in ["- ", "* ", "• "] where l.hasPrefix(marker) { l.removeFirst(marker.count) }
            return l.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Sentences ending in . ! ? or … followed by a space (or the end).
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let terminal = c == "." || c == "!" || c == "?" || c == "…"
            let atBoundary = i + 1 == chars.count || chars[i + 1] == " "
            if terminal && atBoundary {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { result.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit - 1))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }
}
