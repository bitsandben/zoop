import Foundation

/// Overlap-aware de-duplication of banked sleep sessions.
///
/// An unstable strap clock can re-bank the same night under a shifted timebase, leaving overlapping
/// copies under different `startTs` keys that the (deviceId, startTs) upsert cannot collapse. This is
/// the shared collapse rule applied wherever banked sessions are assembled before day assignment or
/// scoring. Pure and deterministic; the Kotlin twin mirrors it byte for byte.
public enum SleepSessionDedup {

    /// Absolute overlap (seconds) at or above which two sessions are copies of the same night. Two real
    /// sleeps never overlap on one honest timeline; 30 min keeps sub-30-min boundary grazes from collapsing.
    public static let minOverlapSeconds = 30 * 60

    /// Fractional overlap of the shorter session at or above which two sessions are duplicates, catching
    /// a short fragment swallowed by a longer copy (e.g. 40 min, 60% inside the night).
    public static let minOverlapFractionOfShorter = 0.5

    /// Edge distance (seconds) at or below which a same-night fragment is still one night. The Oura
    /// SleepNet burst runs a few epochs before the `0x49` onset, so its pre-onset piece can bank as a short
    /// session just before, or grazing into, the anchored night. 15 min is ~2x the observed pre-onset span.
    public static let nearAdjacentSeconds = 15 * 60

    /// A shorter session at or below this fraction of the longer one is a re-decode fragment, not a second
    /// sleep. A ratio, not an absolute cap, because real naps and fragments overlap in length: a 26 min
    /// fragment beside a 390 min night (6.7%) collapses, two real naps of 20 and 33 min (61%) do not.
    /// Conservative; the durable fix is `0x49`-onset keying.
    public static let fragmentFractionOfLonger = 0.10

    /// Seconds of overlap between the two sessions' effective spans (edited onsets honoured). 0 when disjoint.
    static func overlapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, min(a.endTs, b.endTs) - max(a.effectiveStartTs, b.effectiveStartTs))
    }

    /// Edge gap (seconds) between two disjoint sessions; 0 when they touch or overlap. Only meaningful when `overlapSeconds == 0`.
    static func edgeGapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, max(a.effectiveStartTs, b.effectiveStartTs) - min(a.endTs, b.endTs))
    }

    /// True when `a` and `b` are copies of the same night: a substantial overlap (`minOverlapSeconds`, or
    /// `minOverlapFractionOfShorter` of the shorter), or a same-night fragment (no more than
    /// `fragmentFractionOfLonger` of the longer) at its edge, whether grazing in or within `nearAdjacentSeconds`.
    ///
    /// The fragment term is continuous across the overlap==0 seam: a piece overshooting the onset by
    /// seconds must not count as more distinct than one ending seconds short. The ratio gate keeps two
    /// real adjacent naps apart. Only (effectiveStartTs, endTs) are used.
    public static func isDuplicate(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Bool {
        let overlap = overlapSeconds(a, b)
        if overlap >= minOverlapSeconds { return true }
        let aDur = max(a.endTs - a.effectiveStartTs, 0)
        let bDur = max(b.endTs - b.effectiveStartTs, 0)
        let shorter = min(aDur, bDur)
        if overlap > 0, shorter > 0, Double(overlap) >= minOverlapFractionOfShorter * Double(shorter) {
            return true
        }
        // Same-night fragment: short relative to the longer night and hugging its edge on either side.
        let longer = max(aDur, bDur)
        let isFragment = shorter > 0 && Double(shorter) <= fragmentFractionOfLonger * Double(longer)
        return isFragment && (overlap > 0 || edgeGapSeconds(a, b) <= nearAdjacentSeconds)
    }

    /// The canonical preference key (see `dedupe`): higher tuple wins. Shared with `planBank` so both
    /// adjudicate a night by the identical rule.
    static func rankKey(_ s: CachedSleepSession, freshStarts: Set<Int>) -> (Int, Int, Int, Int, Int) {
        (s.userEdited ? 1 : 0,
         freshStarts.contains(s.startTs) ? 1 : 0,
         s.endTs - s.effectiveStartTs,
         s.endTs,
         s.startTs)
    }

    /// Collapses overlapping duplicates to one canonical survivor per night, deterministically.
    ///
    /// Preference, highest first:
    ///   1. `userEdited`: a hand-corrected night is never dropped.
    ///   2. Bank recency: `startTs` in `freshStarts`, passed by the caller since rows carry no banked-at
    ///      column; the freshly detected copy reflects the strap's current timebase.
    ///   3. Longest effective duration.
    ///   4. Latest endTs, then latest startTs, for a stable total order across runs and platforms.
    ///
    /// Greedy sweep in preference order: a session is kept unless it overlap-duplicates a kept one
    /// (edited rows are exempt). Both outputs are sorted by startTs. Read-side callers pass no `freshStarts`.
    public static func dedupe(_ sessions: [CachedSleepSession], freshStarts: Set<Int> = [])
        -> (kept: [CachedSleepSession], dropped: [CachedSleepSession]) {
        guard sessions.count > 1 else { return (sessions, []) }
        let ordered = sessions.sorted { rankKey($0, freshStarts: freshStarts) > rankKey($1, freshStarts: freshStarts) }
        var kept: [CachedSleepSession] = []
        var dropped: [CachedSleepSession] = []
        for s in ordered {
            if !s.userEdited, kept.contains(where: { isDuplicate($0, s) }) {
                dropped.append(s)
            } else {
                kept.append(s)
            }
        }
        return (kept.sorted { $0.startTs < $1.startTs },
                dropped.sorted { $0.startTs < $1.startTs })
    }

    /// The bank-recency witness the post-upsert heal may hand `dedupe` for one device id's rows.
    ///
    /// `keptStarts` witness recency only under `computedId`. For a device-provided hypnogram (an Oura
    /// ring) the same keys name the row the pass read, the stalest of the night, so using them elsewhere
    /// ranked it above fuller re-serves and the heal deleted the full night. Every other id gets no
    /// witness and falls back to longest-wins.
    public static func healWitness(for healId: String, computedId: String, keptStarts: Set<Int>) -> Set<Int> {
        healId == computedId ? keptStarts : []
    }

    // MARK: - generation-side 0x49-onset keying (at-persist, no schema migration)

    /// The grid (seconds) the 0x49 onset is rounded to before it becomes a session's `startTs`. The ring
    /// re-serves one night's `0x49` summary many times with a stable onset (21 s spread over 11 servings),
    /// so rounding to 60 s gives every re-serve the same `startTs` and the PK collapses them, while the
    /// displayed bedtime stays accurate to the minute.
    public static let onsetKeyGridSeconds = 60

    /// Rounds a `0x49` onset (Unix seconds) to `onsetKeyGridSeconds`, the stable per-night key. A rare
    /// straddle at a bucket edge is caught by the completeness guard (`planBank`), which matches by overlap.
    public static func keyedStart(onsetUnixSeconds: Int, gridSeconds: Int = onsetKeyGridSeconds) -> Int {
        let g = max(1, gridSeconds)
        return ((onsetUnixSeconds + g / 2) / g) * g
    }

    /// Guards the onset rekey against `OuraHypnogramBurst.codesWithTimes`'s fallback to the unclipped lay
    /// when clipping to the `0x49` onset would empty the burst (a mis-paired window). The caller cannot see
    /// that fallback, and re-keying to that onset anyway wrote a negative-duration session.
    ///
    /// A clip that bound leaves `mapped.startTs >= onset`; one the fallback ignored leaves it below. Also
    /// rejects 30 s grid-rounding pushing the onset to or past `endTs`.
    ///
    /// Returns the keyed start to bank, or `nil` to keep `mapped.startTs` (no rekey).
    public static func safeKeyedStart(onset: Int, mapped: CachedSleepSession) -> Int? {
        guard onset <= mapped.startTs else { return nil }
        let keyed = keyedStart(onsetUnixSeconds: onset)
        return keyed < mapped.endTs ? keyed : nil
    }

    /// Decides at persist time whether a reconstructed `candidate` night should be banked and which stored
    /// rows it supersedes, so a duplicate is suppressed before it is banked. Same collapse rule as
    /// `dedupe` with no recency witness:
    ///   - bank the candidate unless an existing same-night row is at least as complete (ties keep the
    ///     stored row, so a partial re-drain never clobbers a fuller night);
    ///   - when the candidate wins, delete the same-night rows it supersedes.
    /// Pure; the caller does the store delete and upsert only when `bank` is true.
    ///
    /// `existing` must be the unfiltered stored set for the night's window, including a row already at
    /// the candidate's keyed `startTs` (the common collision, which would otherwise be replaced by PK).
    /// `supersededStarts` excludes the candidate's own `startTs`, since the upsert replaces that in place.
    public static func planBank(candidate: CachedSleepSession, existing: [CachedSleepSession])
        -> (bank: Bool, supersededStarts: [Int]) {
        let sameNight = existing.filter { isDuplicate(candidate, $0) }
        let candidateRank = rankKey(candidate, freshStarts: [])
        // Suppress the candidate if any stored same-night row (same PK or not) ties or outranks it.
        if sameNight.contains(where: { rankKey($0, freshStarts: []) >= candidateRank }) {
            return (bank: false, supersededStarts: [])
        }
        // Candidate is the fullest: bank it (upsert replaces any same-PK row) and retire the other same-night rows.
        return (bank: true, supersededStarts: sameNight.filter { $0.startTs != candidate.startTs }.map(\.startTs))
    }
}
