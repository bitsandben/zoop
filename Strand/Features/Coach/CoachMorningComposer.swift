#if os(iOS)
import Foundation
import StrandAnalytics

/// Turns a rule plan into the stored objects: the brief text and the suggestions with their copy,
/// rationale and expiry. A cloud reply, when there is one, only replaces the wording.
enum CoachMorningComposer {

    struct Output {
        let brief: String
        let suggestions: [CoachSuggestion]
    }

    /// The rule-based brief: readiness, the night, and the first suggestion as today's focus.
    static func compose(input: CoachMorningRules.Input, plan: CoachMorningRules.Plan, now: Date) -> Output {
        let suggestions = plan.candidates.map { suggestion(for: $0, input: input, now: now) }
        var sentences: [String] = []
        if let pct = input.recovery.map(percent), let line = CoachStrings.readiness(plan.readiness, pct: pct) {
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

    /// The numbered candidate list a cloud provider picks from, plus what the user recently declined.
    static func providerPrompt(context: String, output: Output, declined: Set<String>) -> String {
        var lines = [context, "", "---", "", "Candidates (pick by id):"]
        for (i, s) in output.suggestions.enumerated() {
            lines.append("\(i). [\(s.kind.rawValue)] \(s.title): \(s.body) (based on: \(s.rationale))")
        }
        if !declined.isEmpty {
            lines.append("Recently declined by the user: \(declined.sorted().joined(separator: ", ")).")
        }
        lines.append("Draft brief for reference: \(output.brief)")
        return lines.joined(separator: "\n")
    }

    // MARK: - One suggestion

    static func suggestion(for c: CoachMorningRules.Candidate, input: CoachMorningRules.Input,
                           now: Date) -> CoachSuggestion {
        let facts = facts(for: c, input: input)
        return CoachSuggestion(createdAt: now, kind: c.kind, reason: c.reason.rawValue,
                               title: CoachStrings.title(c.reason, facts),
                               body: CoachStrings.body(c.reason, facts),
                               rationale: rationale(for: c.reason, input: input),
                               action: c.action, expiresAt: expiry(for: c.kind, now: now))
    }

    private static func facts(for c: CoachMorningRules.Candidate, input: CoachMorningRules.Input) -> CoachStrings.Facts {
        var f = CoachStrings.Facts()
        if let band = input.strainTarget { f.low = "\(band.lowerBound)"; f.high = "\(band.upperBound)" }
        f.routine = input.plannedRoutines.first?.name ?? ""
        f.debt = ZoopDuration.text(minutes: input.sleepDebtMin)
        switch c.action {
        case .routine(_, let name): f.routine = name
        case .bedtime(let minute), .fastingStart(let minute, _): f.time = clock(minute)
        case .strainTarget(let low, let high): f.low = "\(low)"; f.high = "\(high)"
        case .none: break
        }
        return f
    }

    /// The data a reason rests on, joined into one line ("Recovery 28% · Sleep debt 1h 20m").
    private static func rationale(for reason: CoachMorningRules.Reason, input: CoachMorningRules.Input) -> String {
        var parts: [String] = []
        let recovery = input.recovery.map { CoachStrings.whyRecovery(percent($0)) }
        switch reason {
        case .lowRecoveryRest, .greenRoutine, .greenPush, .moderateSession, .steadyDay:
            parts = [recovery].compactMap { $0 }
        case .plannedRoutineEaseOff, .plannedRoutineGo:
            parts = [recovery, input.plannedRoutines.first.map { CoachStrings.whyPlanned($0.name) }].compactMap { $0 }
        case .sleepDebtBedtime:
            parts = [CoachStrings.whyDebt(ZoopDuration.text(minutes: input.sleepDebtMin))]
        case .shortNightBedtime:
            parts = [input.sleepMin.map { CoachStrings.whySleep(ZoopDuration.text(minutes: $0)) }].compactMap { $0 }
        case .hrvBelowRange:
            if let h = input.hrv, let b = input.hrvBaseline {
                parts = [CoachStrings.whyHrv(ZoopNumber.decimal(h, digits: 0), typical: ZoopNumber.decimal(b, digits: 0))]
            }
        case .highStress:
            parts = [input.stressLevel.map { CoachStrings.whyStress(ZoopNumber.decimal($0, digits: 1)) }].compactMap { $0 }
        case .fastingNext:
            parts = [CoachStrings.whyFasting]
        case .fastingShorten:
            parts = [recovery, CoachStrings.whyFasting].compactMap { $0 }
        }
        return parts.joined(separator: " · ")
    }

    /// Daytime advice lapses at midnight; a bedtime holds until the small hours of the next day.
    private static func expiry(for kind: CoachSuggestion.Kind, now: Date) -> Date {
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return kind == .sleepTiming ? midnight.addingTimeInterval(3 * 3600) : midnight
    }

    static func percent(_ value: Double) -> String { ZoopNumber.percent(value.rounded()) }

    /// Minute of day as a localized clock time ("22:40" / "10:40 PM").
    static func clock(_ minute: Int, on day: Date = Date()) -> String {
        let date = Calendar.current.startOfDay(for: day).addingTimeInterval(Double(minute) * 60)
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppClock.formattingLocale))
    }
}
#endif
