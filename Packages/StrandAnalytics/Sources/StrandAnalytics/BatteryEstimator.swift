import Foundation

/// Battery runtime estimate ("~X days left") from the strap's banked SoC history (#713). Fits the
/// recent discharge slope and divides the current charge by it; when the discharge run is too short or
/// flat, falls back to the typical full-charge life for the generation. The measured slope already
/// reflects how the user runs the strap, so there are no usage multipliers. Drain is non-linear and
/// SoC is sparse, so this is an estimate. Pure, no I/O.
public enum BatteryEstimator {

    // MARK: - Rated full-charge life (the cold-start fallback)

    /// Typical full-charge life (hours) per generation, used before enough discharge is seen to fit a
    /// slope: WHOOP 4.0 about 4.5 days, 5.0 / MG about 12 days (#713). The caller maps its strap to one.
    public static let ratedLifeHoursWhoop4: Double = 108   // 4.5 days
    public static let ratedLifeHoursWhoop5: Double = 288   // 12 days

    /// A discharge run must span at least this long and drop at least this much before its measured slope
    /// is trusted over the rated fallback; short spans give wild rates.
    public static let minSpanHours: Double = 2.0
    public static let minDropPct: Double = 2.0

    /// A SoC rise larger than this (percentage points) between consecutive readings marks a charge; the
    /// discharge run restarts after it so no rate is fitted across a charge.
    public static let chargeStepPct: Double = 1.0

    /// A charge anchors a fresh discharge run only when it returns the strap near full (#8). A partial
    /// top-up (40% to 55%) used to reset the run and inflate "days left" off the short tail; it is now
    /// stepped over and the fit prefers the longer pre-top-up segment.
    public static let nearFullPct: Double = 90.0

    // MARK: - Output

    /// Where the drain rate came from: measured discharge or the rated fallback.
    public enum Source: String, Equatable, Sendable { case measured, rated }

    public struct Estimate: Equatable, Sendable {
        /// Estimated hours of runtime left at the latest reading (time to 0%).
        public let remainingHours: Double
        public let source: Source
        /// The latest SoC the estimate is anchored to, in percent.
        public let currentSoc: Double

        public init(remainingHours: Double, source: Source, currentSoc: Double) {
            self.remainingHours = remainingHours
            self.source = source
            self.currentSoc = currentSoc
        }

        /// The days figure.
        public var daysRemaining: Double { remainingHours / 24 }
        /// Alias for `remainingHours`.
        public var hoursRemaining: Double { remainingHours }
    }

    // MARK: - Estimate

    /// Estimate remaining runtime from a SoC series.
    /// - Parameters:
    ///   - samples: `(unix-seconds, SoC%)` pairs in any order; the caller drops nil-SoC rows.
    ///   - ratedHours: typical full-charge life, one of the `ratedLifeHours...` constants.
    /// - Returns: an estimate, or nil when there is no reading to anchor to.
    public static func estimate(samples: [(ts: Int, soc: Double)], ratedHours: Double) -> Estimate? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let last = sorted.last else { return nil }
        let current = last.soc

        // The discharge segment to fit: anchored at the most recent near-full charge and ending before any
        // later partial top-up (#8).
        let run = dischargeFitWindow(sorted)

        // Simple endpoints rate (%/h): the series is short and near-monotone within a segment, so endpoints
        // match least-squares at lower cost. nil when too short, too flat or not discharging. The estimate
        // stays anchored to `current` even when the fit window ends earlier.
        let measuredRate: Double? = {
            guard run.count >= 2, let first = run.first, let lastRun = run.last else { return nil }
            let spanHours = Double(lastRun.ts - first.ts) / 3600.0
            let drop = first.soc - lastRun.soc
            guard spanHours >= minSpanHours, drop >= minDropPct else { return nil }
            let rate = drop / spanHours
            return rate > 0 ? rate : nil
        }()

        let rate = measuredRate ?? (100.0 / max(ratedHours, 1))
        let remaining = max(0, current) / rate
        // Cap scaled to the current SoC, not a flat multiple of the full rated life (#99): a too-slow measured
        // slope at low charge (idle spans, sparse 5/MG SoC) extrapolated 9% to ~3 days. The per-% runtime
        // cannot realistically stretch past ~1.5x rated.
        let clamped = min(remaining, ratedHours * 1.5 * (max(0, current) / 100.0))
        return Estimate(remainingHours: clamped,
                        source: measuredRate != nil ? .measured : .rated,
                        currentSoc: current)
    }

    /// The slice of the sorted SoC series to fit the discharge slope on (#8):
    /// 1. Start at the most recent near-full charge (a rise > chargeStepPct landing at >= nearFullPct).
    ///    Partial top-ups are not anchors and are stepped over; with no near-full charge, start = 0.
    /// 2. End before the most recent partial top-up after the start anchor, so the fit uses the longer
    ///    pre-top-up segment.
    /// `current` is taken from the series end, not this window, so trimming the tail changes only the slope.
    static func dischargeFitWindow(_ sorted: [(ts: Int, soc: Double)]) -> [(ts: Int, soc: Double)] {
        guard sorted.count >= 2 else { return sorted }

        // Most recent near-full charge anchors the run start; partial top-ups are stepped over.
        var startIdx = 0
        for i in stride(from: sorted.count - 1, through: 1, by: -1)
        where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
            startIdx = i
            break
        }

        // With no near-full (>=90%) charge to anchor on (#919; common on a 12-day WHOOP 5.0), anchor at the
        // highest SoC (top of the most recent discharge) rather than the oldest reading, which can sit below a
        // later charge and net to a non-discharge window stuck on `rated`. The max is >= every later reading,
        // so the window can only discharge; the minDropPct gate still rejects a flat run. Takes the last
        // occurrence of the max.
        // The search is bounded to the last two charge-step cycles (#99); scanning the whole buffer let a
        // strap that tops up short of full daily anchor on a peak several cycles back and flatten the slope.
        if startIdx == 0 {
            var chargeStepIdxs: [Int] = []
            for i in 1..<sorted.count where sorted[i].soc > sorted[i - 1].soc + chargeStepPct {
                chargeStepIdxs.append(i)
            }
            let searchFloor = chargeStepIdxs.count >= 2 ? chargeStepIdxs[chargeStepIdxs.count - 2] : 0
            var maxIdx = searchFloor
            for i in searchFloor..<sorted.count where sorted[i].soc >= sorted[maxIdx].soc { maxIdx = i }
            startIdx = maxIdx
        }

        // End before the most recent partial top-up after the start anchor, so the fit uses the longer pre-top-up segment.
        var endIdx = sorted.count - 1
        if endIdx - startIdx >= 1 {
            for i in stride(from: sorted.count - 1, through: startIdx + 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc < nearFullPct {
                endIdx = i - 1
                break
            }
        }
        guard endIdx > startIdx else { return Array(sorted[startIdx...]) }
        return Array(sorted[startIdx...endIdx])
    }

    /// Diagnostic twin of `estimate`: the same `Estimate` plus trace lines describing the (t, soc) series,
    /// detected charge steps, trailing discharge run start/span/drop, fitted slope, and which gate
    /// (minSpanHours / minDropPct) chose measured vs rated. Gated by the caller on TestCentre.active(.battery).
    /// Pure.
    public static func estimateTrace(samples: [(ts: Int, soc: Double)], ratedHours: Double)
        -> (estimate: Estimate?, trace: [String]) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let last = sorted.last, let first0 = sorted.first else {
            return (nil, ["battery series=0 readings, no reading to anchor to"])
        }
        var lines: [String] = []
        lines.append("battery series=\(sorted.count) readings span \(first0.ts)..\(last.ts)s")
        for s in sorted { lines.append("battery read t=\(s.ts)s soc=\(socText(s.soc))") }

        // Most recent near-full charge anchors the run start (same scan as estimate); a partial top-up does not.
        var startIdx = 0
        if sorted.count >= 2 {
            for i in stride(from: sorted.count - 1, through: 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
                startIdx = i
                let rise = sorted[i].soc - sorted[i - 1].soc
                lines.append("battery chargeStep at t=\(sorted[i].ts)s +\(socText(rise))pp "
                    + "(>chargeStepPct \(socText(chargeStepPct)))")
                break
            }
        }
        // Most recent partial top-up after the anchor: the fit ends before it (#8).
        if sorted.count >= 2, startIdx < sorted.count - 1 {
            for i in stride(from: sorted.count - 1, through: startIdx + 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc < nearFullPct {
                let rise = sorted[i].soc - sorted[i - 1].soc
                lines.append("battery partialTopUp at t=\(sorted[i].ts)s +\(socText(rise))pp "
                    + "(<nearFullPct \(socText(nearFullPct))) -> fit pre-top-up segment")
                break
            }
        }
        let run = dischargeFitWindow(sorted)

        var spanPass = false
        var dropPass = false
        if run.count >= 2, let runFirst = run.first, let runLast = run.last {
            let spanHours = Double(runLast.ts - runFirst.ts) / 3600.0
            let drop = runFirst.soc - runLast.soc
            lines.append("battery dischargeRun start=\(runFirst.ts)s "
                + "span=\(hoursText(spanHours))h drop=\(socText(drop))pp")
            spanPass = spanHours >= minSpanHours
            dropPass = drop >= minDropPct
            if spanPass && dropPass && drop / spanHours > 0 {
                lines.append("battery slope=\(slopeText(drop / spanHours))pct/h fitted from run endpoints")
            }
        } else {
            lines.append("battery dischargeRun too short to fit (run=\(run.count) readings)")
        }

        let measured = spanPass && dropPass && run.count >= 2
            && (run.first!.soc - run.last!.soc) / (Double(run.last!.ts - run.first!.ts) / 3600.0) > 0
        lines.append("battery gate minSpanHours \(hoursText(minSpanHours)) "
            + "\(spanPass ? "PASS" : "FAIL"), minDropPct \(socText(minDropPct)) "
            + "\(dropPass ? "PASS" : "FAIL") -> source=\(measured ? "measured" : "rated")")

        return (estimate(samples: samples, ratedHours: ratedHours), lines)
    }

    private static func socText(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func hoursText(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func slopeText(_ v: Double) -> String { String(format: "%.1f", v) }

    /// Display rule (#713): hours under 48h ("~14h"), days above ("~4.5 days"). Unit text only; the caller
    /// adds the "left" copy. Locale-free; the UI localises the number.
    public static func label(hours: Double) -> String {
        if hours < 48 { return "~\(Int(hours.rounded()))h" }
        return "~\(String(format: "%.1f", hours / 24)) days"
    }

    // MARK: - Predictive low-battery alert policy

    /// Fire the runtime alert at this many hours of remaining life. A fixed SoC threshold gives very
    /// different lead time per generation (15% is ~16 h on a 4.0, ~1.8 days on a 5.0/MG); a runtime
    /// threshold gives the same "charge it tonight" warning for both.
    public static let runtimeAlertHours: Double = 24
    /// Re-arm when the estimate recovers to this; the 12 h hysteresis band stops slope-fit jitter from re-firing.
    public static let runtimeRearmHours: Double = 36

    /// Crossing-with-hysteresis decision for the predictive alert, shaped like
    /// `BatteryNotifier.BatteryAlertPolicy.evaluate`: persisted `alerted` gate in, fire decision and next
    /// gate out. `charging == nil` means unknown and still fires (only a confirmed `true` suppresses),
    /// since the strap reports its charge bit only every ~8 min.
    public static func runtimeAlert(remainingHours: Double,
                                    charging: Bool?,
                                    alerted: Bool) -> (fire: Bool, newAlerted: Bool) {
        var armedOff = alerted
        if remainingHours >= runtimeRearmHours { armedOff = false }
        let fire = !armedOff && remainingHours <= runtimeAlertHours && charging != true
        if fire { armedOff = true }
        return (fire, armedOff)
    }

    // MARK: - The ~10% hardware cutoff

    /// The strap stops sampling and drops the link near this SoC, not at 0%. Measured on a WHOOP 5.0
    /// with R22 deep-data and high-rate IMU capture: SoC ran 13.1% to 10.9% over 80 min, the last HR sample
    /// landed 27 min after the 10.9% reading, and nothing below 10.9% was ever banked.
    ///
    /// `estimate` divides the full current SoC by the drain rate, so `remainingHours` is time to 0% and
    /// overstates usable life by `cutoffSocPct / rate`. Anything asking whether the strap will survive N
    /// hours must use `usableRemainingHours(...)`, not `Estimate.remainingHours`. Not folded into `estimate`
    /// because that value feeds the displayed badge and shared fixtures.
    public static let cutoffSocPct: Double = 10.0

    /// Runtime left before the strap goes dark at `cutoffSocPct`: `(currentSoc - cutoff) / rate` with
    /// `rate = currentSoc / remainingHours`, rearranged so the rate is never recovered explicitly. The #99
    /// clamp only lowers `remainingHours`, so the result can only be pessimistic. 0 at or below the cutoff.
    public static func usableRemainingHours(remainingHours: Double, currentSoc: Double) -> Double {
        guard currentSoc > 0, remainingHours > 0 else { return 0 }
        return max(0, remainingHours * (currentSoc - cutoffSocPct) / currentSoc)
    }

    /// `usableRemainingHours` for a whole `Estimate`.
    public static func usableRemainingHours(_ estimate: Estimate) -> Double {
        usableRemainingHours(remainingHours: estimate.remainingHours, currentSoc: estimate.currentSoc)
    }

    // MARK: - Critical low-battery alert (the escalation the 15% alert can't give)

    /// SoC at which the critical "charge it now" alert fires: a second crossing below
    /// `BatteryNotifier.BatteryAlertPolicy.lowThreshold` (15%) with its own gate.
    /// Derived from `cutoffSocPct`: the strap goes dark at ~10%, so the usable alert band is (10%, 15%].
    /// 5% is unreachable and 10% a coin flip (lowest banked reading 10.9%, SoC arrives already rounded).
    /// 12% sits mid-band, was reliably reported, and clears the 15% line by 3 pp so it is a separate crossing.
    /// Lead time scales with drain: ~1.2 h at 1.65 %/h (R22 + high-rate IMU), ~5.7 h at 0.35 %/h.
    public static let criticalSocPct = 12

    /// Re-arms on the same recovery as the 15% alert (`BatteryAlertPolicy.lowRearmAbove` = 25) so one charge
    /// re-arms both; its own constant keeps the policies independently tunable.
    public static let criticalRearmAbovePct = 25

    /// Crossing-with-hysteresis decision for the critical low alert: persisted gate in, fire decision and
    /// next gate out. A separate policy with its own flag because the failure it fixes is the latch: the 15%
    /// alert sets `lowAlerted` until SoC recovers to 25%, so the user got one warning and then silence for
    /// ~3 h to the cutoff. `charging == nil` still fires; only a confirmed `true` suppresses.
    public static func criticalAlert(pct: Int,
                                     charging: Bool?,
                                     alerted: Bool) -> (fire: Bool, newAlerted: Bool) {
        var armedOff = alerted
        if pct >= criticalRearmAbovePct { armedOff = false }
        let fire = !armedOff && pct <= criticalSocPct && charging != true
        if fire { armedOff = true }
        return (fire, armedOff)
    }

    // MARK: - Bedtime night-guard ("this won't last the night")

    /// How long before habitual bedtime the night-guard window opens: wide enough for several ~8-minute
    /// battery readings and for the user to act, narrow enough to be about tonight.
    public static let bedtimeLeadHours: Double = 3.0

    /// Safety margin on top of waiting until bedtime plus tonight's sleep; covers slope-fit error and long nights.
    public static let bedtimeMarginHours: Double = 1.0

    /// Floor on the nights behind `typicalSleepHours`, so the duration median is never taken off a night or two.
    /// (The midsleep learner's own `SleepStageTotals.habitualMinDays` (14) already gates the night guard.)
    public static let bedtimeMinNights = 7

    /// What tonight demands of the strap versus what it has, so the notifier can word the alert from real numbers.
    public struct NightRunway: Equatable, Sendable {
        public let hoursUntilBedtime: Double
        public let sleepHours: Double
        /// `hoursUntilBedtime + sleepHours + bedtimeMarginHours`.
        public let requiredHours: Double
        /// Cutoff-aware runtime (`usableRemainingHours`), not the raw time-to-0% estimate.
        public let usableHours: Double

        public init(hoursUntilBedtime: Double, sleepHours: Double,
                    requiredHours: Double, usableHours: Double) {
            self.hoursUntilBedtime = hoursUntilBedtime
            self.sleepHours = sleepHours
            self.requiredHours = requiredHours
            self.usableHours = usableHours
        }

        /// Hours the strap falls short; 0 when it makes it.
        public var shortfallHours: Double { max(0, requiredHours - usableHours) }
    }

    /// Typical night length (hours): the median of the recent nightly durations from
    /// `IntelligenceEngine.computeHabitualSleep` (longest block per local day, so naps drop out). Median so
    /// one all-nighter or one dead-strap night cannot shrink the budget. nil under `minNights`.
    public static func typicalSleepHours(nightlyHours: [Double],
                                         minNights: Int = bedtimeMinNights) -> Double? {
        let valid = nightlyHours.filter { $0 > 0 }
        guard valid.count >= minNights else { return nil }
        let sorted = valid.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Decide whether to warn, before bed, that the strap won't survive the night. Independent of the 24 h
    /// runtime and 15% SoC alerts, which latch and then stay silent through the final descent. Bedtime is
    /// derived from the learned sleep model (`habitualMidsleepSec` minus half the typical night, #547), not
    /// a fixed clock band, which would misfire for shift and late sleepers.
    /// - Parameters:
    ///   - nowSecOfDay: local time-of-day seconds in [0, 86400).
    ///   - habitualMidsleepSec: learned midsleep as local seconds-of-day; nil at cold start (< 14 nights).
    ///   - typicalSleepHours: from `typicalSleepHours(nightlyHours:)`; nil at cold start.
    ///   - usableRemainingHours: cutoff-aware runtime; nil with no estimate.
    ///   - alerted: the persisted once-per-night gate.
    public static func bedtimeAlert(nowSecOfDay: Int,
                                    habitualMidsleepSec: Int?,
                                    typicalSleepHours: Double?,
                                    usableRemainingHours: Double?,
                                    charging: Bool?,
                                    alerted: Bool)
        -> (fire: Bool, newAlerted: Bool, runway: NightRunway?) {
        // Cold start: with no learned midsleep or duration history there is no honest bedtime, and a fixed
        // 23:00 would misfire for late sleepers. Stay silent and leave the gate untouched.
        guard let midsleep = habitualMidsleepSec,
              let sleepHours = typicalSleepHours,
              sleepHours > 0,
              (0..<secondsPerDay).contains(midsleep),
              (0..<secondsPerDay).contains(nowSecOfDay) else {
            return (false, alerted, nil)
        }
        let bedtimeSec = self.bedtimeSec(midsleepSec: midsleep, sleepHours: sleepHours)
        let hoursUntilBedtime = Double(floorMod(bedtimeSec - nowSecOfDay, secondsPerDay)) / 3600.0
        // Outside the pre-bed window (including when `hoursUntilBedtime` wraps to ~24 after bedtime) the gate
        // re-arms, which makes this once per night: each evening's window is a fresh crossing.
        guard hoursUntilBedtime <= bedtimeLeadHours else { return (false, false, nil) }
        // No estimate yet: nothing to judge; hold the gate.
        guard let usable = usableRemainingHours else { return (false, alerted, nil) }
        // The strap must survive the wait until bedtime and the night itself, plus the margin. Anchoring to
        // `hoursUntilBedtime` rather than a flat `sleepHours` keeps the whole lead window honest.
        let required = hoursUntilBedtime + sleepHours + bedtimeMarginHours
        let runway = NightRunway(hoursUntilBedtime: hoursUntilBedtime, sleepHours: sleepHours,
                                 requiredHours: required, usableHours: usable)
        let fire = !alerted && usable < required && charging != true
        // Charging suppression must not consume the gate: unplug inside the window and the alert can still fire.
        return (fire, fire ? true : alerted, runway)
    }

    /// Half the typical night in whole seconds (midsleep to bedtime, and to wake). The one place that
    /// rounding lives, so `bedtimeSec` and `NightStandDown.band` agree. Callers guard `sleepHours > 0`.
    public static func halfNightSec(sleepHours: Double) -> Int {
        Int((sleepHours * 1800).rounded())
    }

    /// Learned bedtime as local seconds-of-day: midsleep minus half the typical night, circular so a 03:30
    /// midsleep on an 8 h night is 23:30. Shared by `bedtimeAlert` and `NightStandDown.band` so they cannot
    /// disagree about when the night starts.
    public static func bedtimeSec(midsleepSec: Int, sleepHours: Double) -> Int {
        floorMod(midsleepSec - halfNightSec(sleepHours: sleepHours), secondsPerDay)
    }

    private static let secondsPerDay = 86_400

    /// Floored modulo, correct for negative operands (bedtime arithmetic wraps midnight both ways).
    private static func floorMod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r < 0 ? r + n : r
    }
}
