import Foundation

/// Per-day reuse identity for `IntelligenceEngine.analyzeRecent`'s pass-1 loop (#1005). A post-offload
/// only adds rows to the 1-2 newest days, yet every re-score re-read all nights and re-ran `analyzeDay`.
/// Pass 1 keeps only each night's small result, so a night whose scored inputs are unchanged reproduces
/// a byte-identical result: an in-memory `[day: (key, DayScan)]` cache reuses the scan when this key
/// matches. A miss is the full path, and every day still flows into pass 2. The cache is per-device and
/// never persists or crosses the `.zoopbak` boundary.
public enum AnalyzeRecentDayCache {

    /// Which part of a day's cache key moved, for the miss reason on the reuse line (#2073). A healthy
    /// pass reuses all but today; a pass reusing nothing has had something shared by every key change
    /// (`rrAlias5` is computed once per pass and folded into all keys, so it alone can cause a total miss).
    /// Keys are `owner|hrCount:hrMaxTs:anchor:detail|streams`, so the differing segment names the cause.
    public static func missReason(cachedKey: String, freshKey: String) -> String {
        if cachedKey == freshKey { return "none" }
        let a = cachedKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        let b = freshKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        if a.count < 3 || b.count < 3 { return "shape" }
        if a[0] != b[0] { return "owner" }
        if a[1] != b[1] { return "hr" }
        let ra = a[2].range(of: "rrAlias5=").map { String(a[2][$0.upperBound...]) } ?? ""
        let rb = b[2].range(of: "rrAlias5=").map { String(b[2][$0.upperBound...]) } ?? ""
        return ra != rb ? "rrAlias5" : "streams"
    }
    /// The per-day reuse key: reuse a cached day iff this string is unchanged.
    /// - `hrCount` / `hrMaxTs`: night-window HR row count and newest timestamp, the same change witness
    ///   the whole-pass gate uses, at day granularity.
    /// - `skinAnchorRaw`: the WHOOP 4.0 window-wide skin-temp anchor (nil for 5/MG or unresolved). Another
    ///   night's data can re-anchor and shift this night's skin conversion without moving its HR
    ///   fingerprint. Encoded by raw bit pattern for exact, locale-free equality.
    /// - `owner`: the resolved owning device id, so a multi-strap owner flip invalidates explicitly.
    /// - `streams`: opaque witness of every other scored stream (PPG HR, R-R, respiration, SpO2, gravity,
    ///   steps, skin temp, events; `WhoopStore.dayStreamFingerprint`). A history offload does not commit
    ///   channels together, so a night can gain its R-R with `hrCount`/`hrMaxTs` unmoved (#29); keyed on HR
    ///   alone the HRV-less scan was re-served even on force refresh.
    /// Pass-global inputs (profile, baselines, sleep need, habitual midsleep, tz, stager toggles) are not
    /// in the key; the engine drops the whole cache when its pass config signature changes.
    public static func cacheKey(owner: String, hrCount: Int, hrMaxTs: Int, skinAnchorRaw: Double?,
                                streams: String,
                                // Whether this day emits the per-window HRV detail (`dayStart == nowLocalMidnight`, #1575). The
                                // night cached as today with its detailed trace becomes ordinary after midnight and must not keep
                                // replaying detail; costs one re-score per rollover, only while a trace mode is on.
                                hrvWindowDetail: Bool) -> String {
        let anchor = skinAnchorRaw.map { String($0.bitPattern) } ?? "nil"
        return "\(owner)|\(hrCount):\(hrMaxTs):\(anchor):\(hrvWindowDetail ? "d" : "s")|\(streams)"
    }
}
