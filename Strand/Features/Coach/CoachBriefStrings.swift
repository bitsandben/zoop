#if os(iOS)
import Foundation
import StrandAnalytics

// MARK: - Morning brief explanations (zoop.coach.explain.* catalogue entries)
//
// The headline and the "because" lines of the morning brief, one per `MorningBriefDrivers.Driver`, each
// citing its own number and, when the user's history sizes it, the points it cost.

enum CoachBriefStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }

    private static func s(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    private static func n(_ v: Double) -> String { ZoopNumber.decimal(v.rounded(), digits: 0) }

    // MARK: Headline

    static func headline(_ brief: MorningBriefDrivers.Brief, recovery: Double, range: ClosedRange<Double>?) -> String {
        let pct = n(recovery)
        guard brief.notable else { return s(r("zoop.coach.explain.quiet", "All in the green: recovery \(pct).")) }
        switch brief.tone {
        case .below:
            let lo = n(range?.lowerBound ?? 0), hi = n(range?.upperBound ?? 0)
            return s(r("zoop.coach.explain.below", "Recovery \(pct), below your usual \(lo)–\(hi)."))
        case .within:
            return s(r("zoop.coach.explain.within", "Recovery \(pct), still in your usual range, but something stands out."))
        case .above:
            return s(r("zoop.coach.explain.above", "Recovery \(pct), above your usual range, but something stands out."))
        case .unknown:
            return recovery < MorningBriefDrivers.redRecovery
                ? s(r("zoop.coach.explain.low", "Recovery \(pct): today is for recovering."))
                : s(r("zoop.coach.explain.plain", "Recovery \(pct), and something stands out."))
        }
    }

    // MARK: Because lines

    static func line(_ d: MorningBriefDrivers.Driver) -> String {
        let base: String
        switch d.kind {
        case .illness:
            base = s(r("zoop.coach.explain.illness", "Several of your vitals are outside your usual range, something may be coming on"))
        case .restless:
            let v = n(d.value), t = n(d.typical ?? 0)
            base = s(r("zoop.coach.explain.restless", "You moved a lot in your sleep: \(v) movement bouts instead of your usual \(t)"))
        case .restlessMinutes:
            let v = ZoopDuration.text(minutes: d.value), t = ZoopDuration.text(minutes: d.typical ?? 0)
            base = s(r("zoop.coach.explain.restlessMinutes", "You were restless for \(v) in your sleep, usually \(t)"))
        case .restingHR:
            let v = n(d.value)
            base = s(r("zoop.coach.explain.rhr", "Your resting heart rate was \(v) bpm above your normal"))
        case .hrv:
            let v = ZoopNumber.percent(abs(d.value))
            base = d.value < 0
                ? s(r("zoop.coach.explain.hrv", "Your HRV was \(v) below your normal"))
                : s(r("zoop.coach.explain.hrvUp", "Your HRV was \(v) above your normal"))
        case .sleep:
            let v = ZoopDuration.text(minutes: abs(d.value))
            base = s(r("zoop.coach.explain.sleep", "You slept \(v) less than you need"))
        case .bedtime:
            let v = ZoopDuration.text(minutes: d.value)
            base = s(r("zoop.coach.explain.bedtime", "You went to bed \(v) later than usual"))
        case .strain:
            let v = ZoopNumber.percent(d.value)
            base = s(r("zoop.coach.explain.strain", "Yesterday was \(v) harder than your average"))
        case .logged:
            let name = RecoveryFactorsBuilder.name(d.question)
            base = s(r("zoop.coach.explain.logged", "You logged \(name)"))
        }
        guard let p = d.points, abs(p) >= 1 else { return s(r("zoop.coach.body.plain", "\(base).")) }
        let pts = ZoopNumber.signed(p.rounded(), digits: 0)
        return s(r("zoop.coach.explain.points", "\(base) (about \(pts) points)."))
    }

    /// Headline plus one line per driver, as stored and shown in the brief sheet.
    static func text(headline: String, lines: [String]) -> String {
        ([headline] + lines.map { "• " + $0 }).joined(separator: "\n")
    }

    /// The push body: the headline and the first two reasons, without bullets.
    static func push(headline: String, lines: [String]) -> String {
        ([headline] + lines.prefix(2)).joined(separator: " ")
    }

    /// The drivers as plain facts for a cloud provider, which may only reword them.
    static func providerLines(_ lines: [String]) -> [String] {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }
}
#endif
