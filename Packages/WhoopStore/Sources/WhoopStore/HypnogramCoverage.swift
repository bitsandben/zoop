import Foundation

/// How much of a sleep session's `[startTs, endTs)` span its stage segments account for.
///
/// A stage timeline is expected to tile its span, but a device-provided hypnogram assembled from
/// incomplete records (Oura merges only contiguous codes) can leave holes while `startTs`/`endTs` still
/// span the whole night; one measured night covered 23% of its span. Coverage is a ratio of two stored
/// numbers, derived on read, so nothing is persisted and it applies retroactively.
///
/// It only reports how much was OBSERVED: callers must not treat unobserved time as awake.
public enum HypnogramCoverage {

    /// Coverage at or above which a stage timeline is treated as describing its whole span. Healthy nights
    /// measured 99-100% and broken ones 23-93%, so 0.95 sits in the empty middle.
    public static let minCoverage: Double = 0.95

    /// The covered fraction of `spanSeconds`, or nil ("unknown, do not judge") when there is nothing to
    /// measure, so unknown is never mistaken for bad. Clamped to 1 so overlapping segments read as complete.
    public static func fraction(coveredSeconds: Double, spanSeconds: Double) -> Double? {
        guard spanSeconds > 0, coveredSeconds > 0 else { return nil }
        return min(1.0, coveredSeconds / spanSeconds)
    }

    /// The covered fraction of `spanSeconds` for a session's stored `stagesJSON`, or nil when coverage is not
    /// meaningful: a nil/blank/`"[]"` payload, the imported minute-dict shape, Health Connect's `{stage,min}`
    /// array (no timestamps), or an array holding any non-object element.
    ///
    /// Timestamp-free shapes keep this gate off the WHOOP CSV, Apple and Health Connect imports. Not a blanket
    /// import exemption: the Xiaomi importer emits timestamped segments with a span taken from independent
    /// bedtime/wake fields, so a Xiaomi night whose items fall short of those bounds is judged holed (pinned by test).
    public static func fraction(stagesJSON: String?, spanSeconds: Double) -> Double? {
        fraction(coveredSeconds: coveredSeconds(stagesJSON: stagesJSON), spanSeconds: spanSeconds)
    }

    /// Seconds of `stagesJSON` covered by timestamped segments, or 0 when the payload has none. Zero, not nil,
    /// because it is a summable quantity; use `fraction` to distinguish unknown from known for one session.
    public static func coveredSeconds(stagesJSON: String?) -> Double {
        guard let json = stagesJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let segs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return 0 }
        var covered = 0.0
        for seg in segs {
            guard let s = (seg["start"] as? NSNumber)?.doubleValue,
                  let e = (seg["end"] as? NSNumber)?.doubleValue, e > s else { continue }
            covered += e - s
        }
        return covered
    }

    /// Coverage summed across a bridged main-night GROUP, the quantity a night is judged on.
    ///
    /// Mirrors `AnalyticsEngine.analyzeDay` term for term: every fragment adds its full `[startTs, endTs)` to the
    /// denominator, but only timestamped segments add cover, so a group mixing a timestamp-free fragment with a
    /// timestamped one reads as holed. A group whose fragments are all timestamp-free comes back nil.
    public static func groupFraction(_ fragments: [(stagesJSON: String?, spanSeconds: Double)]) -> Double? {
        var covered = 0.0, span = 0.0
        for f in fragments {
            span += f.spanSeconds
            covered += coveredSeconds(stagesJSON: f.stagesJSON)
        }
        return fraction(coveredSeconds: covered, spanSeconds: span)
    }

    public static func groupFraction(_ sessions: [CachedSleepSession]) -> Double? {
        groupFraction(sessions.map { (stagesJSON: $0.stagesJSON,
                                      spanSeconds: Double($0.endTs - $0.startTs)) })
    }

    /// `isHoled` for a bridged main-night GROUP. Unknown coverage (nil) is not holed.
    public static func isHoledGroup(_ sessions: [CachedSleepSession]) -> Bool {
        guard let f = groupFraction(sessions) else { return false }
        return f < minCoverage
    }

    /// True when the timeline is known to cover less than `minCoverage` of its span. Unknown coverage (nil)
    /// is not holed: guards built on this fail open.
    public static func isHoled(stagesJSON: String?, spanSeconds: Double) -> Bool {
        guard let f = fraction(stagesJSON: stagesJSON, spanSeconds: spanSeconds) else { return false }
        return f < minCoverage
    }

    /// `isHoled` for a stored session, using its own `[startTs, endTs)` as the span.
    public static func isHoled(_ s: CachedSleepSession) -> Bool {
        isHoled(stagesJSON: s.stagesJSON, spanSeconds: Double(s.endTs - s.startTs))
    }
}
