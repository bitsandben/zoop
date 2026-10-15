import Foundation

/// One line summarising every day a scoring pass skipped for want of HR samples, instead of one line
/// per day. A pass walks a fixed window, so un-scoreable days are re-skipped every pass, and the strap
/// log is a fixed-size rolling buffer that such noise evicts. Days are grouped by sample count and
/// listed (not collapsed to a range that could hide a gap). Returns nil when nothing was skipped.
public func skippedSleepDaysLine(_ skipped: [(day: String, hrSamples: Int)], minHrSamples: Int) -> String? {
    if skipped.isEmpty { return nil }
    var byCount: [Int: [String]] = [:]
    for entry in skipped { byCount[entry.hrSamples, default: []].append(entry.day) }
    let groups = byCount.keys.sorted().map { count -> String in
        let days = byCount[count]!.sorted()
        return "hrSamples=\(count) on \(days.count) day(s): \(days.joined(separator: ", "))"
    }
    return "sleep SKIPPED \(skipped.count) day(s) — need ≥\(minHrSamples) hrSamples: "
        + groups.joined(separator: "; ")
}
