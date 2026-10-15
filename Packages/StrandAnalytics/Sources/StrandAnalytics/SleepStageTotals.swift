import Foundation

/// Decode a sleep session's `stagesJSON` (the on-device segment array `[{start,end,stage}]` or the
/// imported minute dict `{light,deep,rem,awake}`) into stage MINUTE totals, and aggregate a night's
/// blocks into the sleep-derived daily fields. Pure, so the daily recompute after a wake-time edit
/// can run off stored (reshaped) stages without raw streams.
public enum SleepStageTotals {

    public struct Minutes: Equatable {
        public var awake: Double, light: Double, deep: Double, rem: Double
        public var asleep: Double { light + deep + rem }
        public var inBed: Double { asleep + awake }
        public init(awake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
            self.awake = awake; self.light = light; self.deep = deep; self.rem = rem
        }
    }

    /// Stage minutes for one session's `stagesJSON`, or nil if nothing usable decodes. The on-device
    /// stager says "wake", the importer "awake"; both map to `awake`.
    public static func minutes(fromStagesJSON json: String?) -> Minutes? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {                 // segment array (computed)
            var m = Minutes()
            for seg in arr {
                guard let s = (seg["start"] as? NSNumber)?.intValue,
                      let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                      let name = seg["stage"] as? String else { continue }
                let mins = Double(e - s) / 60.0
                switch name {
                case "wake", "awake": m.awake += mins
                case "light": m.light += mins
                case "deep": m.deep += mins
                case "rem": m.rem += mins
                default: continue
                }
            }
            return m.inBed > 0 ? m : nil
        }
        if let dict = obj as? [String: Any] {                  // minute dict (imported)
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            let m = Minutes(awake: v("awake"), light: v("light"), deep: v("deep"), rem: v("rem"))
            return m.inBed > 0 ? m : nil
        }
        return nil
    }

    /// Return `stagesJSON` with its `[{start,end,stage}]` segments trimmed to begin no earlier than
    /// `onsetSec` (earlier segments dropped, a straddling one cut to `[onsetSec, end]`). The imported
    /// `{stage:min}` shape and unparseable JSON are returned UNCHANGED, as is input already starting at/after
    /// the onset.
    public static func clampStagesToOnset(_ stagesJSON: String?, onsetSec: Int) -> String? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return stagesJSON   // dict/imported shape or unparseable → unchanged
        }
        var out: [[String: Any]] = []
        for seg in arr {
            // Shape check is start+end only: a {stage:min} entry has neither, so bail unchanged. A segment
            // missing only `stage` defaults to "" (minutes() ignores it).
            guard let rawS = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue else { return stagesJSON }
            let name = seg["stage"] as? String ?? ""
            let s = max(rawS, onsetSec)
            guard e > s else { continue }                                        // fully before the onset → drop
            out.append(["start": s, "end": e, "stage": name])
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: out),
              let str = String(data: outData, encoding: .utf8) else { return stagesJSON }
        return str
    }

    /// The sleep-derived daily fields for a night made of these blocks' `stagesJSON`, or nil if none
    /// decode. `efficiency` is asleep / in-bed in [0,1]. Zoop's segment stages tile the window, so Σ stage
    /// minutes equals the clock span and this matches `AnalyticsEngine.analyzeDay`'s TST/(end−start);
    /// they would diverge only for malformed non-tiling stages.
    public struct DailySleep: Equatable {
        public let totalSleepMin: Double, efficiency: Double
        public let deepMin: Double, remMin: Double, lightMin: Double
    }

    public static func dailyAggregate(_ stagesJSONs: [String?]) -> DailySleep? {
        dailyAggregate(stagesJSONs, interFragmentAwakeSeconds: 0)
    }

    /// As `dailyAggregate(_:)`, but folds the out-of-bed time between bridged main-night fragments into the
    /// night's AWAKE total (and so its in-bed denominator). A main sleep bridged across a 20-min wake gap
    /// must show ~20 min awake, not lose it: the fragments' stages tile only their own spans. The caller
    /// computes the gap once and passes it so the analytics rollup and the edit/recompute seam share one
    /// definition. `interFragmentAwakeSeconds` ≤ 0 reproduces plain sum-of-stages.
    public static func dailyAggregate(_ stagesJSONs: [String?],
                                      interFragmentAwakeSeconds: Double) -> DailySleep? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        if interFragmentAwakeSeconds > 0 { total.awake += interFragmentAwakeSeconds / 60.0 }
        guard any, total.inBed > 0 else { return nil }
        return DailySleep(totalSleepMin: total.asleep, efficiency: total.asleep / total.inBed,
                          deepMin: total.deep, remMin: total.rem, lightMin: total.light)
    }

    /// Out-of-bed seconds BETWEEN consecutive bridged sleep fragments (each an `(start,end)` span). Sorted by
    /// start, the gap after fragment i is `max(0, start[i+1] - end[i])`; overlapping/abutting fragments
    /// contribute 0. The single shared definition of awake-between-fragments for `analyzeDay` and the
    /// edit/recompute seam, so they never double-count.
    public static func interFragmentAwakeSeconds(_ spans: [(start: Int, end: Int)]) -> Double {
        guard spans.count > 1 else { return 0 }
        let sorted = spans.sorted { $0.start < $1.start }
        var gap = 0
        for i in 1..<sorted.count {
            let g = sorted[i].start - sorted[i - 1].end
            if g > 0 { gap += g }
        }
        return Double(gap)
    }

    // MARK: - Canonical main-night selection

    /// Local hour (inclusive) opening the cold-start overnight band [`overnightStartHour`,
    /// `overnightEndHour`), used ONLY for the alignment bonus (not a gate). Matches the detector's
    /// `SleepStager.isOvernightOnset` window [20:00, 11:00) so selector and detector agree.
    public static let overnightStartHour = 20
    /// Local hour (exclusive) closing the cold-start overnight band. An onset in
    /// [`overnightEndHour`, `overnightStartHour`) is daytime.
    public static let overnightEndHour = 11

    public static let secondsPerDay = 86_400

    /// Alignment credit (MINUTES) added to a block's asleep minutes when its midpoint sits on the habitual
    /// midsleep (or, cold-start, the overnight band center). A bonus, not a gate: a genuine 7 h daytime
    /// sleep still beats a 1.5 h overnight fragment, while a normal 4 h night beats a longer daytime nap.
    public static let alignmentBonusMin: Double = 90.0

    /// Full bonus within this many seconds (circular) of the habitual midsleep, then linear decay to 0 at
    /// `alignmentZeroSec`.
    public static let alignmentFullWindowSec = 2 * 3_600
    public static let alignmentZeroSec = 5 * 3_600

    /// Runs separated by a wake gap shorter than this (minutes) are bridged into one block for selection,
    /// so a briefly-interrupted main sleep is scored as one night. The detector already bridges
    /// sparse-gravity gaps up to 90 min (`SleepStager.sparseBridgeGapMin`); this is the selector backstop.
    public static let gapBridgeMaxMin = 60

    /// Wider wake-gap bridge (minutes) applied ONLY to an overnight night-tail fragment, so one overnight
    /// sleep with a longer mid-night wake isn't split into a nap + a main sleep (#861). Mirrors
    /// `SleepStager.nightContinuationGapMin`. Used in `mainNightGroupIndices` only when the later
    /// fragment's onset is in the overnight band, so a daytime nap is never folded in.
    public static let nightTailBridgeMaxMin = 90

    /// One candidate block for main-night selection. `start` is the EFFECTIVE onset (a user wake/bed edit
    /// moves `end`, never the detected onset key); `tzOffsetSeconds` makes it local for the timing test.
    public struct NightBlock {
        public let start: Int, end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationS: Int { end - start }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    // MARK: - Selection reason

    /// Why the selector chose the block it did, derived from the exact signals the score used so the UI
    /// can explain the pick without re-deriving anything.
    public enum MainNightReason: String, Equatable {
        /// The day has a single sleep block, so there is nothing to choose between.
        case onlyBlock
        /// Longest by asleep duration with no meaningful timing credit; duration alone decided it.
        case longest
        /// Longest by asleep duration AND it earned a meaningful alignment bonus (learned habitual midsleep
        /// exists and the midpoint is inside the bonus window).
        case longestNearUsual
        /// NOT the longest; the alignment bonus flipped the pick toward this block.
        case alignedToUsual
    }

    /// A bonus is meaningful when it is positive (midpoint inside the window, circular distance <
    /// `alignmentZeroSec`). The epsilon keeps floating-point noise at the edge from counting as credit.
    static let meaningfulBonusEpsilon: Double = 1e-9

    /// Main-night selection plus the explainability fields the UI renders: the chosen index, the reason,
    /// and the chosen block's ASLEEP duration (the same figure the score used).
    public struct MainNightSelection: Equatable {
        public let index: Int
        public let reason: MainNightReason
        public let asleepSeconds: Int
        public init(index: Int, reason: MainNightReason, asleepSeconds: Int) {
            self.index = index; self.reason = reason; self.asleepSeconds = asleepSeconds
        }
        public var asleepMinutes: Double { Double(asleepSeconds) / 60.0 }
    }

    /// True when a block's onset falls in the cold-start overnight band (≥ `overnightStartHour` or <
    /// `overnightEndHour`, local). The scored selector no longer gates on it. `offsetSec` is seconds EAST
    /// of UTC.
    public static func isOvernightOnset(_ ts: Int, offsetSec: Int) -> Bool {
        let local = ts + offsetSec
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return hour >= overnightStartHour || hour < overnightEndHour
    }

    /// Local time-of-day, in seconds [0, 86400), of a unix timestamp shifted east by `offsetSec`.
    static func localSecOfDay(_ ts: Int, offsetSec: Int) -> Int {
        let local = ts + offsetSec
        return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
    }

    /// Smallest circular distance (seconds, 0...43200) between two times-of-day (23:30 and 00:30 are
    /// 3600 s apart, not 82800).
    static func circularDistanceSec(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b) % secondsPerDay
        return min(raw, secondsPerDay - raw)
    }

    /// The cold-start anchor: the center of the overnight band (20:00 → 11:00 wraps midnight, so 03:30
    /// local), standing in for the habitual midsleep before enough history exists.
    static var coldStartAnchorSec: Int {
        let startSec = overnightStartHour * 3_600
        let span = ((overnightEndHour - overnightStartHour) * 3_600 + secondsPerDay) % secondsPerDay // wrap
        return (startSec + span / 2) % secondsPerDay
    }

    /// The alignment bonus (MINUTES) for sitting near the target midsleep: full `alignmentBonusMin` within
    /// `alignmentFullWindowSec`, decaying linearly to 0 by `alignmentZeroSec`. Inputs are local
    /// times-of-day in seconds.
    static func alignmentBonusMinutes(blockMidSec: Int, targetMidSec: Int) -> Double {
        let d = circularDistanceSec(blockMidSec, targetMidSec)
        if d <= alignmentFullWindowSec { return alignmentBonusMin }
        if d >= alignmentZeroSec { return 0 }
        let frac = Double(alignmentZeroSec - d) / Double(alignmentZeroSec - alignmentFullWindowSec)
        return alignmentBonusMin * frac
    }

    /// The target midsleep time-of-day the scorer aligns to: the learned `habitualMidsleepSec` when supplied,
    /// else the cold-start band center.
    static func targetMidsleepSec(_ habitualMidsleepSec: Int?) -> Int {
        habitualMidsleepSec ?? coldStartAnchorSec
    }

    // MARK: - Gap-bridging

    /// Merge adjacent `NightBlock`s separated by a wake gap shorter than `gapBridgeMaxMin` into single
    /// blocks for selection. Sorts by `start` first so bridging sees neighbours.
    public static func bridgeAdjacent(_ blocks: [NightBlock]) -> [NightBlock] {
        guard blocks.count > 1 else { return blocks }
        let sorted = blocks.sorted { $0.start < $1.start }
        let bridgeS = gapBridgeMaxMin * 60
        var out: [NightBlock] = [sorted[0]]
        for b in sorted.dropFirst() {
            let last = out[out.count - 1]
            let gap = b.start - last.end
            if gap >= 0 && gap < bridgeS {
                out[out.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// One bridged night group: the fragments (ORIGINAL indices, ascending) plus the group's
    /// inter-fragment wake seams. Used by consumers that present an interrupted night as ONE night (Health
    /// write-back, sleep screens) so they group exactly as the day totals do.
    public struct BridgedNightGroup: Equatable {
        public let indices: [Int]
        public let gaps: [GapSpan]
        /// One inter-fragment seam: (previous bridged end, next fragment start), end > start always.
        public struct GapSpan: Equatable {
            public let start: Int, end: Int
            public init(start: Int, end: Int) { self.start = start; self.end = end }
        }
        public init(indices: [Int], gaps: [GapSpan]) { self.indices = indices; self.gaps = gaps }
    }

    /// EVERY bridged group over `blocks`, using the same two-tier bridge as `mainNightGroupIndices`, without
    /// the winner pick. A negative gap (a block starting inside the previous span) does not bridge and
    /// never fabricates a seam. Groups are ordered by start.
    public static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: Int) -> [BridgedNightGroup] {
        guard !blocks.isEmpty else { return [] }
        // Sort by onset so bridging sees neighbours, as `bridgeAdjacent` does.
        let order = blocks.indices.sorted { blocks[$0].start < blocks[$1].start }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        // Build bridged spans and the original indices composing each, in one pass.
        var bridged: [NightBlock] = []
        var groups: [[Int]] = []
        var gaps: [[BridgedNightGroup.GapSpan]] = []
        for idx in order {
            let b = blocks[idx]
            if let last = bridged.last {
                let gap = b.start - last.end
                // Short-wake bridge (< gapBridgeMaxMin), identical to `bridgeAdjacent`. Then a wider bridge for an
                // overnight night-tail (#861): a gap in [gapBridgeMaxMin, nightTailBridgeMaxMin) folds the fragment in
                // only when its onset is still in the overnight band, so a daytime nap stays its own block.
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(b.start, offsetSec: offsetSec)))
                if bridges {
                    if gap > 0 {
                        gaps[gaps.count - 1].append(.init(start: last.end, end: b.start))
                    }
                    bridged[bridged.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
            }
            bridged.append(b)
            groups.append([idx])
            gaps.append([])
        }
        return zip(groups, gaps).map { BridgedNightGroup(indices: $0.sorted(), gaps: $1) }
    }

    /// The ORIGINAL indices of the MAIN-NIGHT GROUP: the main night plus any fragments bridged into it, so
    /// a briefly-interrupted main sleep is scored as ONE night and the caller can SUM the group's stages.
    ///
    /// `bridgedNightGroups` merges the blocks, `mainNightIndex` scores the bridged spans (a two-fragment
    /// night out-scores a lone nap), and the winning group's indices are returned ascending. nil only for an
    /// empty list; with no bridgeable gap this is the single block `mainNightIndex` would pick.
    public static func mainNightGroupIndices(_ blocks: [NightBlock], offsetSec: Int,
                                             habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        let all = bridgedNightGroups(blocks, offsetSec: offsetSec)
        // Rebuild each group's span for scoring: (first start, running-max end), as the one-pass loop built it.
        let bridgedSpans = all.map { g -> NightBlock in
            NightBlock(start: g.indices.map { blocks[$0].start }.min() ?? 0,
                       end: g.indices.map { blocks[$0].end }.max() ?? 0)
        }
        guard let winner = mainNightIndex(bridgedSpans, offsetSec: offsetSec,
                                          habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        return all[winner].indices
    }

    /// Index of the day's MAIN night by the LEARNED-TIMING SCORE: asleepMinutes + alignmentBonus, where the
    /// bonus credits a midpoint near `habitualMidsleepSec` (or, cold-start, the overnight-band center).
    /// No duration floor or overnight gate: a nap-only day still resolves to a main block and a genuine long
    /// daytime sleep can win. Highest score wins; ties go to the EARLIER onset. nil only for an empty list.
    /// This overload has no decoded stages, so "asleep minutes" is the clock span.
    public static func mainNightIndex(_ blocks: [NightBlock], offsetSec: Int,
                                      habitualMidsleepSec: Int? = nil) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let target = targetMidsleepSec(habitualMidsleepSec)
        func score(_ b: NightBlock) -> Double {
            let asleepMin = Double(b.durationS) / 60.0
            let midSec = localSecOfDay(b.midpointSec, offsetSec: offsetSec)
            return asleepMin + alignmentBonusMinutes(blockMidSec: midSec, targetMidSec: target)
        }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let cs = score(cand), bs = score(best)
            let candWins: Bool
            if cs != bs {
                candWins = cs > bs                       // higher score wins
            } else {
                candWins = cand.start < best.start       // exact tie → earlier onset (stable)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }

    /// Main-night selection annotated with the explainability reason and the chosen block's asleep
    /// duration. `index` is identical to `mainNightIndex(...)`. The reason comes from the same signals:
    ///   - `onlyBlock`: a single block.
    ///   - `alignedToUsual`: not the longest; the alignment bonus flipped the pick.
    ///   - `longestNearUsual`: the longest, with a learned habitual and a positive alignment bonus.
    ///   - `longest`: otherwise (incl. cold-start).
    /// "Longest" ranks by the same duration the score adds (clock span here), ties to the earlier onset.
    public static func mainNightSelection(_ blocks: [NightBlock], offsetSec: Int,
                                          habitualMidsleepSec: Int? = nil) -> MainNightSelection? {
        guard let idx = mainNightIndex(blocks, offsetSec: offsetSec,
                                       habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let chosen = blocks[idx]
        let reason = mainNightReason(
            chosenAsleepSec: chosen.durationS, chosenOnset: chosen.start,
            chosenMidLocalSec: localSecOfDay(chosen.midpointSec, offsetSec: offsetSec),
            blockCount: blocks.count,
            // Duration-only winner over the same asleep figure and tie-break.
            longestAsleepSec: blocks.map(\.durationS).max() ?? chosen.durationS,
            longestOnset: durationOnlyWinnerOnset(asleepSecs: blocks.map(\.durationS),
                                                  onsets: blocks.map(\.start)),
            chosenIsDurationWinnerOnset: chosen.start,
            habitualMidsleepSec: habitualMidsleepSec)
        return MainNightSelection(index: idx, reason: reason, asleepSeconds: chosen.durationS)
    }

    /// The onset of the DURATION-ONLY winner among parallel `asleepSecs`/`onsets` arrays: greatest asleep
    /// figure, ties to the EARLIER onset (as the score does). Returns the first onset when empty.
    static func durationOnlyWinnerOnset(asleepSecs: [Int], onsets: [Int]) -> Int {
        guard !asleepSecs.isEmpty else { return 0 }
        var bestIdx = 0
        for i in 1..<asleepSecs.count {
            let candDur = asleepSecs[i], bestDur = asleepSecs[bestIdx]
            let candWins: Bool
            if candDur != bestDur {
                candWins = candDur > bestDur
            } else {
                candWins = onsets[i] < onsets[bestIdx]
            }
            if candWins { bestIdx = i }
        }
        return onsets[bestIdx]
    }

    /// Decide the `MainNightReason` from the chosen block and the duration-only winner. The chosen block is
    /// the duration winner iff its asleep equals the longest AND its onset equals the winner's onset.
    static func mainNightReason(chosenAsleepSec: Int, chosenOnset: Int, chosenMidLocalSec: Int,
                                blockCount: Int, longestAsleepSec: Int, longestOnset: Int,
                                chosenIsDurationWinnerOnset: Int, habitualMidsleepSec: Int?) -> MainNightReason {
        if blockCount <= 1 { return .onlyBlock }
        let chosenIsLongest = (chosenAsleepSec == longestAsleepSec)
            && (chosenIsDurationWinnerOnset == longestOnset)
        if !chosenIsLongest {
            return .alignedToUsual
        }
        // The chosen block is the longest; "near usual" only with a learned habitual and a positive bonus.
        if let habitual = habitualMidsleepSec {
            let bonus = alignmentBonusMinutes(blockMidSec: chosenMidLocalSec, targetMidSec: habitual)
            if bonus > meaningfulBonusEpsilon { return .longestNearUsual }
        }
        return .longest
    }

    /// The night's daily sleep aggregate: USER-EDITED blocks substitute for their detected twins, then
    /// user-added blocks with no detected twin are unioned in. `detected` carries stable startTs + stages;
    /// `edited` maps startTs → hand-corrected stages (a wake-time edit never moves startTs); `manual` holds
    /// blocks the detector never found. De-duped by startTs. Returns the aggregate and whether an edit or
    /// manual block contributed (so the caller only overrides the day then), or nil when nothing decodes.
    public static func dailyAggregateHonoringEdits(
        detected: [(startTs: Int, stagesJSON: String?)],
        edited: [Int: String?],
        manual: [(startTs: Int, stagesJSON: String?)] = [],
        // Effective onsets (a wake/bed edit moves end, not the start key) plus the UTC offset, so the
        // main-night pick reads the user's clock. nil keeps the sum-of-all-blocks behaviour.
        onsetByStart: [Int: Int]? = nil,
        offsetSec: Int = 0,
        // Learned habitual midsleep (local seconds-of-day); nil = cold-start overnight-band bonus.
        habitualMidsleepSec: Int? = nil
    ) -> (sleep: DailySleep, editApplied: Bool)? {
        // Substitute an edited block's stages only when they are usable: an edit that reshaped to nil falls back
        // to the detected stages rather than dropping the block and collapsing the night's total.
        var applied = false
        // (startTs, effective stages) for every block: detected (edit-substituted) then twinless manual blocks.
        var blocks: [(startTs: Int, stagesJSON: String?)] = detected.map { d in
            if let stages = edited[d.startTs] ?? nil {   // flatten String?? → String?, then require non-nil
                applied = true
                return (startTs: d.startTs, stagesJSON: stages)
            }
            return (startTs: d.startTs, stagesJSON: d.stagesJSON)
        }
        // Union a user-added block with no detected twin (e.g. a hand-logged nap) so the pick sees it; match on
        // startTs and add only absent rows with usable stages.
        let detectedStarts = Set(detected.map(\.startTs))
        for m in manual where !detectedStarts.contains(m.startTs) {
            if let stages = m.stagesJSON {
                blocks.append((startTs: m.startTs, stagesJSON: stages))
                applied = true
            }
        }
        // With onsets supplied, the daily figure is the MAIN NIGHT group only (the same block the Sleep tab
        // shows), so Intelligence, Sleep Need and the debt ledger read the same number. Naps stay their own
        // rows. No onsets: the legacy sum of all blocks.
        if let onsetByStart {
            // Pick by the Sleep tab's learned-timing score, bridging adjacent blocks split by a short wake gap into
            // the main-night GROUP and summing it, so the seam reports the same night `analyzeDay` does.
            let group = mainNightGroupIndicesByStages(blocks, onsetByStart: onsetByStart, offsetSec: offsetSec,
                                                      habitualMidsleepSec: habitualMidsleepSec)
            // Out-of-bed time between bridged fragments counts as AWAKE via the same definition `analyzeDay` uses,
            // over each fragment's effective span `[onset, onset + decoded in-bed]`.
            if let group {
                // Trim each SELECTED block's stages to its effective onset before summing. A hand-edited or onset-trimmed
                // bedtime that was too sparse to re-stage (WHOOP 4.0) leaves pre-onset segments, which would push asleep
                // past time-in-bed. Selection ran on the original blocks; only the summed total is clamped.
                let clampedStages: [String?] = group.map { i in
                    if let onset = onsetByStart[blocks[i].startTs] {
                        return clampStagesToOnset(blocks[i].stagesJSON, onsetSec: onset)
                    }
                    return blocks[i].stagesJSON
                }
                let spans: [(start: Int, end: Int)] = group.enumerated().map { (gi, i) in
                    let onset = onsetByStart[blocks[i].startTs] ?? blocks[i].startTs
                    let inBedSec = Int((minutes(fromStagesJSON: clampedStages[gi])?.inBed ?? 0) * 60.0)
                    return (start: onset, end: onset + inBedSec)
                }
                let gapAwakeS = interFragmentAwakeSeconds(spans)
                if let agg = dailyAggregate(clampedStages, interFragmentAwakeSeconds: gapAwakeS) {
                    return (agg, applied)
                }
            }
            return nil
        }
        guard let agg = dailyAggregate(blocks.map(\.stagesJSON)) else { return nil }
        return (agg, applied)
    }

    /// The original-index group (ascending) of the day's MAIN night on the STAGES path: the main night plus
    /// adjacent bridged fragments, so the edit/recompute seam sums the same fragments `analyzeDay` does. Each
    /// block's span is `[onset, onset + decoded in-bed]`; bridged spans are scored by
    /// `mainNightIndexByStages`. nil only for an empty list.
    static func mainNightGroupIndicesByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                              onsetByStart: [Int: Int], offsetSec: Int,
                                              habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        func effEnd(_ b: (startTs: Int, stagesJSON: String?)) -> Int {
            onset(b) + Int((minutes(fromStagesJSON: b.stagesJSON)?.inBed ?? 0) * 60.0)
        }
        let order = blocks.indices.sorted { onset(blocks[$0]) < onset(blocks[$1]) }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        // Bridged groups of ORIGINAL indices plus the representative (startTs, stages) the score reads.
        var groups: [[Int]] = []
        var groupEnd: [Int] = []     // running effective end of each bridged group
        for idx in order {
            let b = blocks[idx]
            if let last = groupEnd.last {
                let gap = onset(b) - last
                // Same two-tier bridge as `mainNightGroupIndices` (short-wake, then the overnight night-tail widening,
                // #861) so the daily total folds in exactly the fragments the Sleep tab does.
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(onset(b), offsetSec: offsetSec)))
                if bridges {
                    groups[groups.count - 1].append(idx)
                    groupEnd[groupEnd.count - 1] = max(last, effEnd(b))
                    continue
                }
            }
            groups.append([idx])
            groupEnd.append(effEnd(b))
        }
        // Score each bridged group by its first fragment's onset and the group's summed decoded minutes.
        let groupBlocks: [(startTs: Int, stagesJSON: String?)] = groups.map { g in
            // Representative block: startTs is the earliest-onset fragment (anchoring the midpoint) and stages are
            // the group's summed stages, so the scorer ranks the combined night.
            let summed = SleepStageTotals.summedStagesJSON(g.map { blocks[$0].stagesJSON })
            let anchor = g.min(by: { onset(blocks[$0]) < onset(blocks[$1]) }) ?? g[0]
            return (startTs: blocks[anchor].startTs, stagesJSON: summed)
        }
        var groupOnsets: [Int: Int] = [:]
        for (gi, g) in groups.enumerated() {
            let anchor = g.min(by: { onset(blocks[$0]) < onset(blocks[$1]) }) ?? g[0]
            groupOnsets[groupBlocks[gi].startTs] = onset(blocks[anchor])
        }
        guard let winner = mainNightIndexByStages(groupBlocks, onsetByStart: groupOnsets, offsetSec: offsetSec,
                                                  habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        return groups[winner].sorted()
    }

    /// A synthetic minute-dict `stagesJSON` whose per-stage minutes are the SUM of the inputs' decoded
    /// minutes, used only to score a bridged group as one block. nil when nothing decodes.
    static func summedStagesJSON(_ stagesJSONs: [String?]) -> String? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        guard any else { return nil }
        let dict: [String: Double] = ["awake": total.awake, "light": total.light,
                                      "deep": total.deep, "rem": total.rem]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Index of the day's MAIN night by the LEARNED-TIMING SCORE: asleepMinutes + alignmentBonus, where
    /// asleepMinutes is the decoded ASLEEP minutes (not in-bed) and the bonus credits a midpoint near
    /// `habitualMidsleepSec` (or the overnight band). The midpoint is `onset + (in-bed span)/2` from the
    /// decoded minutes. Undecodable blocks score 0 but stay candidates; ties go to the EARLIER onset.
    static func mainNightIndexByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                       onsetByStart: [Int: Int], offsetSec: Int,
                                       habitualMidsleepSec: Int? = nil) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let target = targetMidsleepSec(habitualMidsleepSec)
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        func score(_ b: (startTs: Int, stagesJSON: String?)) -> Double {
            let m = minutes(fromStagesJSON: b.stagesJSON)
            let asleepMin = m?.asleep ?? 0
            let inBedSec = Int((m?.inBed ?? 0) * 60.0)
            let midSec = localSecOfDay(onset(b) + inBedSec / 2, offsetSec: offsetSec)
            return asleepMin + alignmentBonusMinutes(blockMidSec: midSec, targetMidSec: target)
        }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let cs = score(cand), bs = score(best)
            let candWins: Bool
            if cs != bs {
                candWins = cs > bs
            } else {
                candWins = onset(cand) < onset(best)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }

    /// Stages-path counterpart of `mainNightSelection`. `index` equals `mainNightIndexByStages(...)`; the
    /// "longest" comparison ranks by decoded asleep seconds (the figure the score adds), ties by effective
    /// onset. An undecodable block contributes 0 asleep seconds.
    static func mainNightSelectionByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                           onsetByStart: [Int: Int], offsetSec: Int,
                                           habitualMidsleepSec: Int? = nil) -> MainNightSelection? {
        guard let idx = mainNightIndexByStages(blocks, onsetByStart: onsetByStart, offsetSec: offsetSec,
                                               habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        let asleepSecs: [Int] = blocks.map { Int((minutes(fromStagesJSON: $0.stagesJSON)?.asleep ?? 0) * 60.0) }
        let onsets: [Int] = blocks.map(onset)
        let chosen = blocks[idx]
        let chosenAsleepSec = asleepSecs[idx]
        let chosenInBedSec = Int((minutes(fromStagesJSON: chosen.stagesJSON)?.inBed ?? 0) * 60.0)
        let chosenMidLocalSec = localSecOfDay(onset(chosen) + chosenInBedSec / 2, offsetSec: offsetSec)
        let reason = mainNightReason(
            chosenAsleepSec: chosenAsleepSec, chosenOnset: onset(chosen),
            chosenMidLocalSec: chosenMidLocalSec, blockCount: blocks.count,
            longestAsleepSec: asleepSecs.max() ?? chosenAsleepSec,
            longestOnset: durationOnlyWinnerOnset(asleepSecs: asleepSecs, onsets: onsets),
            chosenIsDurationWinnerOnset: onset(chosen),
            habitualMidsleepSec: habitualMidsleepSec)
        return MainNightSelection(index: idx, reason: reason, asleepSeconds: chosenAsleepSec)
    }

    // MARK: - Habitual midsleep

    /// One detected sleep block from the trailing history. `dayKey` groups blocks by local day so the
    /// LONGEST per day can be picked independently of main-night selection (no circular dependency).
    public struct HistoryBlock {
        public let start: Int, end: Int, dayKey: String
        public init(start: Int, end: Int, dayKey: String) {
            self.start = start; self.end = end; self.dayKey = dayKey
        }
        public var durationS: Int { end - start }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    /// Minimum DAYS of history before a habitual midsleep is trusted (~2 weeks, the lower bound the
    /// sleep-timing literature uses for a stable midpoint); below it the scorer uses the overnight band.
    public static let habitualMinDays = 14

    /// The user's habitual midsleep as a LOCAL TIME-OF-DAY (seconds in [0, 86400)), or nil with too little
    /// history. The CIRCULAR MEAN of the midpoint time-of-day of the longest block per local day, so
    /// 23:30 and 00:30 are an hour apart. `offsetSec` makes each midpoint local; `minDays` is the floor.
    public static func habitualMidsleepSec(_ history: [HistoryBlock], offsetSec: Int,
                                           minDays: Int = habitualMinDays) -> Int? {
        guard !history.isEmpty else { return nil }
        // Longest block per local day; ties go to the earlier onset.
        var longestByDay: [String: HistoryBlock] = [:]
        for b in history {
            if let cur = longestByDay[b.dayKey] {
                if b.durationS > cur.durationS || (b.durationS == cur.durationS && b.start < cur.start) {
                    longestByDay[b.dayKey] = b
                }
            } else {
                longestByDay[b.dayKey] = b
            }
        }
        guard longestByDay.count >= minDays else { return nil }
        // Circular mean: unit-vector sum of the angles (order-independent), mapped back to seconds-of-day; nil
        // when the resultant is degenerate (falls back to cold-start).
        let midSecs = longestByDay.values.map { localSecOfDay($0.midpointSec, offsetSec: offsetSec) }
        return circularMeanSec(midSecs)
    }

    /// Minimum mean-resultant length (R = |Σ(sin,cos)| / n) for a circular mean to be meaningful. Below it
    /// the angles are antipodal/uniform, atan2 returns an arbitrary direction, and Swift and Kotlin could
    /// disagree; both reject the same inputs.
    static let circularMeanMinResultant = 1e-9

    /// Circular mean of times-of-day (seconds in [0, 86400)) via the mean unit vector. nil when the
    /// resultant is degenerate (empty, or below `circularMeanMinResultant`), so `habitualMidsleepSec`
    /// falls back to cold-start rather than emit a meaningless anchor.
    static func circularMeanSec(_ secs: [Int]) -> Int? {
        guard !secs.isEmpty else { return nil }
        var sumSin = 0.0, sumCos = 0.0
        let k = 2.0 * Double.pi / Double(secondsPerDay)
        for s in secs {
            let a = Double(s) * k
            sumSin += sin(a); sumCos += cos(a)
        }
        // Resultant length R = |(Σsin, Σcos)| / n; below epsilon the direction is meaningless.
        let resultant = (sumSin * sumSin + sumCos * sumCos).squareRoot() / Double(secs.count)
        guard resultant >= circularMeanMinResultant else { return nil }
        var ang = atan2(sumSin, sumCos)               // [-π, π]
        if ang < 0 { ang += 2.0 * Double.pi }         // → [0, 2π)
        let sec = Int((ang / k).rounded()) % secondsPerDay
        return (sec + secondsPerDay) % secondsPerDay
    }
}
