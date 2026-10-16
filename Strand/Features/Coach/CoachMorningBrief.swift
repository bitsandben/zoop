#if os(iOS)
import Foundation
import StrandAnalytics
import UserNotifications

/// The proactive morning coach: once a day, right after the morning sync has scored the night, it
/// writes a short brief with one to three suggestions and delivers it as the morning push.
///
/// It hangs off the good-morning hook (`AppModel.evaluateGoodMorning`), so it runs when the data is
/// actually there rather than at a fixed clock time. With the Coach on it REPLACES the plain
/// good-morning text, never adds to it: one push per morning. The rules always produce a brief, so it
/// works offline; a configured provider with data consent only rewords it.
@MainActor
enum CoachMorningBrief {

    /// The coach's own switch (Coach settings). Absent = on, like the good-morning notification.
    static let proactiveKey = "zoop.coach.proactive"
    private static let requestId = "coach-morning"
    /// A notification body longer than this is cut; the full brief is on the Today card.
    private static let pushBodyLimit = 220

    static var isProactiveEnabled: Bool {
        UserDefaults.standard.object(forKey: proactiveKey) as? Bool ?? true
    }

    /// Whether the morning goes through the coach rather than the plain good-morning text.
    static var isActive: Bool { CoachBriefScheduler.coachMasterEnabled && isProactiveEnabled }

    /// One generation at a time: the days republish fires in bursts during a sync.
    private static var inFlight = false

    /// What today's brief was written from (`MorningBriefReadiness.Basis`, JSON).
    private static let basisKey = "zoop.coach.morningBriefBasis"

    static var lastBasis: MorningBriefReadiness.Basis? {
        UserDefaults.standard.data(forKey: basisKey)
            .flatMap { try? JSONDecoder().decode(MorningBriefReadiness.Basis.self, from: $0) }
    }

    /// Called on every days republish once `MorningBriefReadiness` says the night is over and offloaded.
    /// Writes today's brief, and REWRITES it when the night it quoted changed afterwards (a later offload
    /// brought more of it), so the Today card always carries the final numbers. Posts at most once a day,
    /// in the morning, only when the good-morning notification is on. `written` reports each write.
    static func onDayUpdate(today: String, recovery: Double?, sleepMin: Double?, nightEndTs: Int?, illness: Bool,
                            repo: Repository, coach: AICoachEngine, now: Date = Date(),
                            written: @escaping (_ basis: MorningBriefReadiness.Basis, _ rewrite: Bool) -> Void = { _, _ in }) {
        guard isActive, recovery != nil, !inFlight else { return }
        let previous = lastBasis
        guard MorningBriefReadiness.needsWrite(previous: previous, day: today, sleepMin: sleepMin,
                                               nightEndTs: nightEndTs) else { return }
        let rewrite = previous?.day == today
        // A rewrite is for a night that was still arriving; past the morning a moved end is a nap, not the night.
        if rewrite, Calendar.current.component(.hour, from: now) >= GoodMorningNotifier.latestHour { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            let result = await generate(repo: repo, coach: coach, illness: illness, now: now, day: today)
            let basis = MorningBriefReadiness.Basis(day: today, sleepMin: sleepMin, nightEndTs: nightEndTs,
                                                    recovery: recovery, writtenAt: Int(now.timeIntervalSince1970))
            if let data = try? JSONEncoder().encode(basis) { UserDefaults.standard.set(data, forKey: basisKey) }
            written(basis, rewrite)
            let hour = Calendar.current.component(.hour, from: now)
            guard GoodMorningNotifier.isEnabled, hour < GoodMorningNotifier.latestHour,
                  !GoodMorningNotifier.hasPosted(today: today),
                  CoachBriefScheduler.claimMorningPush(day: today) else { return }
            GoodMorningNotifier.markPosted(today: today)
            post(body: result.text)
        }
    }

    /// Builds and stores today's brief. Also the "generate now" path for previews and the DEBUG hook.
    @discardableResult
    static func generate(repo: Repository, coach: AICoachEngine, illness: Bool = false, now: Date = Date(),
                         day: String = Repository.localDayKey(Date())) async -> CoachDailyBrief {
        let input = await CoachMorningInputs.gather(repo: repo, illness: illness, now: now)
        let plan = CoachMorningRules.evaluate(input)
        var output = CoachMorningComposer.compose(input: input, plan: plan, now: now,
                                                  whoopScale: CoachMorningInputs.whoopScale)
        var byAI = false
        if let reply = await providerReply(coach: coach, output: output, declined: input.suppressedReasons) {
            output = CoachMorningComposer.applying(reply, to: output)
            byAI = true
        }
        let brief = CoachDailyBrief(day: day, createdAt: now, text: output.brief, byAI: byAI)
        CoachSuggestionStore.shared.record(brief: brief, suggestions: output.suggestions)
        return brief
    }

    /// Asks the configured provider to pick and reword the candidates. Only with the Coach's data
    /// consent: the prompt carries the same metrics summary the chat sends. Nil means "use the rules":
    /// also when the reply is not plain JSON or not written in the app language.
    private static func providerReply(coach: AICoachEngine, output: CoachMorningComposer.Output,
                                      declined: Set<String>) async -> CoachBriefReply.Parsed? {
        guard coach.canSendOneShot, coach.dataConsent, !output.suggestions.isEmpty else { return nil }
        let context = await coach.buildFullContext()
        let language = CoachLanguage.code
        let prompt = CoachMorningComposer.providerPrompt(context: context, output: output, declined: declined,
                                                         languageCode: language)
        guard let reply = try? await coach.oneShot(systemPrompt: CoachBriefReply.systemPrompt(languageCode: language),
                                                   prompt: prompt),
              let parsed = CoachBriefReply.parse(reply, candidateActions: output.suggestions.map(\.action.kindName)),
              CoachLanguageCheck.matches(parsed.allText, languageCode: language) else { return nil }
        return parsed
    }

    /// Respects the notification permission: nothing is asked here, the good-morning switch owns that.
    private static func post(body: String) {
        let title = CoachStrings.pushTitle
        let text = body.count > pushBodyLimit ? String(body.prefix(pushBodyLimit)) + "…" : body
        let id = requestId
        NotificationWork.withSettings { center, settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
#endif
