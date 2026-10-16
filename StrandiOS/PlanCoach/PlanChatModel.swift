import Foundation
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

/// The plan / routine builder. A native form collects the answers (`PlanInterview` slots), one provider
/// call writes the plan or routine as JSON, which is validated before it is shown; "Anpassen" then
/// continues as a short chat. Nothing is saved until the user accepts the draft.
@MainActor
final class PlanChatModel: ObservableObject {

    struct Thought: Equatable {
        let seconds: Int
        let reasoning: String?
    }

    enum Status: Equatable { case draft, active }

    enum Body: Equatable {
        case text(String)
        case plan(TrainingPlanDraft, Status)
        case routine(ImportedProgram, Status)
    }

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case assistant, user }
        let id = UUID()
        let role: Role
        var body: Body
        var thought: Thought?
    }

    enum Phase: Equatable { case interview, drafting, review, refining, saved }

    /// One provider round trip: system prompt + turns in, reply out.
    typealias Transport = (_ system: String, _ messages: [(role: ChatMessage.Role, content: String)]) async throws -> CoachTurnReply

    let kind: PlanInterview.Kind
    @Published private(set) var messages: [Message] = []
    @Published private(set) var phase: Phase = .interview
    @Published private(set) var busy = false
    @Published var errorText: String?
    @Published private(set) var interview: PlanInterview.State

    @Published private(set) var history: WorkoutHistorySummary
    var transport: Transport
    private var lastRequest: (() async -> Void)?

    init(kind: PlanInterview.Kind, history: WorkoutHistorySummary, transport: @escaping Transport) {
        self.kind = kind
        self.history = history
        self.transport = transport
        self.interview = PlanInterview.State(kind: kind)
    }

    func updateHistory(_ summary: WorkoutHistorySummary) { history = summary }

    var latestPlan: TrainingPlanDraft? {
        for m in messages.reversed() { if case .plan(let d, _) = m.body { return d } }
        return nil
    }

    var latestRoutine: ImportedProgram? {
        for m in messages.reversed() { if case .routine(let p, _) = m.body { return p } }
        return nil
    }

    /// The id of the object card that Übernehmen / Anpassen act on.
    var actionableCardId: UUID? {
        guard phase == .review else { return nil }
        return messages.last { if case .text = $0.body { return false }; return true }?.id
    }

    // MARK: Turns

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        errorText = nil
        switch phase {
        case .refining, .review:
            messages.append(Message(role: .user, body: .text(text)))
            await requestEdit(text)
        case .interview, .drafting, .saved:
            return
        }
    }

    /// The form was sent: all answers at once, then the one request that writes the plan or routine.
    func submitForm(_ answers: [PlanInterview.Slot: String], summary: String) async {
        guard phase == .interview, !busy else { return }
        errorText = nil
        interview.fill(answers)
        messages.append(Message(role: .user, body: .text(summary)))
        await requestDraft()
    }

    /// "Anpassen": the next message edits the draft.
    func beginAdjusting() {
        guard phase == .review else { return }
        phase = .refining
        messages.append(Message(role: .assistant, body: .text(PlanFormat.t("zoop.planchat.adjust.prompt"))))
    }

    func retry() async {
        guard let lastRequest, !busy else { return }
        errorText = nil
        await lastRequest()
    }

    private func requestDraft() async {
        phase = .drafting
        lastRequest = { [weak self] in await self?.requestDraft() }
        let system = kind == .plan ? PlanChatPrompts.planSystem : LiftRoutineGenerator.systemPrompt
        let prompt = kind == .plan
            ? PlanChatPrompts.planRequest(state: interview, history: history, today: Date())
            : PlanChatPrompts.routineRequest(state: interview)
        await runDraft(system: system, prompt: prompt, fallbackPhase: .drafting)
    }

    private func requestEdit(_ change: String) async {
        phase = .drafting
        lastRequest = { [weak self] in await self?.requestEdit(change) }
        if kind == .plan, let plan = latestPlan {
            await runDraft(system: PlanChatPrompts.planSystem,
                           prompt: PlanChatPrompts.planEdit(plan, change: change, today: Date()), fallbackPhase: .review)
        } else if let routine = latestRoutine {
            await runDraft(system: LiftRoutineGenerator.systemPrompt,
                           prompt: PlanChatPrompts.routineEdit(routine, change: change), fallbackPhase: .review)
        }
    }

    /// Asks for the JSON object, with one retry on a reply that does not validate.
    private func runDraft(system: String, prompt: String, fallbackPhase: Phase) async {
        busy = true
        defer { busy = false }
        var turns: [(role: ChatMessage.Role, content: String)] = [(.user, prompt)]
        var seconds = 0.0
        for attempt in 0..<2 {
            let reply: CoachTurnReply
            do {
                reply = try await transport(system, turns)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = fallbackPhase
                return
            }
            seconds += reply.seconds
            let thought = Thought(seconds: Int(seconds.rounded()), reasoning: reply.reasoning)
            if accept(reply.text, thought: thought) {
                lastRequest = nil
                return
            }
            if attempt == 0 { turns += [(.assistant, reply.text), (.user, PlanChatPrompts.jsonRetry)] }
        }
        errorText = PlanFormat.t("zoop.planchat.error.parse")
        phase = fallbackPhase
    }

    /// Validates a reply and appends the object card; false when it does not parse.
    private func accept(_ reply: String, thought: Thought) -> Bool {
        switch kind {
        case .plan:
            guard let draft = try? TrainingPlanDraftParser.parse(
                reply, today: TrainingPlan.dayKey(Date()),
                resolveSport: { KnownWorkoutTypeLookup.canonical($0) }) else { return false }
            messages.append(Message(role: .assistant, body: .plan(draft, .draft), thought: thought))
            let closing = draft.summary.map { CoachReplyGuard.shorten($0, maxSentences: 1, maxChars: 160) }
            messages.append(Message(role: .assistant,
                                    body: .text(closing ?? PlanFormat.t("zoop.planchat.plan.closing"))))
        case .routine:
            guard let program = try? LiftRoutineGenerator.parse(reply) else { return false }
            messages.append(Message(role: .assistant, body: .routine(program, .draft), thought: thought))
            messages.append(Message(role: .assistant, body: .text(PlanFormat.t("zoop.planchat.routine.closing"))))
        }
        phase = .review
        return true
    }

    /// Marks the accepted card active and ends the conversation.
    func markSaved() {
        if let id = actionableCardId, let index = messages.firstIndex(where: { $0.id == id }) {
            switch messages[index].body {
            case .plan(let d, _): messages[index].body = .plan(d, .active)
            case .routine(let p, _): messages[index].body = .routine(p, .active)
            case .text: break
            }
        }
        phase = .saved
        messages.append(Message(role: .assistant, body: .text(PlanFormat.t(
            kind == .plan ? "zoop.planchat.plan.saved" : "zoop.planchat.routine.saved"))))
    }

    private static func thought(_ reply: CoachTurnReply) -> Thought {
        Thought(seconds: Int(reply.seconds.rounded()), reasoning: reply.reasoning)
    }
}

/// Sport text → catalogue name, case-insensitively.
enum KnownWorkoutTypeLookup {
    static func canonical(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let k = KnownWorkoutType.resolving(t) { return k.rawValue }
        return KnownWorkoutType.allCases.first { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }?.rawValue
    }
}
