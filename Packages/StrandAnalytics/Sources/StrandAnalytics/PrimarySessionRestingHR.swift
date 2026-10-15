import Foundation

/// #1169: shadow resting-HR definition, the arithmetic mean of valid HR samples in the longest (primary) sleep
/// session rather than the five-minute floor `AnalyticsEngine` ships. Recorded in `rhr_primary_session` for
/// comparison only; it does not feed scoring (#2522 keeps the primary-session selection but the floor value).
///
/// Evidence is thin: one participant over five nights against official WHOOP RHR and a Polar H10 ECG mean
/// (pre-declared dev/holdout split, no fitted offset); rounded MAE vs official 6.0->2.0 (dev) / 7.5->0.8 (holdout).
///
/// - Primary session: the longest by duration, ties to the first; a short nap never replaces the main night.
/// - Valid sample: bpm within `validBpm` (default 30...220, `AnalyticsEngine`'s worn-HR range); out-of-range or absent samples are excluded.
/// - Mean: unweighted sample mean (a time-weighted variant behaves differently under irregular cadence).
/// - Coverage: nil unless the primary session has at least `minValidSamples` valid samples.
/// Approximate, not clinically validated.
public enum PrimarySessionRestingHR {

    /// One sleep session for a wake day: duration and raw (possibly invalid) HR samples in bpm. Wake-day assignment stays in `AnalyticsEngine`.
    public struct Session: Sendable, Equatable {
        public let durationSec: Double
        public let bpm: [Int]
        public init(durationSec: Double, bpm: [Int]) {
            self.durationSec = durationSec
            self.bpm = bpm
        }
    }

    /// The worn-HR range `AnalyticsEngine` uses, reused so validity is one rule.
    public static let defaultValidBpm: ClosedRange<Int> = 30...220
    /// Provisional minimum valid-sample coverage; a sample count is cadence-blind, so the rule is a tuning parameter.
    public static let defaultMinValidSamples = 30

    /// Mean valid HR of the longest session, or nil when no session clears `minValidSamples`.
    public static func meanHR(sessions: [Session],
                              validBpm: ClosedRange<Int> = defaultValidBpm,
                              minValidSamples: Int = defaultMinValidSamples) -> Double? {
        // Longest by duration; `max(by:)` keeps the first of equal durations.
        guard let primary = sessions.max(by: { $0.durationSec < $1.durationSec }) else { return nil }
        let valid = primary.bpm.filter { validBpm.contains($0) }
        guard valid.count >= minValidSamples else { return nil }
        return Double(valid.reduce(0, +)) / Double(valid.count)
    }

    /// Coverage inputs for the primary session `meanHR` averages: valid-sample count and duration. Raw inputs, not
    /// a derived fraction, so later validation can choose its own coverage definition. Shadow instrumentation only.
    public struct Coverage: Sendable, Equatable {
        /// Valid HR samples in the primary session.
        public let validSamples: Int
        /// The primary session's duration in seconds.
        public let durationSec: Double
        public init(validSamples: Int, durationSec: Double) {
            self.validSamples = validSamples
            self.durationSec = durationSec
        }
    }

    /// The primary session's valid-sample count and duration, or nil in lockstep with `meanHR`.
    public static func coverage(sessions: [Session],
                                validBpm: ClosedRange<Int> = defaultValidBpm,
                                minValidSamples: Int = defaultMinValidSamples) -> Coverage? {
        guard let primary = sessions.max(by: { $0.durationSec < $1.durationSec }) else { return nil }
        let valid = primary.bpm.filter { validBpm.contains($0) }
        guard valid.count >= minValidSamples else { return nil }
        return Coverage(validSamples: valid.count, durationSec: primary.durationSec)
    }
}
