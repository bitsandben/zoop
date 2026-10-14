import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night resolution (pure)
//
// Which stored blocks make up a day's main night, how a stored `stagesJSON` decodes, and the gates
// behind the stage caveats. These are the shared selectors Today, Coupled, the energy bank and the
// analytics rollup also call, so the Sleep screen, the dashboard totals and the edit target always
// resolve the same block. Kept on the screen type because those callers address them as
// `SleepView.mainNightGroup(...)` etc.

extension SleepScreen {

    /// The device's current UTC offset (seconds east), read once per pick. The selector's timing test
    /// uses the same `offsetSec` maths as the engine (`SleepStageTotals.localSecOfDay`).
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single winning block: the durable edit anchor. One real row, no gap bridging, because an
    /// edit writes against exactly one stored session. `habitualMidsleepSec` is the learned value the
    /// engine used, so a shift sleeper resolves the same block the analytics did; nil = cold-start band.
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The winning block plus every adjacent fragment the engine bridges into it, ascending by onset.
    /// A briefly interrupted night therefore reads as one sleep, and only blocks outside it are naps.
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Asleep minutes in blocks outside the main-night group. A stage-less nap contributes nothing
    /// rather than its in-bed window.
    static func napSleepMinutes(_ sessions: [CachedSleepSession],
                                habitualMidsleepSec: Int? = nil) -> Double {
        let mainStarts = Set(mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec).map(\.startTs))
        return sessions
            .filter { !mainStarts.contains($0.startTs) }
            .reduce(0) { $0 + decodedAsleepMinutes($1.stagesJSON, effectiveStartTs: $1.effectiveStartTs) }
    }

    /// The bridged main-night span (onset → wake): the one bed/wake window every glance screen shows.
    static func mainNightSpan(_ sessions: [CachedSleepSession],
                              habitualMidsleepSec: Int? = nil) -> (start: Int, end: Int)? {
        let group = mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let first = group.first, let last = group.last else { return nil }
        return (first.effectiveStartTs, last.endTs)
    }

    // MARK: Pre-onset stubs

    /// Longest leading block that can still be a pre-sleep awake stub (lying in bed before sleep).
    /// Generous because real stubs ran close to three hours; the asleep gate below is the real guard.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still be a sleepless stub.
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A lead carrying some sleep is still spurious when below this share of the night's largest block.
    static let preOnsetStubMinorFrac: Double = 0.15
    /// A lead with at least this much real sleep is a genuine first sleep however long the main block
    /// is; ~20 min is the shortest standalone sleep episode.
    static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Spurious when brief and either essentially sleepless or minor relative to the main block (below
    /// both the relative share and the absolute episode floor). `refAsleepMin` 0 disables the relative test.
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// Index of the fragment that supplies the displayed bedtime: the first non-stub, else 0.
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let refAsleepMin = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: refAsleepMin) { return i }
        }
        return 0
    }

    /// A synthetic session over the main block's window for a day whose blocks decode to no usable
    /// sleep, so the screen still shows that night (and its edit affordance) instead of going blank.
    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    // MARK: Stage decoding

    /// Asleep minutes from either stored format: the on-device segment array or the imported minutes
    /// dict. The onset stub test must read both, or every on-device fragment would read as sleepless.
    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        decodeStages(json)?.asleep
            ?? decodeSegments(json, sessionStart: effectiveStartTs)?.stages.asleep
            ?? 0
    }

    /// The imported minutes dict `{"light","deep","rem","awake"}`.
    static func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func val(_ key: String) -> Double { (dict[key] as? NSNumber)?.doubleValue ?? 0 }
        let s = Stages(awake: val("awake"), light: val("light"), deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// The on-device segment array `[{"start","end","stage"}]` as totals plus a timeline in seconds from
    /// `sessionStart`. Segments are trimmed to `sessionStart`, so a hand-set later bedtime never sums
    /// stages from before it.
    static func decodeSegments(_ json: String?, sessionStart: Int) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(stage: stage, start: TimeInterval(start - sessionStart),
                                           end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    // MARK: Stage caveat gates

    /// Whether the "may be incomplete" caveat applies. Sparse motion alone is a staging-mechanism flag
    /// that also fires on complete nights, so the night must additionally read short of the need.
    static func stageSparseNoteApplies(stagingSparse: Bool,
                                       asleepMin: Double,
                                       needHours: Double = AnalyticsEngine.Rest.defaultNeedHours) -> Bool {
        guard stagingSparse else { return false }
        return asleepMin < needHours * 60.0
    }

    /// A high-efficiency night with an implausibly small deep+REM share: far more likely a staging miss
    /// than a real night without restorative sleep. Built on `ScoreConfidence.rest` so the caveat and
    /// the persisted Rest confidence cannot disagree. Unstaged nights are never flagged.
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                        asleepSeconds: asleepMin * 60.0,
                                        restorativeSeconds: restorativeMin * 60.0,
                                        efficiency: efficiency)
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }
}
