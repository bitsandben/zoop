#if os(iOS)
import Foundation
import StrandAnalytics

/// Turns a rule plan into the stored objects: the brief text and the suggestions with their copy,
/// "because" line and expiry, all in the app language. A cloud reply, when there is one, only
/// replaces the wording.
enum CoachMorningComposer {

    struct Output {
        let brief: String
        let suggestions: [CoachSuggestion]
    }

    /// The rule-based brief: readiness, the night, and the first suggestion as today's focus.
    static func compose(input: CoachMorningRules.Input, plan: CoachMorningRules.Plan, now: Date,
                        whoopScale: Bool) -> Output {
        let suggestions = plan.candidates.map { suggestion(for: $0, now: now, whoopScale: whoopScale) }
        var sentences: [String] = []
        if let pct = input.recovery.map(score), let line = CoachStrings.readiness(plan.readiness, pct: pct) {
            sentences.append(line)
        }
        if let slept = input.sleepMin, slept > 0 {
            let duration = ZoopDuration.text(minutes: slept)
            sentences.append(input.sleepDebtMin >= SleepDebt.onTargetBandMin
                ? CoachStrings.sleptWithDebt(duration, debt: ZoopDuration.text(minutes: input.sleepDebtMin))
                : CoachStrings.slept(duration))
        }
        if let first = suggestions.first { sentences.append(CoachStrings.focus(first.title)) }
        return Output(brief: sentences.joined(separator: " "), suggestions: suggestions)
    }

    /// Applies a parsed cloud reply: its brief, and its picks in its order with its wording. Candidates
    /// the reply left out are dropped, since the provider judged them less relevant today.
    static func applying(_ reply: CoachBriefReply.Parsed, to output: Output) -> Output {
        let reworded: [CoachSuggestion] = reply.picks.compactMap { pick in
            guard output.suggestions.indices.contains(pick.index) else { return nil }
            var s = output.suggestions[pick.index]
            s.title = pick.title
            s.body = pick.body
            return s
        }
        return Output(brief: reply.brief, suggestions: reworded.isEmpty ? output.suggestions : reworded)
    }

    /// The numbered candidate list a cloud provider picks from (with each one's action kind, which the
    /// reply must echo), plus what the user recently declined. The candidates are already written in
    /// the app language, which keeps the provider in it too.
    static func providerPrompt(context: String, output: Output, declined: Set<String>, languageCode: String) -> String {
        var lines = [context, "", "---", "", "Candidates (pick by id; keep the action kind):"]
        for (i, s) in output.suggestions.enumerated() {
            lines.append("\(i). action=\(s.action.kindName) [\(s.kind.rawValue)] \(s.title): \(s.body) \(s.rationale)")
        }
        if !declined.isEmpty {
            lines.append("Recently declined by the user: \(declined.sorted().joined(separator: ", ")).")
        }
        lines.append("Draft brief for reference: \(output.brief)")
        lines.append(CoachBriefReply.languageDirective(languageCode: languageCode))
        return lines.joined(separator: "\n")
    }

    // MARK: - One suggestion

    static func suggestion(for c: CoachMorningRules.Candidate, now: Date, whoopScale: Bool) -> CoachSuggestion {
        let facts = facts(for: c, whoopScale: whoopScale)
        let format = CoachEvidenceFormat(clock: { clock($0) }, duration: { ZoopDuration.text(minutes: Double($0)) })
        let because = CoachStrings.because(c.evidence.map { CoachStrings.clause($0, format: format) })
        return CoachSuggestion(createdAt: now, kind: c.kind, reason: c.reason.rawValue,
                               title: CoachStrings.title(c.reason, facts),
                               body: CoachStrings.body(c.reason, facts),
                               rationale: because,
                               action: c.action, expiresAt: expiry(for: c.kind, now: now))
    }

    private static func facts(for c: CoachMorningRules.Candidate, whoopScale: Bool) -> CoachStrings.Facts {
        var f = CoachStrings.Facts()
        for e in c.evidence { if case .planned(let name) = e { f.routine = name } }
        switch c.action {
        case .routine(_, let name): f.routine = name
        case .bedtime(let minute), .fastingStart(let minute, _), .breathe(let minute): f.time = clock(minute)
        case .strainTarget(let low, let high):
            let (lo, hi) = TodayRings.strainTargetNumbers(low...high, whoopScale: whoopScale,
                                                          locale: AppLanguage.activeLocale)
            f.target = "\(lo)–\(hi)"
        case .none: break
        }
        return f
    }

    /// Daytime advice lapses at midnight; a bedtime holds until the small hours of the next day.
    private static func expiry(for kind: CoachSuggestion.Kind, now: Date) -> Date {
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return kind == .sleepTiming ? midnight.addingTimeInterval(3 * 3600) : midnight
    }

    /// Recovery as Zoop prints it everywhere: the plain score, no "%".
    static func score(_ value: Double) -> String { ZoopNumber.decimal(value.rounded(), digits: 0) }

    /// Minute of day as a localized clock time ("22:40" / "10:40 PM").
    static func clock(_ minute: Int, on day: Date = Date()) -> String {
        let date = Calendar.current.startOfDay(for: day).addingTimeInterval(Double(minute) * 60)
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppClock.formattingLocale))
    }
}
#endif
