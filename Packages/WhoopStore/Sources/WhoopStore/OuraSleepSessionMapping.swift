import Foundation
import OuraProtocol

/// Maps a reconstructed Oura hypnogram (the anchored per-code stage sequence from
/// `OuraHypnogramAssembler.codesWithTimes`, 30 s epochs) onto a `CachedSleepSession` whose `stagesJSON`
/// uses the same `[{start,end,stage}]` shape as `SleepStager` and the importers (`SleepStageTotals.minutes`).
///
/// The session is stored under the ring's own deviceId (the imported side), so `SleepMerge`'s
/// imported-over-computed rule lets Oura's on-ring staging win over sparse-motion computed staging.
/// This is provider data reshaped, not a Zoop-computed signal.
///
/// `stagesJSON` is built by hand in fixed key order (`start`,`end`,`stage`) so Swift and Kotlin emit
/// byte-identical segment JSON (stored-value contract).
public enum OuraSleepSessionMapping {

    /// Stage token per code, as `SleepStageTotals` decodes: "deep"/"light"/"rem"/"wake".
    static func token(_ stage: OuraSleepStage) -> String {
        switch stage {
        case .deep:  return "deep"
        case .light: return "light"
        case .rem:   return "rem"
        case .awake: return "wake"
        }
    }

    /// Builds a `CachedSleepSession` from the anchored per-code stage sequence (ascending `ts`, one code per
    /// `secondsPerCode`). Adjacent equal stages merge into one segment. `startTs` is the first code's ts,
    /// `endTs` the last code's ts plus one epoch. `efficiency` = asleep / (asleep + awake) as 0-1, nil when
    /// nothing is in bed. Returns nil for an empty sequence. `restingHr`/`avgHrv` stay nil.
    public static func session(fromCodes codes: [(ts: Int, stage: OuraSleepStage)],
                               secondsPerCode: Int = 30) -> CachedSleepSession? {
        guard let first = codes.first, let last = codes.last else { return nil }

        // Merge adjacent equal stages into contiguous segments.
        struct Seg { var start: Int; var end: Int; let stage: OuraSleepStage }
        var segs: [Seg] = []
        for c in codes {
            let segEnd = c.ts + secondsPerCode
            if var lastSeg = segs.last, lastSeg.stage == c.stage, lastSeg.end == c.ts {
                lastSeg.end = segEnd
                segs[segs.count - 1] = lastSeg
            } else {
                segs.append(Seg(start: c.ts, end: segEnd, stage: c.stage))
            }
        }

        // Hand-built JSON in fixed key order for byte-identical output across platforms.
        let json = "[" + segs.map {
            "{\"start\":\($0.start),\"end\":\($0.end),\"stage\":\"\(token($0.stage))\"}"
        }.joined(separator: ",") + "]"

        var asleepSec = 0, awakeSec = 0
        for c in codes {
            if c.stage == .awake { awakeSec += secondsPerCode } else { asleepSec += secondsPerCode }
        }
        let inBedSec = asleepSec + awakeSec
        let efficiency = inBedSec > 0 ? Double(asleepSec) / Double(inBedSec) : nil

        return CachedSleepSession(startTs: first.ts, endTs: last.ts + secondsPerCode,
                                  efficiency: efficiency, restingHr: nil, avgHrv: nil,
                                  stagesJSON: json)
    }
}
