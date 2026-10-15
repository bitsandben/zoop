import Foundation

// SseDeltas: pure SSE delta parsing for AI provider streaming. Given one SSE `data:` payload, extract the
// text delta for the provider's wire shape; no network or I/O.

/// Pure SSE delta extraction for the three provider wire shapes the coach speaks.
public enum SseDeltas {

    /// The SSE stream terminator sent by OpenAI-compatible servers.
    public static let doneMarker = "[DONE]"

    // MARK: - SSE line splitting

    /// Strips the `data: ` prefix from one SSE line; nil for blank lines, comments (`: ...`) and non-data fields.
    public static func dataPayload(fromLine line: String) -> String? {
        // Strip a trailing \r (CRLF streams). Blank line = event separator; ":" prefix = comment.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix(":") { return nil }
        // Strip "data:" then one optional leading space (not part of the value per the SSE spec).
        if trimmed.hasPrefix("data:") {
            var payload = String(trimmed.dropFirst("data:".count))
            if payload.hasPrefix(" ") { payload = String(payload.dropFirst()) }
            return payload
        }
        // Other SSE fields (event:, id:, retry:) are not data — skip.
        return nil
    }

    /// True when a data payload is the `[DONE]` terminator.
    public static func isDone(_ payload: String) -> Bool {
        payload.trimmingCharacters(in: .whitespacesAndNewlines) == doneMarker
    }

    // MARK: - Per-provider delta extraction

    /// Text delta from an OpenAI-compatible payload (`choices[0].delta.content`). Nil for `[DONE]`, no choices,
    /// or a non-content delta such as the first chunk's `role`.
    public static func openAiDelta(_ payload: String) -> String? {
        if isDone(payload) { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        // Empty content (OpenAI's usual first delta) is nil so `onDelta` does not fire for it.
        return content.isEmpty ? nil : content
    }

    /// Text delta from a Gemini payload (`candidates[0].content.parts[].text`, joined). Nil when no text parts.
    public static func geminiDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// Text delta from an Anthropic payload; only `content_block_delta` / `text_delta` events carry text.
    public static func anthropicDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "content_block_delta",
              let delta = obj["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String,
              deltaType == "text_delta",
              let text = delta["text"] as? String else { return nil }
        // Empty text is nil, as for `openAiDelta`.
        return text.isEmpty ? nil : text
    }

    // MARK: - Full-stream reassembly (test helper)

    /// Reassembles the full reply text from a complete SSE stream; used by tests to compare against the non-streamed reply.
    public static func reassemble(lines: [String], provider: SseProvider) -> String {
        var out = ""
        for line in lines {
            guard let payload = dataPayload(fromLine: line) else { continue }
            let delta: String?
            switch provider {
            case .openAi, .custom:  delta = openAiDelta(payload)
            case .gemini:           delta = geminiDelta(payload)
            case .anthropic:        delta = anthropicDelta(payload)
            }
            if let d = delta { out += d }
        }
        return out
    }
}

/// The provider wire shape to use for delta extraction. `.custom` shares the OpenAI shape.
public enum SseProvider {
    case openAi, custom, gemini, anthropic
}
