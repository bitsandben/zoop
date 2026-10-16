import Foundation
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - Sending

extension AICoachEngine {
    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        // The master switch, checked at the EGRESS rather than only on the routes in. Every way into Coach
        // is gated, but "gated everywhere I thought of" is what #2254 got wrong once: a revoked consent
        // survived in memory because the conversation never re-read it. A wearer can be STANDING on this
        // screen when the switch goes off, and that path passes no tab. Refusing here makes "the AI is off"
        // true however the screen was reached.
        guard CoachBriefScheduler.coachMasterEnabled else { return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        // A transcript from an earlier local day is retired before the new turn is appended (#1542,
        // Kotlin twin merged first). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        retireStaleConversationIfNeeded()
        conversationDay = Self.localEpochDay()

        errorText = nil
        appendMessage(ChatMessage(role: .user, text: trimmed))
        sending = true
        // K2: persist once the turn is fully settled (success, mid-stream error, or empty-stream
        // removal) — not per streamed chunk, so a long reply doesn't hammer the store.
        defer { sending = false; persistMessages() }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        // K13: if the conversation overflows the sliding window, summarize the dropped middle so
        // the model retains context continuity. Best-effort; failure degrades to the old gap.
        await summarizeDroppedMiddleIfNeeded(key: key)
        var wire = wireMessages(context: context)

        // K11: If a chart image is pending and the provider is Gemini, attach it to the last
        // user turn as inline_data. Non-Gemini providers can't accept images, so the image is
        // silently dropped (the text question still goes through). Cleared after consumption.
        let imageBase64 = pendingChartImage
        pendingChartImage = nil

        // K1: Stream the reply. Append a placeholder assistant message, then mutate its text as
        // chunks arrive by replacing the last element in `messages`. The transcript re-renders on
        // each update (SwiftUI binds to `messages`). On error mid-stream, keep the partial text and
        // append a "(stream interrupted)" marker — never a crash.
        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire, inlineImage: imageBase64) { delta in
                accumulated += delta
                // Replace the last message's text with the accumulated stream so far.
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: accumulated
                    )
                }
            }
            // Finalize: trim whitespace. If the stream produced nothing, show "(no reply)".
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: clean.isEmpty ? "(no reply)" : clean
                )
            }
        } catch let e as AICoachError {
            // Mid-stream error: keep the partial text + an interrupted marker (PRD K1 acceptance).
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(" + Self.streamInterrupted + ")*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                // No text received at all — remove the empty placeholder.
                messages.remove(at: lastIdx)
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(" + Self.streamInterrupted + ")*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages.remove(at: lastIdx)
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// K1: streams the brief the same way `send` does.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]

        let prefix = Self.briefHeading + "\n\n"
        let placeholder = ChatMessage(role: .assistant, text: prefix)
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire) { delta in
                accumulated += delta
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: prefix + accumulated
                    )
                }
            }
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant, text: prefix + clean)
            }
        } catch let e as AICoachError {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(" + Self.streamInterrupted + ")*"
                )
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(" + Self.streamInterrupted + ")*"
                )
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// Heading of a brief in the chat, and the marker on a cut-off reply, in the app language.
    static var briefHeading: String {
        String(localized: LocalizedStringResource("zoop.coach.chat.briefHeading", defaultValue: "Today's brief"))
    }
    static var streamInterrupted: String {
        String(localized: LocalizedStringResource("zoop.coach.chat.interrupted", defaultValue: "stream interrupted"))
    }

    /// K5: The brief instruction shared by the interactive `startBriefIfNeeded()` (streamed into the
    /// chat) and the headless `generateBrief()` below (used by the scheduled morning-brief notification).
    /// Kept in one place so the two paths never drift.
    private static let briefInstruction = """
    Based on the data above, give me TODAY'S coaching brief as three short lines, one sentence each: \
    (1) my readiness, citing charge, HRV and rest; \
    (2) exactly what training to do today; \
    (3) one specific thing to improve my charge. No headings.
    """

    /// K5: Generate today's coaching brief WITHOUT touching the visible chat transcript. Used by the
    /// scheduled morning-brief notification (`CoachBriefScheduler`), which can run with no Coach screen
    /// open and must never append to (or duplicate into) `messages`. Non-streaming (a background/BGTask
    /// context has no UI to stream into). Returns nil when not configured/consented, on any network
    /// failure, or when the reply is empty — the caller treats nil as "brief unavailable"; never throws.
    func generateBrief() async -> String? {
        // Same master-switch gate as `send`, because this entry has NO UI at all: it is what the scheduler
        // calls, and a caller that skipped the scheduler's own gate would otherwise reach a provider with
        // the AI switched off.
        guard CoachBriefScheduler.coachMasterEnabled else { return nil }
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await buildFullContext()
        let request = context + "\n\n---\n\n" + Self.briefInstruction + "\n" + CoachLanguage.directive
        // The scheduled brief is shown as is, so a reply in the wrong language gets one retry with the
        // language line stressed, then counts as a failed generation (the caller retries later).
        for attempt in 0..<2 {
            let text = attempt == 0 ? request : request + "\n\nIMPORTANT: " + CoachLanguage.directive
            let messages: [(role: ChatMessage.Role, content: String)] = [(.user, text)]
            guard let reply = try? await callProvider(key: key, messages: messages) else { return nil }
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { return nil }
            if CoachLanguage.matches(clean) { return clean }
        }
        return nil
    }

    /// Dispatch to the user's chosen provider client.
    func callProvider(key: String,
                      messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        let client = provider.client
        let prompt = CoachLanguage.withDirective(systemPrompt)
        return try await withModelFallback { model in
            try await client.send(key: key, model: model, systemPrompt: prompt,
                                  messages: messages, session: self.session)
        }
    }

    /// K1: Dispatch to the user's chosen provider client's streaming method. The default
    /// `AIProviderClient.stream` falls back to `send` + a single delta, so providers without
    /// streaming still work. K11: when an inline image is present, dispatches to
    /// `streamWithImage` instead (Gemini overrides it; others ignore the image).
    private func streamProvider(key: String,
                                messages: [(role: ChatMessage.Role, content: String)],
                                inlineImage: String? = nil,
                                onDelta: (String) -> Void) async throws {
        let client = provider.client
        let prompt = CoachLanguage.withDirective(systemPrompt)
        try await withModelFallback { model in
            try await client.streamWithImage(key: key, model: model, systemPrompt: prompt,
                                             messages: messages, inlineImage: inlineImage,
                                             session: self.session, onDelta: onDelta)
        }
    }
}

// MARK: - One-shot structured requests

extension AICoachEngine {
    /// True when a one-shot request can be sent: the Coach is switched on and a provider is set up.
    var canSendOneShot: Bool { CoachBriefScheduler.coachMasterEnabled && isConfigured }

    /// Send a single prompt with its own system prompt through the user's configured provider and
    /// model, returning the raw reply. Touches neither the chat transcript nor the metrics context:
    /// only `systemPrompt` and `prompt` leave the device. Used by the Lift Log routine generator and the
    /// morning brief. `json` asks OpenAI-compatible providers for a JSON object (structured outputs).
    func oneShot(systemPrompt: String, prompt: String, json: Bool = false) async throws -> String {
        guard CoachBriefScheduler.coachMasterEnabled, isConfigured, let key = resolvedKey else {
            throw AICoachError.noKey
        }
        let client = provider.client
        return try await withModelFallback { model in
            if json, let openAI = client as? OpenAIClient {
                return try await openAI.sendDetailed(key: key, model: model, systemPrompt: systemPrompt,
                                                     messages: [(.user, prompt)], session: self.session,
                                                     jsonMode: true).text
            }
            return try await client.send(key: key, model: model, systemPrompt: systemPrompt,
                                         messages: [(.user, prompt)], session: self.session)
        }
    }
}
