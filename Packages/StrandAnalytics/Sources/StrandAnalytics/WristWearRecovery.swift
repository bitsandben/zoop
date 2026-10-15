import WhoopProtocol

/// Reconciles a missing WRIST_ON event without declaring an unobserved tail worn. Only the unpaired OFF
/// tail uses this; explicit OFF/ON intervals stay authoritative. Valid HR is 30...220 bpm (AnalyticsEngine's
/// worn-HR gate); five minutes with no gap over five seconds rejects isolated pulses and sparse streams.
/// The returned boundary is the first observed sample of that run. Not a sleep classifier.
public enum WristWearRecovery {
    public static let confirmationSeconds = 5 * 60
    public static let maximumGapSeconds = 5

    public static func firstSustainedHR(_ hr: [HRSample], after: Int, before: Int) -> Int? {
        // Duplicate timestamps collapse conservatively: an invalid observation wins.
        var validByTimestamp: [Int: Bool] = [:]
        for sample in hr where sample.ts > after && sample.ts < before {
            validByTimestamp[sample.ts] = (validByTimestamp[sample.ts] ?? true)
                && (30...220).contains(sample.bpm)
        }
        var start: Int?
        var previous: Int?
        for ts in validByTimestamp.keys.sorted() {
            guard validByTimestamp[ts] == true else {
                start = nil; previous = nil
                continue
            }
            if previous == nil || ts - previous! > maximumGapSeconds { start = ts }
            previous = ts
            if let start, ts - start >= confirmationSeconds { return start }
        }
        return nil
    }
}
