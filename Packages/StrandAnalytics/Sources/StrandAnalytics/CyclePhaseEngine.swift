import Foundation

// CyclePhaseEngine.swift - on-device menstrual-cycle phase awareness from the nightly skin-temperature
// series, corroborated by the luteal resting-HR rise and luteal HRV drop. Pure, DB-free.
//
// Method: wrist skin temperature runs roughly 0.3-0.5 C higher in the luteal phase (biphasic
// ovulatory shift, e.g. PMC11294004), mirrored by a resting-HR rise and an RMSSD drop. Derived from
// the user's own banked nights against their own baseline.
//
// Awareness only, approximate. NOT contraception, a fertility predictor, a medical device or a
// diagnosis: never a "fertile window" or "safe days", never a single confident period date (only a
// probabilistic window), and a flat or irregular signal says "no clear pattern", never a verdict.
public enum CyclePhaseEngine {

    // MARK: - Tuning constants (pinned by test)

    /// Weights for the fused luteal index z = wTemp*zTemp + wRHR*zRHR + wHRV*(-zHRV). Temperature
    /// dominates; the HRV term is negated so a drop pushes the index up like temp and RHR.
    public static let wTemp: Double = 0.6
    public static let wRHR: Double = 0.2
    public static let wHRV: Double = 0.2

    /// A night is "elevated" when its fused index sits at least this many spreads above the personal
    /// series mean. Spread is the median absolute deviation, so a few extreme nights don't widen the gate.
    public static let elevationK: Double = 0.5

    /// Plausibility clamp on the estimated cycle length (days); outside it reads "no clear pattern".
    public static let minCycleDays: Int = 21
    public static let maxCycleDays: Int = 40
    /// Textbook cycle length used as the next-period prior when the personal median isn't reliable yet.
    public static let defaultCycleDays: Int = 28

    /// Minimum nights of usable data before classifying at all (~1.5 cycles).
    public static let minNightsToClassify: Int = 42

    /// Half-width (days) of the peri-ovulatory band around the estimated elevation onset.
    public static let periOvulatoryHalfWidth: Int = 2

    // MARK: - Inputs

    /// One night's standardized inputs. `tempZ` / `rhrZ` / `hrvZ` are z-scores from `Baselines.deviation`
    /// (computed by the caller to keep the engine I/O-free); `day` is "yyyy-MM-dd", oldest to newest.
    /// A nil signal simply doesn't contribute to that night's fused index.
    public struct Night: Equatable, Sendable {
        public let day: String
        public let tempZ: Double?
        public let rhrZ: Double?
        public let hrvZ: Double?
        public init(day: String, tempZ: Double?, rhrZ: Double?, hrvZ: Double?) {
            self.day = day; self.tempZ = tempZ; self.rhrZ = rhrZ; self.hrvZ = hrvZ
        }
    }

    // MARK: - Output

    public enum Phase: String, Equatable, Sendable, Codable {
        case follicular
        case periOvulatory
        case luteal
        case unknown        // no clear pattern — NEVER a fabricated phase
        case learning       // not enough data yet
    }

    public enum Confidence: String, Equatable, Sendable, Codable {
        case learning       // < minNightsToClassify, or baseline not usable
        case building       // classifies, but the cadence is still coarse (one elevation seen)
        case solid          // a stable repeating shift detected
    }

    /// A detected follicular-to-luteal temperature shift onset (for the curve markers).
    public struct ShiftMarker: Equatable, Sendable {
        public let day: String
        public init(day: String) { self.day = day }
    }

    /// A probabilistic next-period window: always a range of days, never a single date.
    public struct NextPeriodWindow: Equatable, Sendable {
        public let earliestDay: String
        public let latestDay: String
        public init(earliestDay: String, latestDay: String) {
            self.earliestDay = earliestDay; self.latestDay = latestDay
        }
    }

    public struct Result: Equatable, Sendable {
        public let phase: Phase
        public let confidence: Confidence
        /// Inclusive cycle-day estimate as a range (nil when unknown or learning).
        public let cycleDayLow: Int?
        public let cycleDayHigh: Int?
        /// Estimated personal cycle length in days (nil until a repeat is seen).
        public let cycleLengthDays: Int?
        /// Probabilistic next-period window (nil unless a usable cadence and recent elevation exist).
        public let nextPeriodWindow: NextPeriodWindow?
        public let shiftMarkers: [ShiftMarker]
        public let note: String

        public init(phase: Phase, confidence: Confidence, cycleDayLow: Int?, cycleDayHigh: Int?,
                    cycleLengthDays: Int?, nextPeriodWindow: NextPeriodWindow?,
                    shiftMarkers: [ShiftMarker], note: String) {
            self.phase = phase; self.confidence = confidence
            self.cycleDayLow = cycleDayLow; self.cycleDayHigh = cycleDayHigh
            self.cycleLengthDays = cycleLengthDays; self.nextPeriodWindow = nextPeriodWindow
            self.shiftMarkers = shiftMarkers; self.note = note
        }
    }

    public static let awarenessLine =
        "For awareness only. Not a medical device, not contraception, not a substitute for professional care."

    // MARK: - Classify

    /// Classifies the most recent night from the trailing series.
    ///
    /// - Parameters:
    ///   - nights: oldest to newest nightly inputs.
    ///   - baselineUsable: whether the skin-temp baseline is `usable`; below that we stay `.learning`.
    ///   - loggedPeriodStarts: optional "yyyy-MM-dd" logged starts. The latest anchors cycle-day 1 and is
    ///     cross-validated against the detected shift (a mistimed log is flagged, not trusted).
    public static func classify(_ nights: [Night],
                                baselineUsable: Bool,
                                loggedPeriodStarts: [String] = []) -> Result {
        // Gate: a usable baseline and ~1.5 cycles of data.
        guard baselineUsable, nights.count >= minNightsToClassify else {
            return Result(phase: .learning, confidence: .learning, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: [],
                          note: "Learning your pattern from your nightly temperature - keep wearing it overnight.")
        }

        // Fuse each night into one luteal index; nil where there is no signal.
        let fused: [(day: String, value: Double?)] = nights.map { n in
            (n.day, fusedIndex(tempZ: n.tempZ, rhrZ: n.rhrZ, hrvZ: n.hrvZ))
        }
        let values = fused.compactMap { $0.value }
        guard values.count >= minNightsToClassify else {
            return Result(phase: .learning, confidence: .learning, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: [],
                          note: "Learning your pattern from your nightly temperature - keep wearing it overnight.")
        }

        let center = median(values)
        let spread = max(1e-9, medianAbsoluteDeviation(values, center: center))

        // Per-night elevated flag (luteal-ward run detection).
        let elevated: [Bool] = fused.map { row in
            guard let v = row.value else { return false }
            return (v - center) >= elevationK * spread
        }

        // Rising edges (follicular to luteal onsets) are the temperature-shift markers.
        var onsets: [Int] = []
        for i in fused.indices {
            if elevated[i] && (i == 0 || !elevated[i - 1]) { onsets.append(i) }
        }
        let shiftMarkers = onsets.map { ShiftMarker(day: fused[$0].day) }

        // No detectable shift: honest "no clear pattern", never a fabricated phase.
        guard let lastOnsetIdx = onsets.last else {
            return Result(phase: .unknown, confidence: .building, cycleDayLow: nil, cycleDayHigh: nil,
                          cycleLengthDays: nil, nextPeriodWindow: nil, shiftMarkers: shiftMarkers,
                          note: "No clear temperature pattern yet - this can happen with irregular cycles, "
                              + "hormonal birth control, or shift work.")
        }

        // Personal cycle length = median gap between successive onsets (calendar days).
        var onsetGaps: [Int] = []
        if onsets.count >= 2 {
            for k in 1..<onsets.count {
                if let d = daysBetween(fused[onsets[k - 1]].day, fused[onsets[k]].day) { onsetGaps.append(d) }
            }
        }
        let medianGap = onsetGaps.isEmpty ? nil : Int(median(onsetGaps.map(Double.init)).rounded())
        let cycleLength: Int? = {
            guard let g = medianGap, g >= minCycleDays, g <= maxCycleDays else { return nil }
            return g
        }()
        let confidence: Confidence = cycleLength != nil ? .solid : .building

        // The latest logged start on or before the last night anchors cycle-day 1; compare it to the onset.
        let lastNightDay = fused.last!.day
        var note = ""
        var anchorDay = fused[lastOnsetIdx].day      // default anchor = the temperature shift onset
        var anchoredByLog = false
        if let loggedStart = mostRecentOnOrBefore(loggedPeriodStarts, day: lastNightDay) {
            anchorDay = loggedStart
            anchoredByLog = true
            let delta = daysBetween(loggedStart, fused[lastOnsetIdx].day)
            // The shift sits well after period start in a normal cycle, so an implausible offset, or a logged
            // start older than a full cycle (a newer period is overdue), flags the log as likely mistimed.
            let sinceLog = daysBetween(loggedStart, lastNightDay) ?? 0
            if (delta.map { $0 < 0 || $0 > maxCycleDays } ?? false) || sinceLog > maxCycleDays {
                note = "Your temperature shift came at a different time than your logged date - "
                    + "the logged start may be off."
            }
        }

        // Cycle-day range: from the log if anchored, else from the shift onset (start of luteal, ~day
        // 14-16) offset by a follicular-length prior.
        let daysSinceAnchor = daysBetween(anchorDay, lastNightDay) ?? 0
        let (cycleDayLow, cycleDayHigh): (Int?, Int?) = {
            if anchoredByLog {
                let d = max(1, daysSinceAnchor + 1)
                return (max(1, d - 1), d + 1)             // ±1 day band
            } else {
                // Onset ~ luteal start; place near a typical follicular length and widen the band.
                let lutealStartDay = (cycleLength ?? defaultCycleDays) / 2
                let d = lutealStartDay + daysSinceAnchor
                return (max(1, d - 2), d + 2)             // ±2 day band (coarser without a log)
            }
        }()

        // Phase of the most recent night relative to the latest onset.
        let daysSinceOnset = daysBetween(fused[lastOnsetIdx].day, lastNightDay) ?? 0
        let phase: Phase
        if elevated[fused.count - 1] {
            // In an elevated run: luteal, unless right at the onset edge (peri-ovulatory).
            phase = daysSinceOnset <= periOvulatoryHalfWidth ? .periOvulatory : .luteal
        } else {
            // Below the gate: peri-ovulatory dip near a known onset, otherwise follicular.
            phase = daysSinceOnset <= periOvulatoryHalfWidth ? .periOvulatory : .follicular
        }

        // Next-period window: the luteal-to-follicular drop precedes menses, so roughly one cycle length
        // after the anchor. Always a range.
        var window: NextPeriodWindow? = nil
        if let len = cycleLength {
            // Window = anchor + cycle length +/- 2 days, surfaced only once in range and on/after the anchor.
            if let earliest = shiftDay(anchorDay, by: len - 2),
               let latest = shiftDay(anchorDay, by: len + 2),
               latest >= lastNightDay {
                window = NextPeriodWindow(earliestDay: max(lastNightDay, earliest), latestDay: latest)
            }
        }

        if note.isEmpty {
            note = phaseNote(phase)
        }

        return Result(phase: phase, confidence: confidence,
                      cycleDayLow: cycleDayLow, cycleDayHigh: cycleDayHigh,
                      cycleLengthDays: cycleLength, nextPeriodWindow: window,
                      shiftMarkers: shiftMarkers, note: note)
    }

    // MARK: - Fusion

    /// Weighted fused luteal index for one night. HRV z is negated; weights renormalise over the
    /// signals present, so a temp-only night still scores.
    public static func fusedIndex(tempZ: Double?, rhrZ: Double?, hrvZ: Double?) -> Double? {
        var weighted = 0.0
        var wSum = 0.0
        if let t = tempZ { weighted += wTemp * t; wSum += wTemp }
        if let r = rhrZ { weighted += wRHR * r; wSum += wRHR }
        if let h = hrvZ { weighted += wHRV * (-h); wSum += wHRV }
        guard wSum > 0 else { return nil }
        return weighted / wSum
    }

    // MARK: - Copy

    static func phaseNote(_ phase: Phase) -> String {
        switch phase {
        case .follicular:
            return "Follicular range - temperature sitting at your baseline."
        case .periOvulatory:
            return "Around your mid-cycle shift - temperature is turning."
        case .luteal:
            return "Luteal range - temperature is running above your baseline."
        case .unknown:
            return "No clear pattern yet."
        case .learning:
            return "Learning your pattern - keep wearing it overnight."
        }
    }

    // MARK: - Small stats / day helpers (self-contained to keep the engine I/O-free)

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// Median absolute deviation about `center` (robust spread).
    static func medianAbsoluteDeviation(_ xs: [Double], center: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        return median(xs.map { abs($0 - center) })
    }

    /// Calendar days from `a` to `b` ("yyyy-MM-dd"), b - a; nil if unparseable. UTC.
    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = parseDay(a), let db = parseDay(b) else { return nil }
        let secs = db.timeIntervalSince(da)
        return Int((secs / 86_400).rounded())
    }

    /// Most recent entry in `days` on or before `day` (ISO strings compare correctly).
    static func mostRecentOnOrBefore(_ days: [String], day: String) -> String? {
        days.filter { $0 <= day }.max()
    }

    static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= 31 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)
    }

    /// Shifts a "yyyy-MM-dd" by `delta` days (UTC); nil if unparseable.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        guard let base = parseDay(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}
