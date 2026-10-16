#if os(iOS)
import Foundation
import StrandAnalytics

/// Turns a rule plan into the stored objects: the brief text and the suggestions with their copy,
/// "because" line and expiry, all in the app language. A cloud reply, when there is one, only
/// replaces the wording.
enum CoachMorningComposer {

    struct Output {
        /// One line: the score against the personal range, or the quiet all-good line.
        let headline: String
        /// The "because" lines, one per driver.
        let reasons: [String]
        let suggestions: [CoachSuggestion]
        /// Something stood out: only then does the morning push go out.
        let notable: Bool

        var brief: String { CoachBriefStrings.text(headline: headline, lines: reasons) }
        var push: String { CoachBriefStrings.push(headline: headline, lines: reasons) }
    }

    /// The rule-based brief: a headline that says where recovery sits against the user's normal, the
    /// drivers that explain it with their numbers, and at most two suggestions.
    static func compose(input: CoachMorningRules.Input, explain: MorningBriefDrivers.Input,
                        plan: CoachMorningRules.Plan, now: Date, whoopScale: Bool) -> Output {
        let suggestions = plan.candidates.map { suggestion(for: $0, now: now, whoopScale: whoopScale) }
        let drivers = MorningBriefDrivers.evaluate(explain)
        let reasons = drivers.drivers.map(CoachBriefStrings.line)
        let headline: String
        if let recovery = explain.recovery ?? input.recovery {
            headline = CoachBriefStrings.headline(drivers, recovery: recovery, range: explain.recoveryRange)
        } else {
            headline = suggestions.first.map { CoachStrings.focus($0.title) } ?? ""
        }
        return Output(headline: headline, reasons: reasons, suggestions: suggestions, notable: drivers.notable)
    }

    /// Applies a parsed cloud reply: its headline and reasons, and its picks in its order with its
    /// wording. Candidates the reply left out are dropped, since the provider judged them less relevant
    /// today. Reasons are kept from the rules when the reply dropped some, so no driver goes unexplained.
    static func applying(_ reply: CoachBriefReply.Parsed, to output: Output) -> Output {
        let reworded: [CoachSuggestion] = reply.picks.compactMap { pick in
            guard output.suggestions.indices.contains(pick.index) else { return nil }
            var s = output.suggestions[pick.index]
            s.title = pick.title
            s.body = pick.body
            return s
        }
        let reasons = reply.reasons.count == output.reasons.count ? reply.reasons : output.reasons
        return Output(headline: reply.headline, reasons: reasons,
                      suggestions: reworded.isEmpty ? output.suggestions : reworded, notable: output.notable)
    }

    /// The facts a cloud provider explains (the drivers, numbered, in the app language) and the numbered
    /// candidate list it picks from (with each one's action kind, which the reply must echo), plus what
    /// the user recently declined or was already told. Written in the app language, which keeps the
    /// provider in it too.
    static func providerPrompt(context: String, output: Output, declined: Set<String>,
                               recentTitles: [String], languageCode: String) -> String {
        var lines = [context, "", "---", "", "Headline draft: \(output.headline)"]
        lines.append(output.reasons.isEmpty
            ? "Drivers: none stood out today (reasons must be empty)."
            : "Drivers (explain each, keep every number):")
        lines += CoachBriefStrings.providerLines(output.reasons)
        lines.append("Candidates (pick by id; keep the action kind):")
        for (i, s) in output.suggestions.enumerated() {
            lines.append("\(i). action=\(s.action.kindName) [\(s.kind.rawValue)] \(s.title): \(s.body) \(s.rationale)")
        }
        if !declined.isEmpty {
            lines.append("Recently declined by the user: \(declined.sorted().joined(separator: ", ")).")
        }
        if !recentTitles.isEmpty {
            lines.append("Already suggested in the last days (do not repeat the wording): \(recentTitles.joined(separator: "; ")).")
        }
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
