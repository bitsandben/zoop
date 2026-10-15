import Foundation
import WhoopProtocol

/// Pure half of the nightly absolute skin-temperature (`skinTempC`) backfill for nights the 21-night
/// rescore window never reaches: the session-attribution rule and the per-night plan. The walker that
/// touches `WhoopStore` lives in `Strand/Data`.
///
/// Rules:
/// 1. Attribute sessions by END. The night window is 54 h wide and contains the previous night too;
///    feeding the funnel the whole window averages two nights into one temperature.
/// 2. Page the candidates. A plain "oldest N" returns the same nights every pass, and the oldest are
///    the likeliest to have lost raw samples, so the sweep would never reach newer nights.
/// 3. The WHOOP 4.0 anchor comes from the CURRENT window. A re-learned anchor cancels in a deviation
///    but not in an absolute, so backfilled nights would sit on a different offset. No anchor means
///    decline, never the global default.
public enum SkinTempBackfill {

    /// One night under consideration: the day key, its read window (unix seconds), and the device owner
    /// whose raw streams are read.
    public struct NightCandidate: Equatable, Sendable {
        public let day: String           // yyyy-MM-dd (local-day key, matching DailyMetric.day)
        public let from: Int             // unix seconds: dayStart - StreamReadCap.lookbackSeconds
        public let to: Int               // unix seconds: dayStart + 24h (or now for today)
        public let owner: String         // the device id whose raw streams wrote this night
        public init(day: String, from: Int, to: Int, owner: String) {
            self.day = day; self.from = from; self.to = to; self.owner = owner
        }
    }

    /// The result of attempting one night's backfill.
    public struct NightResult: Equatable, Sendable {
        public let day: String
        /// The re-derived absolute (°C), or nil when the night declined. The walker writes `skinTempC` only
        /// when this is non-nil.
        public let skinTempC: Double?
        /// Why the night declined, or nil when it filled.
        public let declineReason: String?
        public init(day: String, skinTempC: Double?, declineReason: String? = nil) {
            self.day = day; self.skinTempC = skinTempC; self.declineReason = declineReason
        }
    }

    /// Rule 1: a session belongs to `day` iff its END falls in `[dayStart, dayStart + 86400)`, matching
    /// the engine's `tsInDay(it.end)` filter. `dayStart` is local-midnight unix seconds.
    public static func sessionsForDay(_ sessions: [SleepSession], dayStart: Int) -> [SleepSession] {
        let dayEnd = dayStart + 86_400
        return sessions.filter { $0.end >= dayStart && $0.end < dayEnd }
    }

    /// Rule 3: returns the anchor to use, or nil to decline. With no learned per-device anchor the night
    /// declines (never the global 826 default). For a 5/MG (`.whoop5`) the anchor is always nil and the
    /// night proceeds (centidegree path).
    public static func resolveAnchor(family: DeviceFamily, windowAnchorRaw: Double?) -> Double? {
        switch family {
        case .whoop4:
            // No anchor: decline; the global 826 is not a fallback.
            return windowAnchorRaw
        case .whoop5:
            return nil
        }
    }

    /// Compute one night's backfill absolute, applying all three rules.
    ///
    /// - Parameters:
    ///   - sessions: ALL sleep sessions in the 54 h window; filtered to this day by end timestamp.
    ///   - family: the device family that wrote the owner's skin-temp rows.
    ///   - windowAnchorRaw: the WHOOP 4.0 anchor learned from the current scoring window (nil for 5/MG
    ///     or when none could be learned).
    ///   - wornToleranceSec: worn-gate timestamp tolerance (0 for WHOOP, >0 for Oura).
    /// - Returns: the nightly mean (°C) or nil with a decline reason.
    public static func computeNight(
        candidate: NightCandidate,
        sessions: [SleepSession],
        hr: [HRSample],
        skinTemp: [SkinTempSample],
        family: DeviceFamily,
        windowAnchorRaw: Double?,
        dayStart: Int,
        wornToleranceSec: Int = 0
    ) -> NightResult {
        let matched = sessionsForDay(sessions, dayStart: dayStart)
        if matched.isEmpty {
            return NightResult(day: candidate.day, skinTempC: nil,
                               declineReason: "no sleep session ends on this day")
        }
        let anchor = resolveAnchor(family: family, windowAnchorRaw: windowAnchorRaw)
        if family == .whoop4 && anchor == nil {
            return NightResult(day: candidate.day, skinTempC: nil,
                               declineReason: "no per-device 4.0 anchor from the current window (rule 3: decline, not global fallback)")
        }
        // Same funnel the scoring pass uses, so the two cannot disagree.
        let diag = AnalyticsEngine.skinTempFunnel(
            matched, hr: hr, skinTemp: skinTemp, family: family,
            anchorRaw: anchor, wornToleranceSec: wornToleranceSec)
        if let mean = diag.mean {
            return NightResult(day: candidate.day, skinTempC: mean)
        }
        let reason = diag.kept < diag.minSamples
            ? "only \(diag.kept)/\(diag.minSamples) worn samples"
            : "funnel returned no mean"
        return NightResult(day: candidate.day, skinTempC: nil, declineReason: reason)
    }

    /// Rule 2: one page of candidates, oldest-first within the page. The walker calls this with
    /// increasing 0-based `page` until a page is empty. `pageSize` caps per-pass cost (one sleep-window
    /// sample read per night).
    public static func page(_ candidates: [NightCandidate], page: Int, pageSize: Int = 50) -> [NightCandidate] {
        let start = page * pageSize
        guard start < candidates.count else { return [] }
        let end = min(start + pageSize, candidates.count)
        return Array(candidates[start..<end])
    }
}
