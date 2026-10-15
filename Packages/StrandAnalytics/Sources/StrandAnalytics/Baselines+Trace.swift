import Foundation

// Per-night baseline fold diagnostic (Recovery test mode). Shows how a baseline got to its state,
// including quiet decisions: a night rejected as a hard outlier leaves no other trace, and a spread
// pinned on its floor looks like a settled one. Returns the state from `Baselines.update(...)`
// verbatim and recomputes only the intermediate decisions for the lines. Pure; values, counts and
// thresholds only, no PII; the call site gates on the Recovery test mode.

extension Baselines {

    /// Diagnostic twin of `update(...)`: returns the same state plus a line naming which branch the night took.
    /// Branches in the order `update` tests them:
    /// - `seed` / `seed-empty`: first ever night; fixes the centre and starts spread at the floor.
    /// - `missing`: no value; skip-and-hold, `nightsSinceUpdate` climbs.
    /// - `implausible`: outside physiological bounds; skip-and-hold.
    /// - `rejected`: a hard outlier once seeded and no longer young; seen, not folded.
    /// - `folded`: the normal Winsorized-EWMA path.
    /// The `folded` line reports `young`, the effective spread and half-life, the Winsor band and whether
    /// the value was clamped, and spread before/after with whether it landed on `cfg.floorSpread`;
    /// `atFloor=yes` many nights in means z-scores are still computed against the floor.
    /// - Parameter metric: the metric key ("hrv", "resting_hr", ...) so one log can carry several folds.
    public static func updateTrace(_ state: BaselineState?,
                                   value: Double?,
                                   cfg: MetricCfg,
                                   metric: String,
                                   rejectHardOutliers: Bool = true) -> (state: BaselineState, lines: [String]) {
        // The returned state is always the real fold's.
        let next = update(state, value: value, cfg: cfg, rejectHardOutliers: rejectHardOutliers)

        func r2(_ x: Double) -> Double { (x * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0 }
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        let head = "baseline \(metric)"
        let stateSuffix = "-> mean=\(r2(next.baseline)) spread=\(r2(next.spread)) "
            + "nValid=\(next.nValid) status=\(next.status.rawValue)"

        // Branch order mirrors `update`: it tests `state == nil` first and that branch decides the value's
        // validity, so a first night with a missing or out-of-range value is a seed case, not a skip.
        guard let state = state else {
            guard let v = value, cfg.minVal <= v && v <= cfg.maxVal else {
                return (next, ["\(head) night=seed-empty no usable first value "
                               + "(bounds=\(r2(cfg.minVal))..\(r2(cfg.maxVal))) "
                               + "seeded at midpoint, nValid stays 0 \(stateSuffix)"])
            }
            return (next, ["\(head) night=seed value=\(r2(v)) "
                           + "spread starts at floor=\(r2(cfg.floorSpread)) "
                           + "(this ONE night fixes the centre) \(stateSuffix)"])
        }

        guard let value = value else {
            return (next, ["\(head) night=missing skip-and-hold "
                           + "nightsSinceUpdate=\(next.nightsSinceUpdate) \(stateSuffix)"])
        }

        guard cfg.minVal <= value && value <= cfg.maxVal else {
            return (next, ["\(head) night=implausible value=\(r2(value)) "
                           + "bounds=\(r2(cfg.minVal))..\(r2(cfg.maxVal)) skip-and-hold "
                           + "nightsSinceUpdate=\(next.nightsSinceUpdate) \(stateSuffix)"])
        }

        // Same predicate `update` uses: tied to the valid-night count, not to spread.
        let isYoung = state.nValid < earlyAdaptNights

        if rejectHardOutliers && state.nValid >= minNightsSeed && !isYoung {
            let dev = abs(value - state.baseline)
            if dev > hardOutlierK * state.spread {
                return (next, ["\(head) night=rejected value=\(r2(value)) "
                               + "dev=\(r2(dev)) > k=\(r2(hardOutlierK))*spread=\(r2(state.spread)) "
                               + "(seen, NOT folded) \(stateSuffix)"])
            }
        }

        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effHalfLifeB = isYoung ? earlyHalfLifeB : cfg.halfLifeB
        let lo = state.baseline - winsorK * effSpread
        let hi = state.baseline + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let wasClamped = clamped != value
        // `update` floors the spread with max(cfg.floorSpread, ...); report when the floor won.
        let atFloor = next.spread <= cfg.floorSpread

        return (next, ["\(head) night=folded value=\(r2(value)) young=\(yn(isYoung)) "
                       + "effSpread=\(r2(effSpread)) halfLifeB=\(r2(effHalfLifeB)) "
                       + "winsor=\(r2(lo))..\(r2(hi)) clamped=\(yn(wasClamped))"
                       + (wasClamped ? " to=\(r2(clamped))" : "")
                       + " spread \(r2(state.spread))->\(r2(next.spread)) atFloor=\(yn(atFloor)) \(stateSuffix)"])
    }

    /// Replay an ordered history (oldest first) through `updateTrace`, returning the final state and one
    /// line per night; the answer to "how many nights until the spread lifted".
    /// - Parameter tail: keep only the last N lines. The whole history is still folded, so the state is
    ///   unchanged; this only bounds the log. nil keeps every line.
    public static func foldHistoryTrace(_ values: [Double?],
                                        cfg: MetricCfg,
                                        metric: String,
                                        rejectHardOutliers: Bool = true,
                                        tail: Int? = nil) -> (state: BaselineState, lines: [String]) {
        var state: BaselineState? = nil
        var lines: [String] = []
        for v in values {
            let step = updateTrace(state, value: v, cfg: cfg, metric: metric,
                                   rejectHardOutliers: rejectHardOutliers)
            state = step.state
            lines.append(contentsOf: step.lines)
        }
        if let tail = tail, tail >= 0, lines.count > tail {
            let dropped = lines.count - tail
            lines = ["baseline \(metric) (earlier \(dropped) night(s) omitted)"] + lines.suffix(tail)
        }
        guard let final = state else {
            // Empty history: same midpoint seed as foldHistory.
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return (BaselineState(baseline: seed, spread: cfg.floorSpread, nValid: 0,
                                  nightsSinceUpdate: 0,
                                  status: computeStatus(nValid: 0, nightsSinceUpdate: 0)),
                    ["baseline \(metric) history=empty"])
        }
        return (final, lines)
    }

    /// Recalibration-aware fold, traced: `foldHistory(_:dayKeys:cfg:baselineEpoch:)` drops (rather than
    /// skip-and-holds) every night dated before the recalibration epoch, and the `dropped=` line says so
    /// instead of leaving a low nValid to be inferred. `baselineEpoch` is required here (the production
    /// overload reads UserDefaults); the caller passes the pref in to keep this file pure.
    public static func foldHistoryTrace(_ values: [Double?],
                                        dayKeys: [String],
                                        cfg: MetricCfg,
                                        metric: String,
                                        baselineEpoch: Double,
                                        tail: Int? = nil) -> (state: BaselineState, lines: [String]) {
        guard baselineEpoch > 0 else {
            return foldHistoryTrace(values, cfg: cfg, metric: metric, tail: tail)
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        // Filter then fold, as the production loop does night by night; a test pins this against the real function.
        var kept: [Double?] = []
        var dropped = 0
        for (i, v) in values.enumerated() {
            if i < dayKeys.count, let d = fmt.date(from: dayKeys[i]),
               d.timeIntervalSince1970 < baselineEpoch {
                dropped += 1
                continue
            }
            kept.append(v)
        }
        let day = fmt.string(from: Date(timeIntervalSince1970: baselineEpoch))
        let head = "baseline \(metric) recalibrated=\(day) dropped=\(dropped) night(s) before it"
        let out = foldHistoryTrace(kept, cfg: cfg, metric: metric, tail: tail)
        return (out.state, [head] + out.lines)
    }
}
