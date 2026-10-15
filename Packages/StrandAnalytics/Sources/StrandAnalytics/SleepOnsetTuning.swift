import Foundation
import WhoopProtocol

// MARK: - Sleep onset tuning, evidence and learning (Zoop)
//
// The HR-confirmed onset rule (`SleepStager.onsetDecision`) cuts a quiet lead whose heart rate never
// came down to the night's sleeping level. Pure pieces built on it:
//   1. `OnsetTrimThresholds` / `SleepOnsetStrictness`: the rule's numbers scaled by a user setting
//      (`.standard` equals the shipped constants).
//   2. `SleepOnsetEvidence` / `SleepStager.explainOnset`: what the rule saw and decided for a night,
//      for the "Why this sleep?" sheet; computed by the rule itself, never re-derived in the UI.
//   3. `OnsetCorrectionLearning`: a personal offset learned from the wearer's own start-time edits.
// Approximate, like the rule itself: not validated against PSG.

/// The onset rule's thresholds. `.standard` equals the `SleepStager.onsetTrim*` constants.
public struct OnsetTrimThresholds: Equatable, Hashable, Sendable {
    public var windowMin: Int
    public var sleepLevelPct: Double
    public var sleepBandMult: Double
    public var sleepBandMinBpm: Double
    public var awakeMult: Double
    public var awakeMinDeltaBpm: Double
    public var minLeadMin: Int
    public var stillFrac: Double
    public var minHRMinutes: Int

    public static let standard = OnsetTrimThresholds(
        windowMin: SleepStager.onsetTrimWindowMin,
        sleepLevelPct: SleepStager.onsetTrimSleepLevelPct,
        sleepBandMult: SleepStager.onsetTrimSleepBandMult,
        sleepBandMinBpm: SleepStager.onsetTrimSleepBandMinBpm,
        awakeMult: SleepStager.onsetTrimAwakeMult,
        awakeMinDeltaBpm: SleepStager.onsetTrimAwakeMinDeltaBpm,
        minLeadMin: SleepStager.onsetTrimMinLeadMin,
        stillFrac: SleepStager.onsetTrimStillFrac,
        minHRMinutes: SleepStager.onsetTrimMinHRMinutes)

    /// The thresholds for a strictness. One factor `k` scales every margin (how far above the sleeping
    /// level a lead must sit to count as awake, how close the onset stretch must come, how long a lead
    /// must be to be cut). Strict (k < 1) starts sleep later; Relaxed (k > 1) sooner. Window length, level
    /// percentile and coverage floor are not margins and stay fixed.
    public static func forStrictness(_ s: SleepOnsetStrictness) -> OnsetTrimThresholds {
        let k = s.scale
        guard k != 1 else { return .standard }
        var t = OnsetTrimThresholds.standard
        t.sleepBandMult = 1 + (standard.sleepBandMult - 1) * k
        t.sleepBandMinBpm = standard.sleepBandMinBpm * k
        t.awakeMult = 1 + (standard.awakeMult - 1) * k
        t.awakeMinDeltaBpm = standard.awakeMinDeltaBpm * k
        t.minLeadMin = max(1, Int((Double(standard.minLeadMin) * k).rounded()))
        return t
    }
}

/// How readily quiet time before sleep is counted as awake. Persisted by its raw value.
public enum SleepOnsetStrictness: String, CaseIterable, Sendable, Hashable {
    case strict, standard, relaxed

    /// The margin scale `OnsetTrimThresholds.forStrictness` applies.
    public var scale: Double {
        switch self {
        case .strict:   return 0.6
        case .standard: return 1.0
        case .relaxed:  return 1.5
        }
    }
}

/// Everything the onset rule takes from the wearer's settings, threaded into `detectSleep`.
public struct SleepOnsetTuning: Equatable, Hashable, Sendable {
    public var strictness: SleepOnsetStrictness
    /// Learned personal offset in minutes (positive = sleep starts later than the rule found). Already
    /// clamped by `OnsetCorrectionLearning`; applied to overnight runs only.
    public var personalOffsetMin: Int

    public init(strictness: SleepOnsetStrictness = .standard, personalOffsetMin: Int = 0) {
        self.strictness = strictness
        self.personalOffsetMin = personalOffsetMin
    }

    public static let standard = SleepOnsetTuning()

    public var thresholds: OnsetTrimThresholds { .forStrictness(strictness) }

    /// Empty for the default, so a cache signature built from it is unchanged on an untouched install.
    public var signature: String {
        self == .standard ? "" : "onset-\(strictness.rawValue)\(personalOffsetMin >= 0 ? "+" : "")\(personalOffsetMin)"
    }
}

/// What the onset rule saw and decided for one night, for display. Times are unix seconds.
public struct SleepOnsetEvidence: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case trimmed
        case settledPromptly
        case leadAtSleepingLevel
        case neverSettled
        case sparseHR
        case tooShortToTrim
    }

    public let outcome: Outcome
    public let stillSinceTs: Int
    public let ruleOnsetTs: Int
    /// The onset after the learned offset: the night's detected start.
    public let onsetTs: Int
    public let appliedOffsetMin: Int
    /// The end of the still run (the wearer started moving).
    public let stillUntilTs: Int
    public let sleepLevelBpm: Double?
    public let sleepBandBpm: Double?
    public let awakeBarBpm: Double?
    public let leadMedianBpm: Double?
    /// First minute in the sleeping band inside a still, sleeping-HR stretch.
    public let settledTs: Int?
    public let seriesStartTs: Int
    public let minuteHR: [Double?]
    public let minuteMoving: [Double?]

    /// The lead's distance above the sleeping level, whole bpm, when the rule measured one.
    public var leadAboveLevelBpm: Int? {
        guard let lead = leadMedianBpm, let level = sleepLevelBpm else { return nil }
        return Int((lead - level).rounded())
    }
}

extension SleepStager {
    /// Explain the onset of the night `[sessionStart, sessionEnd]` from its raw streams: rebuild the
    /// gravity-still runs as `detectSleep` does, take the run overlapping the night most, and run the onset
    /// rule on it with `tuning`. nil when no run overlaps. Pass streams for a few hours either side so the
    /// run is rebuilt whole. `detectSleep`'s later confirmation gates are not re-run: they accept or drop a
    /// night, never move its start.
    public static func explainOnset(hr: [HRSample], gravity: [GravitySample],
                                    sessionStart: Int, sessionEnd: Int,
                                    tzOffsetSeconds: Int = 0,
                                    tuning: SleepOnsetTuning = .standard) -> SleepOnsetEvidence? {
        let grav = gravity.sorted { $0.ts < $1.ts }
        guard grav.count >= 2, sessionEnd > sessionStart else { return nil }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let baseline = hrBaseline(hrS)
        let sparse = isGravitySparse(grav, hr: hrS)
        let flags = classifyStill(grav, gravityDeltas(grav))
        var runs = mergePeriods(buildRuns(grav, flags, sparse: sparse, hr: hrS, baseline: baseline))
        let minSleepS = minSleepMin * 60
        let fragmented = isFragmentedToNothing(
            runs.filter { $0.stage == "sleep" }.map { $0.end - $0.start }, minSleepS: minSleepS)
        runs = bridgeSparseSleepTraced(runs, sparse: sparse || fragmented, hr: hrS, baseline: baseline).0
        func overlap(_ p: Period) -> Int { max(0, min(p.end, sessionEnd) - max(p.start, sessionStart)) }
        guard let run = runs.filter({ $0.stage == "sleep" && overlap($0) > 0 })
                .max(by: { overlap($0) < overlap($1) }) else { return nil }

        let decision = onsetDecision(run, hr: hrS, grav: grav, thresholds: tuning.thresholds)
        let offset = isDaytimeCenter(run, tzOffsetSeconds: tzOffsetSeconds) ? 0 : tuning.personalOffsetMin
        let onset = applyingOnsetOffset(onsetTs: decision.onsetTs, runStart: run.start, runEnd: run.end,
                                        offsetMin: offset)
        let seriesStart = min(run.start, sessionStart) - 45 * 60
        let seriesEnd = max(run.end, sessionEnd) + 30 * 60
        return SleepOnsetEvidence(
            outcome: decision.outcome,
            stillSinceTs: run.start,
            ruleOnsetTs: decision.onsetTs,
            onsetTs: onset,
            appliedOffsetMin: (onset - decision.onsetTs) / 60,
            stillUntilTs: run.end,
            sleepLevelBpm: decision.sleepLevelBpm,
            sleepBandBpm: decision.sleepBandBpm,
            awakeBarBpm: decision.awakeBarBpm,
            leadMedianBpm: decision.leadMedianBpm,
            settledTs: decision.settledTs,
            seriesStartTs: seriesStart,
            minuteHR: minuteHRMedians(start: seriesStart, end: seriesEnd, hr: hrS),
            minuteMoving: minuteMovingFraction(start: seriesStart, end: seriesEnd, grav: grav))
    }
}

/// A personal onset offset learned from the wearer's own corrections of a night's start time.
///
/// Each correction is the signed gap, in minutes, between the start the rule found (before any learned
/// offset) and the start the wearer set: positive = they fell asleep later than detected. The offset is
/// the median of the last `maxStored`, used only once there are `minCount` of them and at least
/// `agreementShare` point the same way as that median, and clamped to ±`clampMin`.
public enum OnsetCorrectionLearning {
    public struct Correction: Codable, Equatable, Sendable {
        /// The night's immutable detected start, so a second edit of the same night replaces the first.
        public let nightKey: Int
        public let deltaMin: Double
        public init(nightKey: Int, deltaMin: Double) {
            self.nightKey = nightKey
            self.deltaMin = deltaMin
        }
    }

    public static let maxStored = 20
    public static let minCount = 3
    public static let clampMin = 45
    /// Share of corrections that must point the same way as the median. With three corrections this
    /// means all three.
    public static let agreementShare = 0.75
    /// Corrections smaller than this (minutes) are recorded but point nowhere: they break agreement.
    public static let neutralBelowMin = 1.0

    /// `list` with `c` recorded: a correction for the same night replaces the earlier one, and only the
    /// newest `maxStored` are kept.
    public static func recording(_ c: Correction, into list: [Correction]) -> [Correction] {
        var out = list.filter { $0.nightKey != c.nightKey }
        out.append(c)
        if out.count > maxStored { out.removeFirst(out.count - maxStored) }
        return out
    }

    /// The learned offset in whole minutes, or nil while the corrections are too few or disagree.
    public static func learnedOffsetMin(_ list: [Correction]) -> Int? {
        let deltas = list.suffix(maxStored).map(\.deltaMin).filter { $0.isFinite }
        guard deltas.count >= minCount else { return nil }
        let med = HRVAnalyzer.median(deltas)
        guard abs(med) >= neutralBelowMin else { return nil }
        let sameWay = deltas.filter { med > 0 ? $0 >= neutralBelowMin : $0 <= -neutralBelowMin }.count
        guard Double(sameWay) >= agreementShare * Double(deltas.count) else { return nil }
        let clamped = min(Double(clampMin), max(-Double(clampMin), med))
        let whole = Int(clamped.rounded())
        return whole == 0 ? nil : whole
    }

    /// The correction to record when the wearer moves a night's start from `detectedStartTs` to
    /// `correctedStartTs`. `appliedOffsetMin` is the learned offset the detection already carried, added
    /// back so every correction is measured against the bare rule and the median does not chase itself.
    public static func correction(nightKey: Int, detectedStartTs: Int, correctedStartTs: Int,
                                  appliedOffsetMin: Int) -> Correction {
        Correction(nightKey: nightKey,
                   deltaMin: Double(correctedStartTs - detectedStartTs) / 60.0 + Double(appliedOffsetMin))
    }

    public static func encode(_ list: [Correction]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ raw: String?) -> [Correction] {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Correction].self, from: data) else { return [] }
        return list
    }
}
