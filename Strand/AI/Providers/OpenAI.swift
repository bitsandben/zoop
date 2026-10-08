import Foundation
import StrandAnalytics

struct OpenAIClient: AIProviderClient {
    /// OpenAI itself, or OpenRouter, which speaks the same chat and models API.
    var provider: AIProvider = .openAI

    /// OpenRouter asks callers to name the app; neither header carries any user data.
    private func applyHeaders(_ req: inout URLRequest, key: String) {
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if provider == .openRouter {
            req.setValue("Zoop", forHTTPHeaderField: "X-Title")
        }
    }

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Standard params first (gpt-4 family). Newer/reasoning models reject `temperature` and want
        // `max_completion_tokens`; if the provider 400s about either, retry with the modern shape.
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: false, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 {
            let d = detail.lowercased()
            if d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") {
                return try await chat(key: key, model: model, wire: wire, modernParams: true, session: session)
            }
            throw AICoachError.server(code, detail)
        }
    }

    /// K1: Stream via `stream: true`. Same body as `send`, with `stream: true` added. SSE parsing
    /// via `SseDeltas.openAiDelta`. The modern-params retry on 400 is NOT streamed (rare path;
    /// falls back to `send`'s retry). Byte-parity pin in `SseDeltasTests.openAiReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        var body: [String: Any] = ["model": model, "messages": wire, "stream": true]
        body["temperature"] = 0.6
        body["max_tokens"] = 4096

        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        applyHeaders(&req, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: provider.modelsEndpoint)
        req.httpMethod = "GET"
        applyHeaders(&req, key: key)

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into chat-capable ids (gpt*/o*). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        if provider == .openRouter {
            // Only the free models, sorted, so the picker lists what costs nothing to use.
            return list.compactMap { $0["id"] as? String }.filter { $0.hasSuffix(":free") }.sorted()
        }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return (id.hasPrefix("gpt") || id.hasPrefix("o")) ? id : nil
        }
    }

    // MARK: Private

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — required by reasoning models.
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
        // reply complete (a cap, not a target — the system prompt keeps it short). Matches Gemini + Android.
        if modernParams {
            body["max_completion_tokens"] = 4096
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        applyHeaders(&req, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return content
    }
}
