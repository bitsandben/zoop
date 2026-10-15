import Foundation
import WhoopProtocol

// StepsEstimateEngine+Trace: the Steps test-mode diagnostic traces. Pure, no clock/I/O/PII (counts and
// ratios only); each call is gated behind TestCentre.active(.steps) at the call site.
//
// calibrationTrace: the WHOOP-4 motion-volume path, reusing StepsEstimateEngine.calibrate VERBATIM so it
// cannot disagree with the coefficient the Steps screen shows.
// rawCounterTrace: the WHOOP 5/MG raw path, with the same maxStepDelta gate and ticks-per-step scaling as
// AnalyticsEngine.analyzeDay so it cannot diverge from the daily steps_est value.

extension StepsEstimateEngine {

    /// The WHOOP-4 calibration trace: one `stepsCal point` line per usable day (motion volume, phone reference
    /// count, implied ratio), then the outcome from `calibrate(...)` or the `status(...)` line naming why the
    /// fit was withheld.
    public static func calibrationTrace(points: [CalibrationPoint],
                                        manualOverride: Double? = nil) -> [String] {
        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        var lines: [String] = []

        // Same filter the fit applies, so the trace shows exactly the days that voted.
        let usable = points.filter(isUsableCalibrationPoint)
        for p in usable {
            let ratio = p.motion > 0 ? p.steps / p.motion : 0
            lines.append("stepsCal point motion=\(r2(p.motion)) phoneRef=\(Int(p.steps)) "
                + "ratio=\(r2(ratio)) (steps/motion votes weighted by motion)")
        }

        // Read from calibrate(...) verbatim so it matches the stored coefficient.
        if let cal = calibrate(points, manualOverride: manualOverride), usable.count >= minCalibrationDays || cal.manual {
            let source = cal.manual ? "user-set k" : "k = motion-weighted median of steps/motion"
            lines.append("stepsCal fit k=\(r2(cal.coefficient)) sampleDays=\(cal.sampleDays) "
                + "confidence=\(r2(cal.confidence)) manual=\(cal.manual) "
                + "(\(source))")
        } else {
            // Withheld: name the status the tile shows, via status(...) with the same usable-day filter.
            let status = self.status(points, manualOverride: manualOverride)
            switch status {
            case let .needsMoreDays(have, need):
                lines.append("stepsCal withheld reason=needsMoreDays have=\(have) need=\(need) "
                    + "(no usable auto-fit and no manual k)")
            case let .manual(k, sampleDays):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=1.0 manual=true (user-set k)")
            case let .calibrated(k, sampleDays, confidence):
                lines.append("stepsCal fit k=\(r2(k)) sampleDays=\(sampleDays) "
                    + "confidence=\(r2(confidence)) manual=false (k = motion-weighted median of steps/motion)")
            }
        }
        return lines
    }

    /// The WHOOP 5/MG raw-counter trace for one day: recomputes the wrap-aware sum `analyzeDay` runs over the
    /// cumulative `step_motion_counter` (kept/dropped delta counts, raw ticks, scaled steps), so it matches
    /// the daily `steps_est`. `daySteps` may be in any order; the filter is by local `dayKey`.
    public static func rawCounterTrace(daySteps: [StepSample],
                                       dayKey: String,
                                       tzOffsetSeconds: Int,
                                       ticksPerStep: Double) -> [String] {
        // Same maxStepDelta gate as analyzeDay.
        let maxStepDelta = 512

        // Same filter + sort: this local day's samples, time-ordered.
        let sorted = daySteps
            .filter { AnalyticsEngine.dayString($0.ts, offsetSec: tzOffsetSeconds) == dayKey }
            .sorted { $0.ts < $1.ts }

        var lines: [String] = []
        // #810: a WHOOP 4.0 sends no raw step counter over BLE, so `daySteps` is empty and its steps are
        // motion-estimated; say so rather than emit a line that reads as a fault.
        if daySteps.isEmpty {
            lines.append("stepsRaw day=\(dayKey) counterSamples=0 noRawCounter "
                + "(no step counter on this device; steps are motion-estimated, e.g. WHOOP 4.0)")
            return lines
        }
        // Non-empty input proves a counter exists; rows all outside the local day is only a window mismatch.
        if sorted.isEmpty {
            lines.append("stepsRaw day=\(dayKey) counterSamples=0 inputSamples=\(daySteps.count) noRowsForDay "
                + "(no counter rows matched the requested local day)")
            return lines
        }
        guard sorted.count >= 2 else {
            lines.append("stepsRaw day=\(dayKey) counterSamples=\(sorted.count) (need >=2 for a delta)")
            return lines
        }

        // Wrap-aware deltas exactly as the production sum.
        var rawTotal = 0
        var keptDeltas = 0
        var droppedDeltas = 0
        var minDelta = Int.max
        var maxDelta = Int.min
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
            if delta >= 1 && delta < maxStepDelta {
                rawTotal += delta
                keptDeltas += 1
                minDelta = Swift.min(minDelta, delta)
                maxDelta = Swift.max(maxDelta, delta)
            } else if delta >= maxStepDelta {
                droppedDeltas += 1   // a sync-gap / reboot boundary, not real steps (>= 512)
            }
        }

        let firstCounter = sorted.first!.counter
        let lastCounter = sorted.last!.counter
        lines.append("stepsRaw day=\(dayKey) counterSamples=\(sorted.count) "
            + "firstCounter=\(firstCounter) lastCounter=\(lastCounter) (cumulative u16 @57)")
        lines.append("stepsRaw deltas kept=\(keptDeltas) dropped=\(droppedDeltas) "
            + "(dropped = delta>=\(maxStepDelta), a sync-gap/reboot boundary)")
        if keptDeltas > 0 {
            lines.append("stepsRaw keptRange min=\(minDelta) max=\(maxDelta) "
                + "(each = (cur-prev)&0xFFFF, wrap-aware)")
        }

        // Same expression as analyzeDay's steps_est; ticksPerStep floored at 0.5 so a bad pref can at most double it.
        let scaled = rawTotal > 0
            ? Int((Double(rawTotal) / Swift.max(ticksPerStep, 0.5)).rounded())
            : 0
        // analyzeDay returns nil for a total that rounds to 0, so render "none" rather than a measured zero.
        let scaledText = scaled > 0 ? String(scaled) : "none"
        lines.append("stepsRaw total rawTicks=\(rawTotal) ticksPerStep=\((ticksPerStep * 100).rounded() / 100) "
            + "scaledSteps=\(scaledText) (steps_est for the day)")
        return lines
    }
}
