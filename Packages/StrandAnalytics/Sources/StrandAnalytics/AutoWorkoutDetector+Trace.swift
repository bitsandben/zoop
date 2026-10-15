import Foundation
import WhoopProtocol

// Workouts & GPS test-mode trace and line formatters. `detectTrace` returns exactly what `detect`
// returns plus a trace of the detector's inputs, thresholds, and why each candidate window was offered
// or dropped. `WorkoutsTrace` owns the line shape; the app layer owns the live state. All pure, with no
// clock, I/O or PII (counts, bpm, seconds, sport keys). Callers gate on TestCentre.active(.workouts).

extension AutoWorkoutDetector {

    private struct ShadowPair {
        let candidateIndex: Int
        let savedIndex: Int
        let overlapS: Int
    }

    /// Diagnostic twin of `detect(...)`: returns the same `[DetectedWorkout]` verbatim plus a trace that
    /// logs inputs and thresholds, then walks the detector's gates (sustained-minutes, motion-confirm,
    /// saved-overlap) to name why each merged window survived or dropped.
    /// - Parameters mirror `detect(...)`. `minimumSustainedMinutes` defaults to the published 12-minute
    ///   policy; 10/15 are for local shadow diagnostics only. `path` tags the entry point
    ///   ("autoDetect" / "manualReview").
    public static func detectTrace(hr: [(ts: Int, bpm: Int)],
                                   restingBpm: Int?,
                                   motion: [MotionPoint]? = nil,
                                   savedSpans: [SavedWorkoutSpan] = [],
                                   minimumSustainedMinutes: Double = minSustainedMin,
                                   path: String = "autoDetect")
        -> (results: [DetectedWorkout], trace: [String]) {

        // The result the Today card reads, verbatim, so the trace cannot diverge.
        let results = detect(hr: hr, restingBpm: restingBpm, motion: motion,
                             savedSpans: savedSpans,
                             minimumSustainedMinutes: minimumSustainedMinutes)

        var lines: [String] = []
        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM
        let hasMotion = !(motion?.isEmpty ?? true)

        // Inputs the detector saw.
        lines.append("autoDetect path=\(path) hrSamples=\(hr.count) "
            + "restingBpm=\(restingBpm.map(String.init) ?? "default(\(defaultRestingHR))") "
            + "elevatedFloor=\(floor)bpm motion=\(hasMotion ? "supplied" : "hrOnly") savedSpans=\(savedSpans.count)")

        // Thresholds applied, stated once so a report carries the calibration.
        lines.append("autoDetect thresholds elevatedMargin=\(elevatedMarginBPM)bpm "
            + "minSustainedMin=\(minimumSustainedMinutes) maxDipS=\(maxDipS) mergeGapS=\(mergeGapS) "
            + "motionConfirmMean=\(motionConfirmMean)")

        // Rebuild the merged windows exactly as detect(...) steps 1-4 do (sustained spans tolerating dips, then
        // merge) to name why each survived without changing `results`; the verdict below mirrors steps 5-6.
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty {
            lines.append("autoDetect result windows=0 (no HR samples)")
            return (results, lines)
        }

        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int? = nil
        var spanEnd = 0
        var dipStart: Int? = nil
        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minimumSustainedMinutes * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }
        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil
            } else if spanStart != nil {
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()

        if spans.isEmpty {
            lines.append("autoDetect why=noSustainedSpan "
                + "(no contiguous run held >=\(minimumSustainedMinutes)min above \(floor)bpm)")
            lines.append("autoDetect result windows=0")
            return (results, lines)
        }

        // Merge spans whose gap is strictly < mergeGapS (detect step 4).
        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd < mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        // Per-window verdict, mirroring detect steps 5-6.
        let motionSeries = hasMotion ? motion : nil
        for (start, end) in merged {
            let durMin = (end - start) / 60
            let overlapping = savedSpans.filter { overlaps(start, end, $0.startSec, $0.endSec) }
                .sorted { $0.startSec == $1.startSec ? $0.endSec < $1.endSec : $0.startSec < $1.startSec }
            if !overlapping.isEmpty {
                // Measure each suppression before choosing a duration-aware policy (#2527). The exact saved/candidate
                // ratio avoids rounding away short recordings; intersection seconds separate a contained recording
                // from one mostly outside. Endpoint-only contact still suppresses and is reported as zero.
                let candidateSec = end - start
                for saved in overlapping {
                    let savedSec = max(0, saved.endSec - saved.startSec)
                    let overlapSec = max(0, min(end, saved.endSec) - max(start, saved.startSec))
                    lines.append("autoDetect savedOverlap candidateSec=\(candidateSec) savedSec=\(savedSec) "
                        + "overlapSec=\(overlapSec) savedToCandidate=\(savedSec)/\(candidateSec)")
                }
                lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=overlapsSavedWorkout")
                continue
            }
            if let motionSeries {
                let inWin = motionSeries.filter { $0.ts >= start && $0.ts <= end }.map { $0.intensity }
                let meanMotion = inWin.isEmpty ? 0.0 : inWin.reduce(0.0, +) / Double(inWin.count)
                if meanMotion < motionConfirmMean {
                    lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=motionNotConfirmed "
                        + "(mean=\((meanMotion * 1000).rounded() / 1000) < \(motionConfirmMean))")
                    continue
                }
            }
            lines.append("autoDetect window durMin=\(durMin) verdict=offered")
        }
        lines.append("autoDetect result windows=\(results.count) "
            + "(offered the most recent that is not saved or dismissed)")
        return (results, lines)
    }

    /// Compare shadow candidates with manual/imported labelled workouts without suppressing overlaps.
    /// Candidates and labels are canonical-sorted, then paired one-to-one by a deterministic weighted
    /// assignment: cardinality first, total overlap second, so results do not depend on iteration order.
    /// A match needs strictly positive overlap; endpoint contact is not evidence.
    ///
    /// With `hrForObservability`, a label is observable only when its longest HR run (no gap above the
    /// detector's 90 s dip tolerance) spans the shorter of the label duration and the policy's
    /// qualification duration, so two isolated points cannot manufacture a miss. Unobservable labels are
    /// reported separately. `matched` counts pairs, `unmatched` leftover candidates, `missed` leftover
    /// observable labels. Median onset/end errors are absolute seconds, or `n/a` with no match.
    ///
    /// The caller must exclude legacy auto-detected rows from `savedSpans`: shadow mode measures against
    /// user-confirmed/imported labels. Pure; returns aggregate counts only.
    public static func shadowComparisonLine(policyMinutes: Double,
                                            candidates: [DetectedWorkout],
                                            savedSpans: [SavedWorkoutSpan],
                                            hrForObservability: [(ts: Int, bpm: Int)]? = nil) -> String {
        let orderedCandidates = candidates.sorted {
            if $0.startSec != $1.startSec { return $0.startSec < $1.startSec }
            if $0.endSec != $1.endSec { return $0.endSec < $1.endSec }
            if $0.avgBpm != $1.avgBpm { return $0.avgBpm < $1.avgBpm }
            if $0.peakBpm != $1.peakBpm { return $0.peakBpm < $1.peakBpm }
            return $0.durationMin < $1.durationMin
        }
        let labelPartition = shadowLabelPartition(
            savedSpans: savedSpans,
            hr: hrForObservability,
            policyMinutes: policyMinutes)
        let orderedSaved = labelPartition.observable.sorted {
            if $0.startSec != $1.startSec { return $0.startSec < $1.startSec }
            return $0.endSec < $1.endSec
        }
        var possibleByCandidate = Array(repeating: [ShadowPair](), count: orderedCandidates.count)
        for (candidateIndex, candidate) in orderedCandidates.enumerated() {
            for (savedIndex, saved) in orderedSaved.enumerated() {
                let overlapS = min(candidate.endSec, saved.endSec)
                    - max(candidate.startSec, saved.startSec)
                guard overlapS > 0 else { continue }
                possibleByCandidate[candidateIndex].append(ShadowPair(
                    candidateIndex: candidateIndex,
                    savedIndex: savedIndex,
                    overlapS: overlapS))
            }
        }
        let matchedPairs = maximumCardinalityOverlapPairs(
            possibleByCandidate: possibleByCandidate,
            savedCount: orderedSaved.count)

        let onsetErrors = matchedPairs.map {
            abs(orderedCandidates[$0.candidateIndex].startSec - orderedSaved[$0.savedIndex].startSec)
        }
        let endErrors = matchedPairs.map {
            abs(orderedCandidates[$0.candidateIndex].endSec - orderedSaved[$0.savedIndex].endSec)
        }
        let matched = matchedPairs.count
        let missed = orderedSaved.count - matched
        let unmatched = candidates.count - matched
        return "workout shadow policy=\(shadowMinuteLabel(policyMinutes))min candidates=\(candidates.count) "
            + "matched=\(matched) missed=\(missed) unobservable=\(labelPartition.unobservableCount) "
            + "unmatched=\(unmatched) "
            + "medianOnsetErrorS=\(medianErrorLabel(onsetErrors)) "
            + "medianEndErrorS=\(medianErrorLabel(endErrors))"
    }

    /// Run the published policy plus the supported 10/15-minute alternatives for local shadow diagnostics,
    /// returning aggregate trace lines only. Labels are not passed into `detect`, which would suppress every
    /// true overlap before it could be measured. Nothing here is a published suggestion.
    public static func shadowComparisonLines(hr: [(ts: Int, bpm: Int)],
                                             restingBpm: Int?,
                                             motion: [MotionPoint]? = nil,
                                             savedSpans: [SavedWorkoutSpan],
                                             policies: [Double] = ([minSustainedMin]
                                                 + shadowSustainedMinutes).sorted()) -> [String] {
        policies.map { policy in
            let candidates = detect(hr: hr, restingBpm: restingBpm, motion: motion,
                                    minimumSustainedMinutes: policy)
            return shadowComparisonLine(policyMinutes: policy, candidates: candidates,
                                        savedSpans: savedSpans, hrForObservability: hr)
        }
    }

    /// Split labels by whether the HR input has enough contiguous-in-time coverage to evaluate this policy.
    private static func shadowLabelPartition(savedSpans: [SavedWorkoutSpan],
                                             hr: [(ts: Int, bpm: Int)]?,
                                             policyMinutes: Double)
        -> (observable: [SavedWorkoutSpan], unobservableCount: Int) {
        guard let hr else { return (savedSpans, 0) }
        let timestamps = Array(Set(hr.map(\.ts))).sorted()
        var observable: [SavedWorkoutSpan] = []
        observable.reserveCapacity(savedSpans.count)
        for span in savedSpans {
            let labelDuration = max(0, span.endSec - span.startSec)
            let requiredCoverage = min(Double(labelDuration), max(0, policyMinutes * 60.0))
            var runStart: Int?
            var previousTimestamp: Int?
            var longestRun = 0
            for timestamp in timestamps {
                if timestamp < span.startSec { continue }
                if timestamp > span.endSec { break }
                if let previousTimestamp, timestamp - previousTimestamp > maxDipS {
                    runStart = timestamp
                } else if runStart == nil {
                    runStart = timestamp
                }
                if let runStart { longestRun = max(longestRun, timestamp - runStart) }
                previousTimestamp = timestamp
            }
            if longestRun > 0, Double(longestRun) >= requiredCoverage { observable.append(span) }
        }
        return (observable, savedSpans.count - observable.count)
    }

    /// Hungarian assignment over candidate rows and saved-label + dummy columns. Each positive-overlap edge
    /// gets a cardinality bonus larger than any possible total overlap, so the objective is lexicographic:
    /// match count, then summed overlap. Canonical order and lowest-column tie breaks keep it deterministic.
    private static func maximumCardinalityOverlapPairs(possibleByCandidate: [[ShadowPair]],
                                                       savedCount: Int) -> [ShadowPair] {
        let candidateCount = possibleByCandidate.count
        guard candidateCount > 0, savedCount > 0,
              let maxOverlap = possibleByCandidate.flatMap({ $0 }).map(\.overlapS).max()
        else { return [] }

        let maximumMatches = min(candidateCount, savedCount)
        let cardinalityBonus = Int64(maxOverlap) * Int64(maximumMatches) + 1
        let columnCount = savedCount + candidateCount
        var weights = Array(
            repeating: Array(repeating: Int64(0), count: columnCount),
            count: candidateCount)
        for options in possibleByCandidate {
            for option in options {
                weights[option.candidateIndex][option.savedIndex] =
                    cardinalityBonus + Int64(option.overlapS)
            }
        }

        // Minimum-cost Hungarian algorithm over negated weights; `p[column]` is its assigned 1-based row.
        var rowPotential = Array(repeating: Int64(0), count: candidateCount + 1)
        var columnPotential = Array(repeating: Int64(0), count: columnCount + 1)
        var assignedRow = Array(repeating: 0, count: columnCount + 1)
        var previousColumn = Array(repeating: 0, count: columnCount + 1)
        let infinity = Int64.max / 4

        for row in 1...candidateCount {
            assignedRow[0] = row
            var currentColumn = 0
            var minimumReducedCost = Array(repeating: infinity, count: columnCount + 1)
            var usedColumn = Array(repeating: false, count: columnCount + 1)
            repeat {
                usedColumn[currentColumn] = true
                let currentRow = assignedRow[currentColumn]
                var delta = infinity
                var nextColumn = 0
                for column in 1...columnCount where !usedColumn[column] {
                    let cost = -weights[currentRow - 1][column - 1]
                    let reducedCost = cost - rowPotential[currentRow] - columnPotential[column]
                    if reducedCost < minimumReducedCost[column] {
                        minimumReducedCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if minimumReducedCost[column] < delta {
                        delta = minimumReducedCost[column]
                        nextColumn = column
                    }
                }
                for column in 0...columnCount {
                    if usedColumn[column] {
                        rowPotential[assignedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimumReducedCost[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while assignedRow[currentColumn] != 0

            repeat {
                let prior = previousColumn[currentColumn]
                assignedRow[currentColumn] = assignedRow[prior]
                currentColumn = prior
            } while currentColumn != 0
        }

        var matches: [ShadowPair] = []
        for savedColumn in 1...savedCount {
            let candidateRow = assignedRow[savedColumn]
            guard candidateRow > 0,
                  let pair = possibleByCandidate[candidateRow - 1]
                    .first(where: { $0.savedIndex == savedColumn - 1 })
            else { continue }
            matches.append(pair)
        }
        return matches.sorted {
            if $0.candidateIndex != $1.candidateIndex { return $0.candidateIndex < $1.candidateIndex }
            return $0.savedIndex < $1.savedIndex
        }
    }

    /// Locale-independent policy label.
    private static func shadowMinuteLabel(_ value: Double) -> String {
        if value.isFinite, abs(value) < 1e15, value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func medianErrorLabel(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if !sorted.count.isMultiple(of: 2) { return String(sorted[middle]) }
        return shadowMinuteLabel((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2.0)
    }
}

/// Pure line formatters for the Workouts & GPS test mode. The app-target emitters own the live state;
/// these own the line shape. No state, side effects or PII (counts, seconds, sport keys).
public enum WorkoutsTrace {

    /// A session-lifecycle line. `event` is "start" / "end" / "discarded"; counts are the captured HR window
    /// size and, for an end, the duration and whether a GPS route landed. Sport is the normalised key.
    public static func sessionLine(event: String,
                                   sportKey: String,
                                   hrSamples: Int,
                                   durationSec: Int? = nil,
                                   gpsPoints: Int? = nil) -> String {
        var line = "session event=\(event) sport=\(sportKey) hrSamples=\(hrSamples)"
        if let durationSec { line += " durationSec=\(durationSec)" }
        if let gpsPoints { line += " gpsPoints=\(gpsPoints)" }
        return line
    }

    /// A GPS-fix-progress line: raw fixes seen, fixes the accuracy/speed filter accepted, running distance.
    /// `rawFixes` is optional: a platform that pre-filters upstream has no raw count and passes nil, and the
    /// line renders `rawFixes=n/a` rather than implying an accept rate it cannot measure.
    public static func gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double) -> String {
        "gps rawFixes=\(rawFixes.map(String.init) ?? "n/a") accepted=\(acceptedPoints) "
            + "distanceM=\(Int(distanceM.rounded())) (filter: accuracy+speed gate)"
    }

    /// An analytics detected-bout decision line. A bout is derived from raw HR/motion for scoring and
    /// enrichment but never creates a visible generic workout. No real overlap is `analyticsOnly`; overlap
    /// with a manual/imported row is `droppedOverlapBackfilled` when the bout supplied missing metrics,
    /// else `droppedOverlap`, and `overlapSource` names the row. `durMin` is whole minutes.
    public static func detectedBoutLine(verdict: String,
                                        durMin: Int,
                                        avgBpm: Int,
                                        overlapSource: String? = nil) -> String {
        var line = "detectedBout verdict=\(verdict) durMin=\(durMin) avgBpm=\(avgBpm)"
        if let overlapSource { line += " overlapSource=\(overlapSource)" }
        return line
    }

    /// A cross-source dedup decision line: two same-activity rows from different sources collapsed to the
    /// richer one. Reports the sources, kept richness and overlap.
    public static func dedupLine(sportKey: String,
                                 keptSource: String,
                                 droppedSource: String,
                                 keptRichness: Int,
                                 droppedRichness: Int) -> String {
        "dedup sport=\(sportKey) kept=\(keptSource)(richness=\(keptRichness)) "
            + "dropped=\(droppedSource)(richness=\(droppedRichness)) (same activity, richer kept)"
    }
}

/// Parses the `.workouts`-tagged log tail back into values for the live-readout panel, so it reflects
/// the last session without new published properties. Pure.
public enum WorkoutsReadout {

    /// The most recent session-lifecycle line's fragment (event, sport, counts), or nil when none is present.
    public static func lastSessionSummary(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "session ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }
}
