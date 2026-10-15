import Foundation

// Per-mode day/night capture accumulator (#965). The Test Centre "Capturing K of N" row used to
// count elapsed wall-clock days, so every active mode read the same regardless of what it captured.
// This counts the distinct local calendar days a domain's own tagged trace lines carry, so each mode
// accumulates independently off the shareable log: sleep counts nights (`sleep day=` / `[sleep] gate
// run=`), battery counts days (`[battery] bank soc= t=<unix>s`, folded to a local day), steps counts
// `stepsRaw day=`, and the universal row counts `dayOwner day=` once per scored day. Pure: domain,
// redacted report text and a timezone offset in, an Int out.

public enum CaptureAccumulator {

    /// How a captured day shows up in the log. `.dayKey` domains write `day=YYYY-MM-DD` on their trace
    /// line; `.epoch` domains write a `t=<unix>s` stamp (battery banks a SoC sample per reading) folded to a
    /// local day. A domain not listed has no day-bearing trace and counts 0. The tokens also scope the scan
    /// so an unrelated line carrying `day=` is not counted toward the wrong mode.
    enum DayMarker: Equatable {
        case dayKey(tokens: [String])   // a `day=YYYY-MM-DD` on a line carrying any of `tokens`
        case epoch(tokens: [String])    // a `t=<unix>s` on a line carrying any of `tokens`
    }

    /// The {domain -> day-marker} map. Tokens are the verbatim leading text the live emitters write
    /// (mirroring CaptureCompleteness.tokens); a domain absent from the map accumulates 0.
    /// sleep -> `sleep day=YYYY-MM-DD ...`; steps -> `stepsRaw day=YYYY-MM-DD ...`;
    /// recovery -> `charge ... day=YYYY-MM-DD` / `charge day=YYYY-MM-DD ...`;
    /// battery -> `bank soc=... t=<unix>s` folded to a local day;
    /// universal -> `dayOwner day=YYYY-MM-DD ...`, one per scored day.
    static let markers: [TestDomain: DayMarker] = [
        .sleep:     .dayKey(tokens: ["sleep day=", "gate run="]),
        .steps:     .dayKey(tokens: ["stepsRaw", "stepsEst day="]),
        .recovery:  .dayKey(tokens: ["charge "]),
        .battery:   .epoch(tokens: ["bank soc="]),
        .universal: .dayKey(tokens: ["dayOwner "]),
    ]

    /// yyyy-MM-dd matcher for `day=<key>`; the unix stamp on epoch lines is scanned separately.
    private static let dayKeyRegex = try? NSRegularExpression(pattern: "day=([0-9]{4}-[0-9]{2}-[0-9]{2})")
    private static let epochRegex = try? NSRegularExpression(pattern: "\\bt=([0-9]{6,})s")

    /// Distinct local calendar days `domain` captured, from `reportText`. `.dayKey` domains contribute the
    /// `day=` keys on their tagged lines; `.epoch` domains fold each `t=<unix>s` to a local day via
    /// `tzOffsetSeconds` (seconds east of UTC, as in `AnalyticsEngine.dayString(_:offsetSec:)`). 0 with no
    /// marker or no trace. Pure.
    public static func capturedDays(domain: TestDomain, reportText: String, tzOffsetSeconds: Int) -> Int {
        capturedDayKeys(domain: domain, reportText: reportText, tzOffsetSeconds: tzOffsetSeconds).count
    }

    /// The set of distinct local day keys (yyyy-MM-dd) `domain` captured; empty when none.
    static func capturedDayKeys(domain: TestDomain, reportText: String, tzOffsetSeconds: Int) -> Set<String> {
        guard let marker = markers[domain] else { return [] }
        var days = Set<String>()
        for rawLine in reportText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            switch marker {
            case let .dayKey(tokens):
                guard tokens.contains(where: { line.contains($0) }) else { continue }
                if let key = firstDayKey(in: line) { days.insert(key) }
            case let .epoch(tokens):
                guard tokens.contains(where: { line.contains($0) }) else { continue }
                if let unix = firstEpoch(in: line) {
                    days.insert(AnalyticsEngine.dayString(unix, offsetSec: tzOffsetSeconds))
                }
            }
        }
        return days
    }

    /// First `day=YYYY-MM-DD` value on a line, or nil.
    private static func firstDayKey(in line: String) -> String? {
        guard let re = dayKeyRegex else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// First `t=<unix>s` value on a line, or nil.
    private static func firstEpoch(in line: String) -> Int? {
        guard let re = epochRegex else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}
