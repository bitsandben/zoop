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
    private static let lastDayKey = "zoop.coach.morningBriefDay"
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

    /// Called on every days republish once the sync gates passed. Generates at most once per day, after
    /// the night ended and Recovery is scored; posts only in the morning and only when the
    /// good-morning notification is on.
    static func onDayUpdate(today: String, recovery: Double?, nightEndTs: Int?,
                            repo: Repository, coach: AICoachEngine, now: Date = Date()) {
        guard isActive, recovery != nil, !inFlight,
              UserDefaults.standard.string(forKey: lastDayKey) != today,
              nightEnded(nightEndTs, now: now) else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            let result = await generate(repo: repo, coach: coach, now: now, day: today)
            UserDefaults.standard.set(today, forKey: lastDayKey)
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
    static func generate(repo: Repository, coach: AICoachEngine, now: Date = Date(),
                         day: String = Repository.localDayKey(Date())) async -> CoachDailyBrief {
        let input = await CoachMorningInputs.gather(repo: repo, now: now)
        let plan = CoachMorningRules.evaluate(input)
        var output = CoachMorningComposer.compose(input: input, plan: plan, now: now)
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
    /// consent: the prompt carries the same metrics summary the chat sends. Nil means "use the rules".
    private static func providerReply(coach: AICoachEngine, output: CoachMorningComposer.Output,
                                      declined: Set<String>) async -> CoachBriefReply.Parsed? {
        guard coach.canSendOneShot, coach.dataConsent, !output.suggestions.isEmpty else { return nil }
        let context = await coach.buildFullContext()
        let prompt = CoachMorningComposer.providerPrompt(context: context, output: output, declined: declined)
        let language = AppLanguage.activeLocale.language.languageCode?.identifier ?? "en"
        guard let reply = try? await coach.oneShot(systemPrompt: CoachBriefReply.systemPrompt(language: language),
                                                   prompt: prompt) else { return nil }
        return CoachBriefReply.parse(reply, candidateCount: output.suggestions.count)
    }

    private static func nightEnded(_ endTs: Int?, now: Date) -> Bool {
        guard let endTs else { return false }
        let end = Date(timeIntervalSince1970: TimeInterval(endTs))
        return Calendar.current.isDate(end, inSameDayAs: now) && end <= now
    }

    /// Respects the notification permission: nothing is asked here, the good-morning switch owns that.
    private static func post(body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = CoachStrings.pushTitle
            content.body = body.count > pushBodyLimit ? String(body.prefix(pushBodyLimit)) + "…" : body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: nil))
        }
    }
}
#endif
