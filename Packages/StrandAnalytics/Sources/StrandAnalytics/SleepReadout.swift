import Foundation
import WhoopProtocol

// SleepReadout.swift - pure values for the Sleep & Rest live-readout panel.
//
// hrDensityNow and gravityCoverageNow come from the same streams detection reads;
// lastNightGateFired is parsed from the tagged log tail (the gate-trace lines).

public enum SleepReadout {

    /// HR samples per minute over the stream's own span; 0 when fewer than 2 samples.
    public static func hrDensityPerMinute(hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return 0 }
        let sorted = hr.sorted { $0.ts < $1.ts }
        let spanS = Double(sorted.last!.ts - sorted.first!.ts)
        if spanS <= 0 { return 0 }
        return Double(sorted.count) / (spanS / 60.0)
    }

    /// Fraction of the HR window the gravity stream spans, in [0, 1]; the ratio the sparse-gravity gate
    /// (`SleepStager.sparseGravitySpanFrac`) keys on.
    public static func gravityCoverageFraction(gravity: [GravitySample], hr: [HRSample]) -> Double {
        guard gravity.count >= 2, hr.count >= 2 else { return 0 }
        let g = gravity.sorted { $0.ts < $1.ts }
        let h = hr.sorted { $0.ts < $1.ts }
        let hrSpan = Double(h.last!.ts - h.first!.ts)
        if hrSpan <= 0 { return 0 }
        let gravSpan = Double(g.last!.ts - g.first!.ts)
        return max(0.0, min(1.0, gravSpan / hrSpan))
    }

    /// The gate named by the most recent gate-trace line in the tagged tail, or nil
    /// (lines look like "[sleep] gate run=1 ... gate=accepted ...").
    public static func lastGateFired(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() where line.contains("gate=") {
            guard let range = line.range(of: "gate=") else { continue }
            let after = line[range.upperBound...]
            let token = after.prefix { $0 != " " }
            if !token.isEmpty { return String(token) }
        }
        return nil
    }
}

/// Pure values for the Recovery (Charge) and HRV live-readout panels, parsed from the tagged log tail
/// the Recovery / HRV test-mode emitters write.
public enum TestReadout {

    /// The Charge outcome for the MOST RECENT day from the `.recovery`-tagged tail, or nil. Returns the
    /// score/band fragment, or the nil-reason only when the newest day genuinely has none.
    ///
    /// The engine emits days newest-first (and may replay passes), so the last tail line is the OLDEST
    /// window-edge day, routinely a cold-start `nilScore`. Select by the newest `day=` (ISO dates compare
    /// lexicographically), order-independently, preferring the last pass for that day.
    public static func lastChargeBreakdown(taggedTail: [String]) -> String? {
        var bestDay = ""
        var outcome: String?
        for line in taggedTail {
            guard let dr = line.range(of: "day=") else { continue }
            let day = String(line[dr.upperBound...].prefix(10))
            guard day.count == 10, day >= bestDay else { continue }
            let parsed: String?
            if let r = line.range(of: "score=") {
                let upto = line[r.lowerBound...].prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                parsed = upto.isEmpty ? nil : String(upto)
            } else if let r = line.range(of: "nilScore reason=") {
                let token = line[r.upperBound...].prefix { $0 != " " }
                parsed = token.isEmpty ? nil : "no score (\(token))"
            } else {
                parsed = nil   // a baseline/term line for this day carries no outcome — skip it
            }
            guard let parsed else { continue }
            if day > bestDay { bestDay = day }   // a strictly newer day with an outcome resets the winner
            outcome = parsed                     // newest day (or a later pass of it) → its outcome wins
        }
        return outcome
    }

    /// The most recent HRV result fragment from the `.hrv`-tagged tail (rmssd/sdnn, or the nil note when
    /// a gate refused the reading), or nil.
    public static func lastHrvComputation(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "rmssd=") {
                let frag = String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
            if line.contains("result=nil") { return "no reading (filtered out)" }
        }
        return nil
    }
}

/// Pure values for the Steps live-readout panel, parsed from the `.steps`-tagged log tail.
public enum StepsReadout {

    /// The most recent scaled-steps figure in the tagged tail (5/MG "scaledSteps=" or WHOOP-4 "stepsEst"
    /// lines), or nil when none is present yet.
    public static func stepsToday(taggedTail: [String]) -> Int? {
        for line in taggedTail.reversed() {
            if let n = intField(line, key: "scaledSteps=") { return n }
            if line.contains("stepsEst "), let n = intField(line, key: "steps=") { return n }
        }
        return nil
    }

    /// The most recent WHOOP-4 calibration outcome fragment (a fit, or "needsMoreDays" when withheld), or
    /// nil when none is present yet.
    public static func calibrationState(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "stepsCal fit ") {
                let frag = String(line[r.upperBound...]).prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
            if let r = line.range(of: "stepsCal withheld reason=") {
                let frag = String(line[r.upperBound...]).prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return "not calibrated (\(frag))" }
            }
        }
        return nil
    }

    /// Parse a `key=<int>` field out of a line (value runs to the next space); nil when absent or non-numeric.
    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let token = line[r.upperBound...].prefix { $0 != " " }
        return Int(token)
    }
}
