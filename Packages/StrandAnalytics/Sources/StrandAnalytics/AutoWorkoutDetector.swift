import Foundation
import WhoopProtocol

// Opt-in "did you just work out?" detector, separate from `WorkoutDetector` (which scores and
// enriches logged workouts). It only suggests a workout via a dismissible Today card and never
// writes a row itself. Published policy: a sustained 12-min or longer elevation of HR at or above
// resting + 30 bpm, dips up to 90 s tolerated, near windows merged. Deliberately conservative: it may
// miss a short or gentle session, which suits a suggestion. An optional motion series, when present,
// is required as confirmation; otherwise HR-only.
// The 10- and 15-minute alternatives are shadow policies for Test Centre comparison only and must not
// drive the Today card, persistence, classification or scores until validated.
// Pure: no I/O or clock; all timestamps are unix seconds. Not medical advice.

/// A candidate workout window the user can accept (Save) or dismiss, derived purely from the HR
/// samples inside it.
public struct DetectedWorkout: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    /// Whole minutes: floor of (endSec - startSec) / 60.
    public let durationMin: Int

    public init(startSec: Int, endSec: Int, avgBpm: Int, peakBpm: Int, durationMin: Int) {
        self.startSec = startSec
        self.endSec = endSec
        self.avgBpm = avgBpm
        self.peakBpm = peakBpm
        self.durationMin = durationMin
    }
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude overlapping windows so a
/// logged session is never re-suggested.
public struct SavedWorkoutSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public init(startSec: Int, endSec: Int) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public enum AutoWorkoutDetector {

    // MARK: - Constants (keep byte-identical with the Kotlin twin)

    /// Elevated gate: bpm must be at least restingHR + this margin to count as working.
    public static let elevatedMarginBPM = 30
    /// Minimum contiguous span (minutes) holding the elevated gate.
    public static let minSustainedMin: Double = 12.0
    /// Duration policies evaluated only by local Test Centre shadow diagnostics; the published path uses `minSustainedMin`.
    public static let shadowSustainedMinutes: [Double] = [10.0, 15.0]
    /// A dip below the gate no longer than this does not break the span (a red light, a sip of water).
    public static let maxDipS = 90
    /// Two windows whose gap is strictly less than this (5 min) are merged.
    public static let mergeGapS = 5 * 60
    /// With a motion series, a window must also have mean per-second motion intensity (L2 gravity delta)
    /// at least this. Ignored in HR-only mode.
    public static let motionConfirmMean = 0.05
    /// Resting-HR fallback when the caller has no nightly RHR for the day.
    public static let defaultRestingHR = 60

    // MARK: - Inputs

    /// One motion-intensity reading aligned to the HR timeline (optional confirmation), on the same
    /// L2-gravity-delta scale as `WorkoutDetector.activitySeries`.
    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) {
            self.ts = ts
            self.intensity = intensity
        }
    }

    /// Per-second motion intensity: L2 magnitude of the gravity change vs the previous record (first row 0).
    public static func motionPoints(_ gravity: [GravitySample]) -> [MotionPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var out: [MotionPoint] = []
        out.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0, prev == nil {
                intensity = 0.0
            } else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else {
                intensity = 0.0
            }
            out.append(MotionPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return out
    }

    // MARK: - Public API

    /// Detect candidate sustained-elevated-HR workout windows.
    /// 1. Sort HR ascending; floor = restingHR + `elevatedMarginBPM`; elevated means bpm >= floor.
    /// 2. Grow a span across elevated samples, tolerating a non-elevated run only while its duration from
    ///    the first sub-threshold sample stays <= `maxDipS`. Bounds are the first/last elevated timestamps.
    /// 3. Keep a span only if it lasts >= `minimumSustainedMinutes` (before merge).
    /// 4. Merge kept spans whose gap is strictly < `mergeGapS`.
    /// 5. With a motion series, drop a window whose mean intensity is < `motionConfirmMean`; HR-only keeps it.
    /// 6. Drop a window overlapping any saved span (touching endpoints count).
    /// 7. Emit a `DetectedWorkout` (avg/peak bpm, whole-minute duration) per survivor.
    ///
    /// - Parameters:
    ///   - hr: HR samples `[(ts, bpm)]` in any order; empty gives [].
    ///   - restingBpm: nightly resting HR; nil uses `defaultRestingHR`.
    ///   - motion: optional motion series for confirmation; nil/empty is HR-only.
    ///   - savedSpans: already-saved windows to exclude by overlap.
    ///   - minimumSustainedMinutes: defaults to the published policy; `shadowSustainedMinutes` values are
    ///     for local shadow diagnostics only.
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [MotionPoint]? = nil,
                              savedSpans: [SavedWorkoutSpan] = [],
                              minimumSustainedMinutes: Double = minSustainedMin) -> [DetectedWorkout] {
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty { return [] }

        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM

        // Steps 1-3: grow sustained spans tolerating brief dips. `dipStart` marks where the current
        // sub-threshold run began (nil = not in a dip).
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
                dipStart = nil   // the dip (if any) is bridged
            } else if spanStart != nil {
                // Tolerate the dip until it runs longer than maxDipS (`dipStart` is set once, cleared on the next elevated sample).
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()

        if spans.isEmpty { return [] }

        // Step 4: merge spans whose gap is strictly < mergeGapS (spans are start-ascending).
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

        // Steps 5-7
        let motionSeries = (motion?.isEmpty ?? true) ? nil : motion
        var results: [DetectedWorkout] = []
        for (start, end) in merged {
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) { continue }

            let window = seg.filter { $0.ts >= start && $0.ts <= end }
            if window.isEmpty { continue }

            if let motionSeries = motionSeries {
                let inWin = motionSeries.filter { $0.ts >= start && $0.ts <= end }.map { $0.intensity }
                let meanMotion = inWin.isEmpty ? 0.0 : inWin.reduce(0.0, +) / Double(inWin.count)
                if meanMotion < motionConfirmMean { continue }
            }

            let bpms = window.map { $0.bpm }
            let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
            let peak = bpms.max() ?? avg
            let durMin = (end - start) / 60
            results.append(DetectedWorkout(startSec: start, endSec: end,
                                           avgBpm: avg, peakBpm: peak, durationMin: durMin))
        }
        return results
    }

    /// Closed intervals overlap (touching endpoints count).
    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }
}
