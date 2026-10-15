import Foundation
import WhoopProtocol   // DeviceFamily (sleepMotionLine)

// Sleep & Rest test-mode diagnostic for the Rest composite. Recomputes the four weighted sub-scores from the
// same inputs as AnalyticsEngine.Rest.composite and reuses Rest.composite for the final value, so the trace
// can never disagree with the score. Pure; counts and ratios only.

/// Where the night behind this day's sleep figures came from (#799). The measured BLE path emits `.measured`;
/// the caller passes `.imported(...)` when an imported row won the daily merge, so the trace shows the import
/// winning instead of silently replacing the measured number. Wire strings: `measured` / `imported:whoop` / `imported:apple`.
public enum SleepProvenance: Equatable, Sendable {
    case measured
    case imported(String)   // source tag, e.g. "whoop" / "apple"

    /// Verbatim provenance token: "measured" or "imported:<source>".
    public var wire: String {
        switch self {
        case .measured: return "measured"
        case .imported(let src): return "imported:\(src)"
        }
    }
}

extension AnalyticsEngine {

    /// Per-day sleep provenance line (#799), emitted right after the Rest sub-score line. `hoursAsleepMin` is total
    /// sleep in minutes (`tstS/60`); `sourceRowId` is a stable id of the winning row (main-night start ts or imported row id).
    public static func sleepProvenanceLine(provenance: SleepProvenance,
                                           hoursAsleepMin: Double,
                                           sourceRowId: String) -> String {
        "sleepProvenance provenance=\(provenance.wire) "
            + "hoursAsleep=\(Int(hoursAsleepMin.rounded())) sourceRowId=\(sourceRowId)"
    }

    /// #1567: pass-level warning that this scoring run has no device registry behind it. Same grammar as Kotlin's
    /// `ownerSourceAbsentLine` but a different cause token (`registry=unavailable` here vs `ownerSource=absent`), since
    /// the platforms reach this state by different routes. An unresolvable family silently becomes WHOOP5, which on a
    /// WHOOP 4.0 reads a raw skin-temp ADC as centidegrees and misses the 28-42 deg C worn gate. Counts and an id only.
    public static func registryUnavailableLine(importedDeviceId: String) -> String {
        "analyzeRecent registry=unavailable owner->\(importedDeviceId) skinTempScale->whoop5"
    }

    /// #319 diagnostic: motion coverage and staging context behind the Rest number, so a high score on a poor night
    /// can be explained from an export. `grav`/`hr` are night-window sample counts; `sparse` is the gravity-sparse gate
    /// (WHOOP 4.0 banks motion coarsely, so most epochs default to sleep and over-count duration); `stager` is the
    /// engine that ran; `family` the day's owner.
    public static func sleepMotionLine(day: String, grav: Int, hr: Int, sparse: Bool,
                                       useSleepStagerV2: Bool, family: DeviceFamily) -> String {
        "sleep-motion day=\(day) grav=\(grav) hr=\(hr) sparse=\(sparse) "
            + "stager=\(useSleepStagerV2 ? "V2" : "V1") family=\(family.rawValue)"
    }

    /// Seconds after detected onset to sample HR for the #271 onset trace; long enough to average out beat noise, early enough that a real onset has already dipped.
    public static let onsetTraceWindowSec: Int = 600

    /// Median of a bpm list: sorted element at count/2 (upper-middle on even counts) so platforms agree; nil when empty.
    public static func medianBpm(_ bpms: [Int]) -> Int? {
        if bpms.isEmpty { return nil }
        let s = bpms.sorted()
        return s[s.count / 2]
    }

    /// #271 diagnostic: the onset decision behind an over-early WHOOP 4.0 bedtime. `hrRatio` = HR at onset (median of
    /// the first `onsetTraceWindowSec`) / the day's median HR; near 1.0 means HR had not dipped when the window opened
    /// (sparse 4.0 motion classifying "lying still, awake" as sleep), whereas a real onset dips well below baseline
    /// (cf. `morningReonsetRestingHRMult` = 0.90).
    public static func sleepOnsetLine(onsetTs: Int, hrAtOnsetBpm: Int, baselineHrBpm: Int) -> String {
        let ratio = baselineHrBpm > 0 ? Double(hrAtOnsetBpm) / Double(baselineHrBpm) : 0.0
        let r2 = (ratio * 100.0).rounded() / 100.0
        return "sleep-onset onsetTs=\(onsetTs) hrAtOnset=\(hrAtOnsetBpm) "
            + "baselineHr=\(baselineHrBpm) hrRatio=\(r2)"
    }
}

extension AnalyticsEngine.Rest {

    /// One Rest sub-score diagnostic line. `groupFragments` / `groupInBedSeconds` describe the main-night group
    /// (#525/#561): blocks bridged into the scored night and their in-bed span. The final `composite=` is
    /// `Rest.composite` verbatim so they can't diverge.
    public static func subScoreLine(tstSeconds: Double, inBedSeconds: Double, efficiency: Double,
                                    restorativeSeconds: Double, needHours: Double,
                                    consistency: Double?, deepSeconds: Double?,
                                    groupFragments: Int, groupInBedSeconds: Double) -> String {
        func r2(_ x: Double) -> Double { (x * 100.0).rounded() / 100.0 }

        // Shared `terms` with `composite`, so the line can't drift from it.
        let t = AnalyticsEngine.Rest.terms(
            tstSeconds: tstSeconds, efficiency: efficiency, restorativeSeconds: restorativeSeconds,
            needHours: needHours, consistency: consistency, deepSeconds: deepSeconds)
        let durationScore = t.duration, efficiencyScore = t.efficiency
        let restorativeScore = t.restorative, deepFactor = t.deepFactor
        // -1 = no regularity signal: term omitted, other weights renormalised.
        let consistencyScore = t.consistency ?? -1
        let composite = AnalyticsEngine.Rest.composite(
            tstSeconds: tstSeconds, inBedSeconds: inBedSeconds, efficiency: efficiency,
            restorativeSeconds: restorativeSeconds, needHours: needHours,
            consistency: consistency, deepSeconds: deepSeconds)

        return "rest composite=\(r2(composite)) "
            + "dur=\(r2(durationScore))*wDur=\(wDuration) "
            + "eff=\(r2(efficiencyScore))*wEff=\(wEfficiency) "
            + "restor=\(r2(restorativeScore))*wRestor=\(wRestorative) deepFactor=\(r2(deepFactor)) "
            + "consist=\(r2(consistencyScore))*wConsist=\(wConsistency) "
            + "group=\(groupFragments) groupInBedMin=\(Int(groupInBedSeconds / 60))"
    }
}
