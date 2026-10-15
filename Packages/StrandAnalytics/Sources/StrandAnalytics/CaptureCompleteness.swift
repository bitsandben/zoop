import Foundation

// Report-completeness guard (#812). A Test Centre report could ship thin: the mode was on but its
// key trace never landed (dead emitter, gate never fired). At export, for every domain active during
// the capture, this scans the redacted report text for that domain's expected token(s) and reports OK
// (with a count) or INCOMPLETE (naming the missing token). The result goes into report.txt as a
// "Capture check" section and into meta.json as `capture_check`. Pure: active-domain set and redacted
// text in, values out; it only counts token occurrences. The token map is the single source for the
// renderer and the meta field.

/// Whether a domain active during the capture produced its key trace.
public enum CaptureStatus: String, Sendable, Codable, Equatable {
    case ok          // at least one expected token was found
    case incomplete  // the mode was active but NONE of its expected tokens appear (the dead-trace warning)
}

/// One domain's verdict: OK/INCOMPLETE, how many matching token lines were found, and which tokens were
/// sought (so INCOMPLETE names what is missing).
public struct CaptureCheck: Sendable, Codable, Equatable {
    public let domain: String          // TestDomain.id
    public let status: CaptureStatus
    public let count: Int              // total matching token-bearing lines found across this domain's tokens
    public let tokens: [String]        // the expected token(s) for this domain (what we scanned for)
    public init(domain: String, status: CaptureStatus, count: Int, tokens: [String]) {
        self.domain = domain; self.status = status; self.count = count; self.tokens = tokens
    }
}

public enum CaptureCompleteness {

    /// The map {domain -> expected key-trace token(s)}. A domain is OK when the redacted report has a line
    /// carrying any of its tokens, matched as plain substrings. Tokens are the verbatim leading words the
    /// live emitters write:
    /// sleep -> gate-run trace and sleep-provenance line; connection -> clock-drift summary and bond-state
    /// line; workouts -> auto-detect verdict, session lifecycle and detected-bout lines; display ->
    /// data-volume line and frame-time digest; import -> per-stage rowsIn/rowsOut; steps -> raw step-counter
    /// trace including its no-counter sentinel (a capture that found no counter still emits an honest line,
    /// which counts as a real trace); battery -> banked SoC series; recovery -> Charge term breakdown;
    /// hrv -> rMSSD / spot-reading result; universal -> the dayOwner line on every export.
    public static let tokens: [TestDomain: [String]] = [
        // `sleep day=` (#127) is the always-on per-day provenance line, emitted even when the night was scored
        // on the backfill pass or analyzeRecent skipped the traced gate, so a valid capture is not flagged
        // INCOMPLETE because `gate run=` / `sleepProvenance` did not re-fire.
        .sleep:      ["gate run=", "sleepProvenance", "sleep day="],
        .connection: ["clockDrift", "bondState"],
        .workouts:   ["autoDetect", "session event=", "detectedBout"],
        .display:    ["dataVolume", "frameSummary"],
        .dataImport: ["import stage=", "rowsIn="],
        .steps:      ["stepsRaw", "stepsCal"],
        .battery:    ["bank soc=", "socSeries"],
        // "charge day=": IntelligenceEngine re-emits every recovery trace line as `charge day=<day> ` + body,
        // so other variants could never match.
        .recovery:   ["charge day="],
        .hrv:        ["hrv rmssd=", "hrv result=", "hrv nightSummary"],
        .universal:  ["dayOwner ", "strapClock "],
    ]

    /// Expected tokens for one domain (empty for a domain with no registered emitter, e.g. notifications).
    public static func expectedTokens(for domain: TestDomain) -> [String] {
        tokens[domain] ?? []
    }

    /// Count lines of `reportText` carrying any of `tokens` (plain substring); a line with two tokens counts once.
    static func countMatches(reportText: String, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var n = 0
        for line in reportText.split(separator: "\n", omittingEmptySubsequences: false) {
            if tokens.contains(where: { line.contains($0) }) { n += 1 }
        }
        return n
    }

    /// Run the guard over the redacted `reportText` for each domain in `activeDomains` (those active
    /// during the capture; the caller adds `.universal` when any mode was active). OK when a token appears,
    /// INCOMPLETE when the mode was on but no token landed. A domain with no registered tokens is skipped,
    /// never reported INCOMPLETE. Stable order: registry declaration order, universal last.
    public static func evaluate(activeDomains: Set<TestDomain>, reportText: String) -> [CaptureCheck] {
        // Declaration order with universal last, so per-domain rows read first.
        let ordered = TestDomain.allCases.filter { $0 != .universal } + [.universal]
        return ordered.compactMap { domain -> CaptureCheck? in
            guard activeDomains.contains(domain) else { return nil }
            let toks = expectedTokens(for: domain)
            guard !toks.isEmpty else { return nil }   // no emitter promised => not graded
            let count = countMatches(reportText: reportText, tokens: toks)
            return CaptureCheck(domain: domain.id,
                                status: count > 0 ? .ok : .incomplete,
                                count: count, tokens: toks)
        }
    }

    /// Render the "Capture check" section for report.txt: an OK row names the count, an INCOMPLETE row names
    /// the missing token(s). Empty when nothing was graded.
    public static func reportSection(_ checks: [CaptureCheck]) -> String {
        guard !checks.isEmpty else { return "" }
        var lines = ["", String(repeating: "-", count: 40), "Capture check"]
        for c in checks {
            switch c.status {
            case .ok:
                lines.append("  [OK] \(c.domain): \(c.count) trace line\(c.count == 1 ? "" : "s") "
                             + "(\(c.tokens.joined(separator: " / ")))")
            case .incomplete:
                lines.append("  [INCOMPLETE] \(c.domain): mode was on but produced NO trace "
                             + "(expected \(c.tokens.joined(separator: " / ")))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// True when any graded domain came back INCOMPLETE (a one-glance "this report is thin" flag).
    public static func anyIncomplete(_ checks: [CaptureCheck]) -> Bool {
        checks.contains { $0.status == .incomplete }
    }
}
