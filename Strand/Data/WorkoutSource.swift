import Foundation
import WhoopStore
import StrandAnalytics   // WorkoutsTrace: the dedup-decision line formatter for the Workouts test mode

/// Origin of a workout row, classified from its stored `source` column (the read model carries no
/// `deviceId`). Stored values: "whoop" (WhoopImporter), "apple_health" / "apple-health"
/// (AppleHealthImport), "manual" (live session and the retro add/edit sheet), and "my-whoop-zoop"
/// (legacy detected bouts; readable/editable but no longer created by `analyzeRecent`).
///
/// "-zoop" is checked BEFORE "whoop" because the computed id "my-whoop-zoop" contains "whoop".
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual, lifting, activityFile

    /// Canonical Apple Health source id for new imports. Early rows used the underscore spelling, so reads
    /// must accept both (see `isAppleHealth`).
    static let appleHealthSource = "apple-health"
    private static let legacyAppleHealthSource = "apple_health"

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-zoop") { return .detected }   // BEFORE whoop: "my-whoop-zoop" contains "whoop"
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }          // imported Hevy / Liftosaur strength session
        if s == "activity-file" { return .activityFile } // imported GPX / TCX / FIT activity file
        if isAppleHealth(s) { return .apple }          // both spellings → Apple Health
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// True for an Apple Health workout row under either spelling (`apple-health` or legacy `apple_health`),
    /// case-insensitive. Counts of Apple-logged workouts MUST go through this.
    static func isAppleHealth(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == appleHealthSource || s == legacyAppleHealthSource
    }

    /// Sport-cell text. The detector's machine token "detected" shows as a neutral "Activity", and WHOOP's
    /// concatenated camelCase names ("TraditionalStrengthTraining") are split into words on the
    /// lower-to-upper boundary (#175). Already-spaced labels pass through.
    static func displaySport(_ sport: String) -> String {
        if sport == "detected" { return String(localized: "Activity") }
        let name = splitCamelCase(sport)
        return Bundle.main.localizedString(forKey: "sport." + name, value: name, table: nil)
    }

    private static func splitCamelCase(_ sport: String) -> String {
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// The locale-stable editable form an edit field should SEED ("Activity", never a translated word that
    /// would split cross-source dedup per language).
    static func editableSport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    // MARK: - Dismissed legacy detected bouts
    //
    // "This isn't a workout" tombstones kept as dismissed spans in UserDefaults (#107, #2187); still needed
    // for existing databases.

    static let dismissedDefaultsKey = "workouts.dismissedDetected"

    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a legacy DETECTED row overlapping any dismissed span is hidden; imported and manual
    /// rows never are. Half-open overlap: `row.start < span.end && span.start < row.end`.
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The same activity can land twice (live under the strap, and thin from Health Connect / Apple Health).
    // A pair with overlapping time and the same sport collapses to the richer entry, after the dismissed
    // filter and before the final sort.

    /// Normalised sport key for cross-source matching: folds camelCase tokens and human labels to one key
    /// ("Traditional Strength Training" -> "traditionalstrengthtraining"), case- and space-insensitive;
    /// "detected"/"Activity" fold to "activity". Locale-stable: computed from the raw token, never the
    /// localized display, so the dedup key and trace allowlist don't vary per language.
    static func sportKey(_ sport: String) -> String {
        editableSport(sport).lowercased().filter { !$0.isWhitespace }
    }

    private static let catalogSportKeys: Set<String> =
        Set(WorkoutCatalog.all.map { sportKey($0.name) })

    /// PRIVACY (trace path only): a redaction-safe sport key for the Workouts test-mode trace. `sportKey`
    /// returns a free-typed name verbatim, which `redactPii` cannot catch ("Johns Birthday 5k"). This emits
    /// the key only for the named catalogue (and "activity"); any free text folds to "custom".
    static func traceSportKey(_ sport: String) -> String {
        let key = sportKey(sport)
        if key == "activity" { return key }   // the detector's neutral token, never user text
        return catalogSportKeys.contains(key) ? key : "custom"
    }

    static func richness(_ row: WorkoutRow) -> Int {
        var n = 0
        if row.avgHr != nil { n += 1 }
        if row.maxHr != nil { n += 1 }
        if row.strain != nil { n += 1 }
        if let z = row.zonesJSON, !z.isEmpty { n += 1 }
        if let d = row.distanceM, d > 0 { n += 1 }
        if let k = row.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// True when two rows are the SAME activity from different sources: same normalised sport AND windows
    /// overlapping by more than half of the shorter session (keeps back-to-back sessions distinct).
    static func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        sportKey(a.sport) == sportKey(b.sport) && overlapsInTime(a, b)
    }

    private static func overlapsInTime(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = classify(a.source) == .apple, ib = classify(b.source) == .apple
        if ia != ib { return ia ? b : a }   // keep the non-import on a richness tie
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    // MARK: - Detected-vs-real overlap collapse (#975)
    //
    // `sameActivity` can't collapse a generic detection with a real workout (the sports differ), so this
    // guard hides a DETECTED row overlapping a REAL session by more than half of the shorter one. Runs
    // BEFORE same-sport dedup.

    static func detectedShadowsReal(_ detected: WorkoutRow, _ real: WorkoutRow) -> Bool {
        let overlap = min(detected.endTs, real.endTs) - max(detected.startTs, real.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(detected.endTs - detected.startTs, real.endTs - real.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    static func dropDetectedShadows(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        let reals = rows.filter { classify($0.source) != .detected }
        guard !reals.isEmpty else { return rows }
        return rows.filter { row in
            guard classify(row.source) == .detected else { return true }
            return !reals.contains { detectedShadowsReal(row, $0) }
        }
    }

    /// Collapses cross-source duplicates, keeping the richer row of each pair; order-stable. Detected shadows
    /// of a real session are dropped first (#975).
    static func dedupCrossSource(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        collapseCrossSource(dropDetectedShadows(rows))
    }

    /// The collapse walk shared by `dedupCrossSource` and its trace twin, near-linear: `sportKey` is computed
    /// once per row and a candidate compares only against kept rows of the SAME sport. `onMerge` receives
    /// (winner, loser) per collapsed pair.
    private static func collapseCrossSource(
        _ input: [WorkoutRow],
        onMerge: ((_ winner: WorkoutRow, _ loser: WorkoutRow) -> Void)? = nil
    ) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        kept.reserveCapacity(input.count)
        var bySport: [String: [Int]] = [:]
        for row in input {
            let key = sportKey(row.sport)
            var merged = false
            for idx in bySport[key, default: []] where overlapsInTime(kept[idx], row) {
                let winner = preferred(kept[idx], row)
                if let onMerge {
                    onMerge(winner, winner == kept[idx] ? row : kept[idx])
                }
                kept[idx] = winner
                merged = true
                break
            }
            if !merged {
                bySport[key, default: []].append(kept.count)
                kept.append(row)
            }
        }
        return kept
    }

    static func sourceLabel(_ row: WorkoutRow) -> String {
        switch classify(row.source) {
        case .whoop:        return "strap"
        case .apple:        return "apple"
        case .detected:     return "detected"
        case .manual:       return "manual"
        case .lifting:      return "lifting"
        case .activityFile: return "activityFile"
        }
    }

    /// Diagnostic twin of `dedupCrossSource` for the Workouts & GPS test mode: the identical kept list plus a
    /// trace line per collapsed pair and per dropped detected shadow.
    static func dedupCrossSourceTrace(_ rows: [WorkoutRow]) -> (kept: [WorkoutRow], trace: [String]) {
        var lines: [String] = []
        let reals = rows.filter { classify($0.source) != .detected }
        var input: [WorkoutRow] = []
        input.reserveCapacity(rows.count)
        for row in rows {
            if classify(row.source) == .detected,
               let hit = reals.first(where: { detectedShadowsReal(row, $0) }) {
                let durMin = max(0, (row.endTs - row.startTs) / 60)
                lines.append(WorkoutsTrace.detectedBoutLine(
                    verdict: "droppedShadow", durMin: durMin, avgBpm: row.avgHr ?? 0,
                    overlapSource: sourceLabel(hit)))
                continue
            }
            input.append(row)
        }
        let kept = collapseCrossSource(input) { winner, loser in
            lines.append(WorkoutsTrace.dedupLine(
                sportKey: traceSportKey(winner.sport),   // PRIVACY: catalogue key or "custom", never free text
                keptSource: sourceLabel(winner), droppedSource: sourceLabel(loser),
                keptRichness: richness(winner), droppedRichness: richness(loser)))
        }
        return (kept, lines)
    }

    // MARK: - Building / preserving rows

    /// Carries the captured fields the add/edit sheet does NOT expose (maxHr, strain, zonesJSON, notes,
    /// steps) over from the row being edited, so an edit doesn't wipe a live session's strain/maxHr. No-op
    /// for a fresh add. `distanceM` is a sheet field (#1195) and comes from the new `row`; `steps` (#1058)
    /// has no sheet field so it is carried like the others (#1444).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: row.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes, steps: old.steps)
    }

    static let maxManualSpanSeconds = 24 * 60 * 60

    /// Shortest manual session worth keeping, matching the live-session floor in `AppModel.endWorkout`.
    /// The span-shaped door (used by the sheet) must enforce it too; doing so here lets Save disable itself
    /// and the existing validation note explain why.
    static let minManualSpanSeconds = 60

    static func endForDuration(start: Date, durationMin: Int) -> Date {
        Date(timeIntervalSince1970: start.timeIntervalSince1970 + TimeInterval(durationMin * 60))
    }

    static func spanDurationMin(start: Date, end: Date) -> Int {
        Int(((end.timeIntervalSince1970 - start.timeIntervalSince1970) / 60).rounded())
    }

    static func endAfterStartMove(oldStart: Date, oldEnd: Date, newStart: Date) -> Date {
        Date(timeIntervalSince1970: newStart.timeIntervalSince1970
             + (oldEnd.timeIntervalSince1970 - oldStart.timeIntervalSince1970))
    }

    /// Builds a retroactive manual workout from an explicit SPAN (the shape storage already uses;
    /// `buildManualRow` delegates here, #2034), so the sheet can offer an end time without a lossy round
    /// trip through whole minutes. A span must be positive, at most `maxManualSpanSeconds`, and must not
    /// end in the future.
    static func buildManualRowFromSpan(start: Date, end: Date, sport: String,
                                       avgHr: Int?, energyKcal: Double?, distanceM: Double? = nil,
                                       now: Date = Date()) -> WorkoutRow? {
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        guard s > 0, e > s else { return nil }
        let spanSeconds = e - s
        guard spanSeconds >= minManualSpanSeconds else { return nil }
        guard spanSeconds <= maxManualSpanSeconds else { return nil }
        guard e <= Int(now.timeIntervalSince1970) else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        // Distance 0-1000 km (#1195): rejects negative or absurd entries (an ultra is ~160 km).
        if let d = distanceM, d < 0 || d > 1_000_000 { return nil }
        return WorkoutRow(startTs: s, endTs: e, sport: trimmed, source: "manual",
                          durationS: Double(spanSeconds), energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: distanceM,
                          zonesJSON: nil, notes: nil, steps: nil)
    }

    /// Builds a retroactive manual workout (source "manual", persisted under the strap deviceId by the caller).
    /// Returns nil when the input can't make an honest row; strain/zones stay nil (no captured HR window, so
    /// no fabricated strain). The duration-shaped front door: delegates to `buildManualRowFromSpan` and keeps
    /// the whole-minute bounds and overflow guard that only this shape needs.
    static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, distanceM: Double? = nil,
                               now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        // Reject a row whose END lands in the future (`start <= now` alone lets start + duration overshoot);
        // ending exactly at `now` is valid (#1067). The end check lives in `buildManualRowFromSpan`; the overflow
        // guard stays HERE, before the Int -> TimeInterval -> Int round trip, which is exact for anything the
        // guards admit (~1.7e9 is far below 2^53).
        let durationSeconds = durationMin * 60
        guard durationSeconds <= Int.max - s else { return nil }
        return buildManualRowFromSpan(
            start: start,
            end: Date(timeIntervalSince1970: TimeInterval(s + durationSeconds)),
            sport: sport, avgHr: avgHr, energyKcal: energyKcal, distanceM: distanceM, now: now)
    }
}

// MARK: - Filter predicate (#64)
//
// Pure SPORT / SOURCE / free-text SEARCH filters that compose with the screen's time-range window.

/// One workout-list filter state. `sport` is a displayed-sport key (`WorkoutSource.displaySport`), nil =
/// all; `sourceClass` is the origin class, nil = all; `search` is a trimmed, case-insensitive query over
/// the displayed sport name (empty = none).
struct WorkoutFilter: Equatable {
    var sport: String?
    var sourceClass: WorkoutSource?
    var search: String

    init(sport: String? = nil, sourceClass: WorkoutSource? = nil, search: String = "") {
        self.sport = sport
        self.sourceClass = sourceClass
        self.search = search
    }

    var isActive: Bool {
        sport != nil || sourceClass != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func matches(_ row: WorkoutRow) -> Bool {
        if let sport, WorkoutSource.displaySport(row.sport) != sport { return false }
        if let sourceClass, WorkoutSource.classify(row.source) != sourceClass { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           WorkoutSource.displaySport(row.sport).range(of: q, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    func apply(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        guard isActive else { return rows }
        return rows.filter(matches)
    }
}

// MARK: - Merge (#64)
//
// Merges overlapping or adjacent MANUAL or DETECTED sessions into one. Imported history is read-only
// and never merged; persistence (Repository.mergeWorkouts) only writes through the manual-row path.

enum WorkoutMerge {

    static func isMergeable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }

    static func canMerge(_ rows: [WorkoutRow]) -> Bool {
        rows.count >= 2 && rows.allSatisfy(isMergeable)
    }

    /// The sport the merge carries: the most frequent non-"detected" sport (ties by first appearance), or nil
    /// when every input is a bare detected bout, in which case the caller asks the user to pick.
    static func resolvedSport(_ rows: [WorkoutRow]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in rows where r.sport != "detected" {
            let s = r.sport
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        return order.max(by: { (counts[$0] ?? 0, order.firstIndex(of: $1) ?? 0)
                                < (counts[$1] ?? 0, order.firstIndex(of: $0) ?? 0) })
    }

    /// Merges the rows into one manual row. `sport` overrides the resolved sport (when all inputs are detected
    /// and the user picked one); falls back to "Activity" only with no label. Nil for fewer than two rows.
    ///
    /// startTs = min, endTs = max; durationS = SUM of per-session durations (active time, not the span);
    /// energyKcal and distanceM = SUM; avgHr = duration-weighted mean over sessions that carry one;
    /// maxHr = max; strain = nil (rescored from strap HR via analyzeRecent, #598); zonesJSON = nil;
    /// notes = joined.
    static func merge(_ rows: [WorkoutRow], sport: String? = nil) -> WorkoutRow? {
        guard rows.count >= 2 else { return nil }
        let start = rows.map(\.startTs).min() ?? rows[0].startTs
        let end = rows.map(\.endTs).max() ?? rows[0].endTs

        let durationS = rows.reduce(0.0) { $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) }

        // Energy, distance and steps sum only present values; nil when NOTHING carried one (never a fake 0).
        // Steps are cumulative per session like distance, so a merge sums them (#1444).
        let kcals = rows.compactMap(\.energyKcal)
        let energyKcal = kcals.isEmpty ? nil : kcals.reduce(0, +)
        let dists = rows.compactMap(\.distanceM)
        let distanceM = dists.isEmpty ? nil : dists.reduce(0, +)
        let stepCounts = rows.compactMap(\.steps)
        let mergedSteps = stepCounts.isEmpty ? nil : stepCounts.reduce(0, +)

        // Avg HR is weighted by each row's duration (its span when nil) over rows that HAVE an avg; maxHr is
        // the max present peak; both nil when no row carried the field.
        var hrWeight = 0.0, hrSum = 0.0
        for r in rows {
            guard let hr = r.avgHr else { continue }
            let w = r.durationS ?? Double(max(1, r.endTs - r.startTs))
            hrWeight += w
            hrSum += Double(hr) * w
        }
        let avgHr = hrWeight > 0 ? Int((hrSum / hrWeight).rounded()) : nil
        let maxHrs = rows.compactMap(\.maxHr)
        let maxHr = maxHrs.max()

        let notes = rows.compactMap { $0.notes?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedNotes = notes.isEmpty ? nil : notes.joined(separator: " · ")

        let mergedSport = sport ?? resolvedSport(rows) ?? "Activity"

        return WorkoutRow(startTs: start, endTs: end, sport: mergedSport, source: "manual",
                          durationS: durationS, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                          strain: nil, distanceM: distanceM, zonesJSON: nil, notes: mergedNotes,
                          steps: mergedSteps)
    }
}
