import Foundation

// CircadianEngine.swift - on-device body-clock phase estimate plus a jet-lag / shift-work light and
// sleep-timing plan. Pure, deterministic, DB-free.
//
// Methods:
//   - Single-component cosinor (Halberg) over the rest-activity rhythm: fit M + A*cos(2*pi*(t - phi)/24)
//     by least squares to get amplitude and acrophase (peak-activity clock time). The core-body-
//     temperature minimum (CBTmin) sits ~2-3 h before habitual wake and corroborates the phase.
//   - Phase-response-curve direction rule: to ADVANCE the clock, bright light in the morning and
//     earlier sleep, stepped ~1 h/day; to DELAY, bright light in the evening.
//
// Wellness awareness only, approximate. Light and sleep timing only: never melatonin or any
// supplement, never a guaranteed outcome. Irregular schedules get "your rhythm is hard to read".
public enum CircadianEngine {

    // MARK: - Tuning constants (pinned by test)

    /// Minimum days with a usable activity profile before a stable cosinor fit is reported.
    public static let minDaysForFit: Int = 7
    public static let goodDaysForFit: Int = 14
    /// A cosinor fit with amplitude below this fraction of the mesor is "arrhythmic" (too flat to phase).
    ///
    /// Applied to mean HR (`ActivityBin`), whose mesor is ~45-75 bpm, so the effective bar is
    /// `0.10 x mesor` (about 6.5 bpm at 65, 4.5 at 45) and scales with the mesor (#982).
    /// `minAbsoluteAmplitudeBpm` is the escape hatch for large-mesor wearers. `CircadianEngineTests`
    /// pins what the gate costs at each mesor.
    public static let minRelativeAmplitude: Double = 0.10
    /// Absolute amplitude (bpm) that reads as rhythmic whatever the mesor.
    ///
    /// The relative test alone refused the same swing on a high-resting wearer that it accepted on a
    /// low one (5.5 bpm passes at a 55 bpm mesor, fails at 74.7). 4.5 bpm is the absolute amplitude the
    /// relative gate already accepts at the bottom of its mesor range, so this is strictly more permissive.
    public static let minAbsoluteAmplitudeBpm: Double = 4.5
    /// Max clock-shift the planner steps per day (hours): the ~1 h/day re-entrainment rate.
    public static let maxShiftPerDayHours: Double = 1.0
    /// CBTmin sits roughly this many hours before habitual wake; used to turn the activity acrophase
    /// into an estimated temperature-minimum time when the thermal series is thin.
    public static let cbtMinBeforeWakeHours: Double = 2.5
    /// Activity acrophase sits roughly this many hours after CBTmin in a typical day.
    public static let acrophaseAfterCbtMinHours: Double = 12.0
    /// Population-typical wake hour, used only to place the chronotype reference point.
    ///
    /// `offsetVsScheduleMinutes` is relative to the user's own schedule and cannot name a chronotype
    /// (a reliable 03:00-11:00 sleeper reads near zero), so the lean is bucketed from the absolute
    /// `tempMinHour` against this reference.
    public static let chronotypeReferenceWakeHour: Double = 7.0
    /// Half-width of the "intermediate" band around the reference CBTmin, in hours.
    ///
    /// Deliberately wide: `tempMinHour` is inferred from an activity cosinor unless a measured
    /// `observedTempMinHour` is supplied (no production caller does), so the buckets stay coarse.
    public static let chronotypeBandHours: Double = 1.0

    // MARK: - Inputs

    /// One per-hour rest-activity sample: the local clock hour (0..<24, may be fractional) and the
    /// rhythm signal in that bin. Higher = more active.
    ///
    /// Production feeds per-hour mean heart rate in bpm (WHOOP 4.0 motion is too sparse, #345), which
    /// carries a large DC offset; see `minRelativeAmplitude` for what the gate costs in bpm.
    public struct ActivityBin: Equatable, Sendable {
        public let hour: Double
        public let activity: Double
        public init(hour: Double, activity: Double) {
            self.hour = hour; self.activity = activity
        }
    }

    // MARK: - Cosinor

    /// A single-component cosinor fit: y ≈ mesor + amplitude·cos(2π(hour − acrophaseHours)/24).
    public struct CosinorFit: Equatable, Sendable {
        public let mesor: Double         // rhythm-adjusted mean
        public let amplitude: Double     // half the peak-to-trough swing (≥ 0)
        public let acrophaseHours: Double // clock hour of the activity PEAK, in [0, 24)
        public init(mesor: Double, amplitude: Double, acrophaseHours: Double) {
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseHours = acrophaseHours
        }
    }

    /// Fits a single 24 h cosine to the (hour, activity) bins by ordinary least squares.
    ///
    /// Model: y = M + b*cos(wt) + g*sin(wt), w = 2*pi/24; amplitude = sqrt(b^2 + g^2); acrophase =
    /// atan2(g, b) as a clock hour in [0, 24). Nil with fewer than 3 distinct points or zero variance.
    public static func cosinor(_ bins: [ActivityBin]) -> CosinorFit? {
        guard bins.count >= 3 else { return nil }
        let w = 2.0 * Double.pi / 24.0
        let n = Double(bins.count)

        var sumY = 0.0, sumC = 0.0, sumS = 0.0
        var sumCC = 0.0, sumSS = 0.0, sumCS = 0.0
        var sumYC = 0.0, sumYS = 0.0
        for b in bins {
            let c = cos(w * b.hour)
            let s = sin(w * b.hour)
            let y = b.activity
            sumY += y; sumC += c; sumS += s
            sumCC += c * c; sumSS += s * s; sumCS += c * s
            sumYC += y * c; sumYS += y * s
        }

        // Solve the 3x3 normal equations for (M, b, g) via Cramer's rule.
        let a11 = n,    a12 = sumC,  a13 = sumS
        let a21 = sumC, a22 = sumCC, a23 = sumCS
        let a31 = sumS, a32 = sumCS, a33 = sumSS
        let det = a11 * (a22 * a33 - a23 * a32)
                - a12 * (a21 * a33 - a23 * a31)
                + a13 * (a21 * a32 - a22 * a31)
        guard abs(det) > 1e-12 else { return nil }

        let detM = sumY * (a22 * a33 - a23 * a32)
                 - a12  * (sumYC * a33 - a23 * sumYS)
                 + a13  * (sumYC * a32 - a22 * sumYS)
        let detB = a11 * (sumYC * a33 - a23 * sumYS)
                 - sumY * (a21 * a33 - a23 * a31)
                 + a13  * (a21 * sumYS - sumYC * a31)
        let detG = a11 * (a22 * sumYS - sumYC * a32)
                 - a12 * (a21 * sumYS - sumYC * a31)
                 + sumY * (a21 * a32 - a22 * a31)

        let m = detM / det
        let beta = detB / det
        let gamma = detG / det

        let amplitude = (beta * beta + gamma * gamma).squareRoot()
        // Peak time: cos(w(t - phi)) is maximal where w(t - phi) = 0.
        var phase = atan2(gamma, beta) / w           // hours
        phase = phase.truncatingRemainder(dividingBy: 24.0)
        if phase < 0 { phase += 24.0 }
        return CosinorFit(mesor: m, amplitude: amplitude, acrophaseHours: phase)
    }

    // MARK: - Phase estimate

    public enum PhaseConfidence: String, Equatable, Sendable, Codable {
        case unreadable     // too few days / arrhythmic — "hard to read right now"
        case wide           // a fit, but thin data → wide band
        case solid          // a stable fit over enough days
    }

    public struct PhaseEstimate: Equatable, Sendable {
        /// Estimated clock hour of the body-clock temperature minimum, in [0, 24).
        public let tempMinHour: Double
        /// Estimated activity acrophase (peak activity clock hour).
        public let acrophaseHours: Double
        /// Signed minutes the body clock leads (-) or lags (+) the user's own sleep schedule.
        public let offsetVsScheduleMinutes: Double
        public let confidence: PhaseConfidence
        public let note: String
        public init(tempMinHour: Double, acrophaseHours: Double, offsetVsScheduleMinutes: Double,
                    confidence: PhaseConfidence, note: String) {
            self.tempMinHour = tempMinHour; self.acrophaseHours = acrophaseHours
            self.offsetVsScheduleMinutes = offsetVsScheduleMinutes
            self.confidence = confidence; self.note = note
        }
    }

    /// Estimates the body-clock phase from a pooled activity profile and the user's habitual wake time.
    ///
    /// - Parameters:
    ///   - bins: pooled per-hour activity over the trailing window.
    ///   - daysObserved: distinct days backing the profile (drives confidence).
    ///   - habitualWakeHour: typical wake clock hour, for the schedule-offset comparison.
    ///   - observedTempMinHour: optional measured nightly temp-minimum hour; overrides the activity-derived estimate.
    public static func estimatePhase(bins: [ActivityBin],
                                     daysObserved: Int,
                                     habitualWakeHour: Double,
                                     observedTempMinHour: Double? = nil) -> PhaseEstimate? {
        guard let fit = cosinor(bins) else { return nil }

        let relativeAmplitude = fit.mesor != 0 ? fit.amplitude / abs(fit.mesor) : 0
        // Rhythmic on either measure: a proportional swing or an absolute one (see `minAbsoluteAmplitudeBpm`).
        let rhythmic = relativeAmplitude >= minRelativeAmplitude || fit.amplitude >= minAbsoluteAmplitudeBpm
        if daysObserved < minDaysForFit || !rhythmic {
            // Returned but flagged unreadable so the surface says "hard to read right now."
            let tmin = observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tempMinHour: tmin, acrophaseHours: fit.acrophaseHours,
                                 offsetVsScheduleMinutes: 0, confidence: .unreadable,
                                 note: "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
        }

        // Activity-derived temp-minimum = acrophase - ~12 h.
        let derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        let tempMinHour = observedTempMinHour ?? derivedTempMin

        // A perfectly entrained clock has CBTmin ~cbtMinBeforeWakeHours before wake; the offset is the
        // signed distance (minutes, + = later than schedule) of the estimate from that ideal.
        let idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        let offsetHours = signedHourDelta(from: idealTempMin, to: tempMinHour)
        let offsetMinutes = offsetHours * 60.0

        // SOLID needs strength on both axes. A rhythm admitted only by `minAbsoluteAmplitudeBpm` pins its
        // acrophase less tightly, so it stays `.wide`, which withholds `chronotype`.
        let confidence: PhaseConfidence =
            (daysObserved >= goodDaysForFit && relativeAmplitude >= minRelativeAmplitude) ? .solid : .wide
        let lean: String
        if offsetMinutes > 20 { lean = "later (a night-owl lean)" }
        else if offsetMinutes < -20 { lean = "earlier (a morning-lark lean)" }
        else { lean = "well-aligned with your schedule" }
        let note = "Your body clock looks \(lean)."

        return PhaseEstimate(tempMinHour: tempMinHour, acrophaseHours: fit.acrophaseHours,
                             offsetVsScheduleMinutes: offsetMinutes, confidence: confidence, note: note)
    }

    // MARK: - Jet-lag / shift planner

    public enum ShiftDirection: String, Equatable, Sendable, Codable {
        case advance   // move the clock EARLIER (eastward travel / earlier shift)
        case delay     // move the clock LATER (westward travel / later shift)
        case none      // no meaningful shift required
    }

    /// One day of the re-entrainment plan: when to seek bright light, when to keep it dim, and the
    /// target sleep window. Light and timing only.
    public struct DayPlan: Equatable, Sendable {
        public let dayIndex: Int               // 1-based
        public let brightLightStartHour: Double
        public let brightLightEndHour: Double
        public let dimFromHour: Double
        public let targetSleepHour: Double
        public let targetWakeHour: Double
        public let guidance: String
        public init(dayIndex: Int, brightLightStartHour: Double, brightLightEndHour: Double,
                    dimFromHour: Double, targetSleepHour: Double, targetWakeHour: Double, guidance: String) {
            self.dayIndex = dayIndex
            self.brightLightStartHour = brightLightStartHour; self.brightLightEndHour = brightLightEndHour
            self.dimFromHour = dimFromHour
            self.targetSleepHour = targetSleepHour; self.targetWakeHour = targetWakeHour
            self.guidance = guidance
        }
    }

    public struct JetLagPlan: Equatable, Sendable {
        public let direction: ShiftDirection
        public let totalShiftHours: Double     // absolute size of the shift to absorb
        public let estimatedDays: Int          // days to close it at the stepped rate
        public let days: [DayPlan]
        public let note: String
        public init(direction: ShiftDirection, totalShiftHours: Double, estimatedDays: Int,
                    days: [DayPlan], note: String) {
            self.direction = direction; self.totalShiftHours = totalShiftHours
            self.estimatedDays = estimatedDays; self.days = days; self.note = note
        }
    }

    /// Builds a stepped light and sleep-timing plan to absorb a required clock shift.
    ///
    /// - Parameters:
    ///   - shiftHours: required shift in hours; positive = ADVANCE (eastward), negative = DELAY (westward).
    ///   - currentSleepHour / currentWakeHour: the current sleep window (clock hours).
    public static func planShift(shiftHours: Double,
                                 currentSleepHour: Double,
                                 currentWakeHour: Double) -> JetLagPlan {
        let magnitude = abs(shiftHours)
        guard magnitude >= 0.5 else {
            return JetLagPlan(direction: .none, totalShiftHours: 0, estimatedDays: 0, days: [],
                              note: "No meaningful body-clock shift needed - you're about aligned.")
        }

        let advancing = shiftHours > 0
        let direction: ShiftDirection = advancing ? .advance : .delay
        let days = Int(ceil(magnitude / maxShiftPerDayHours))

        var plan: [DayPlan] = []
        var cumulative = 0.0
        for i in 1...days {
            let stepRemaining = magnitude - cumulative
            let step = min(maxShiftPerDayHours, stepRemaining)
            cumulative += step
            // Advancing shifts the window earlier each day (subtract); delaying later (add).
            let signed = advancing ? -cumulative : cumulative
            let sleep = wrap24(currentSleepHour + signed)
            let wake = wrap24(currentWakeHour + signed)

            let brightStart: Double
            let brightEnd: Double
            let dimFrom: Double
            let guidance: String
            if advancing {
                // ADVANCE: bright light in the morning after the new wake; dim evenings.
                brightStart = wake
                brightEnd = wrap24(wake + 2.0)
                dimFrom = wrap24(sleep - 2.0)
                guidance = "Get bright light early after waking and keep the evening dim - this nudges your "
                    + "clock earlier. Aim for lights-out around \(clock(sleep))."
            } else {
                // DELAY: bright light in the evening; avoid bright morning light.
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light - this nudges "
                    + "your clock later. Aim for lights-out around \(clock(sleep))."
            }
            plan.append(DayPlan(dayIndex: i, brightLightStartHour: brightStart, brightLightEndHour: brightEnd,
                                dimFromHour: dimFrom, targetSleepHour: sleep, targetWakeHour: wake,
                                guidance: guidance))
        }

        let dirWord = advancing ? "earlier" : "later"
        let note = "Shifting your clock \(String(format: "%.1f", magnitude)) h \(dirWord), about "
            + "\(maxShiftPerDayHours == 1.0 ? "an hour" : "\(maxShiftPerDayHours) h") a day. Light and sleep "
            + "timing only."
        return JetLagPlan(direction: direction, totalShiftHours: magnitude, estimatedDays: days,
                          days: plan, note: note)
    }

    // MARK: - Helpers

    /// Wraps an hour value into [0, 24).
    static func wrap24(_ h: Double) -> Double {
        var x = h.truncatingRemainder(dividingBy: 24.0)
        if x < 0 { x += 24.0 }
        return x
    }

    /// A coarse, absolute body-clock category: where the temperature minimum sits on the clock.
    ///
    /// Distinct from the relative "lean" string built from `offsetVsScheduleMinutes` (relative to the
    /// wearer's own schedule); a consistent 03:00-11:00 sleeper is aligned by that read and `.evening`
    /// by this one, so keep the vocabularies disjoint in user-facing text (#1409). Three buckets only,
    /// since the underlying estimate is an activity fit.
    public enum Chronotype: String, Equatable, Sendable, Codable {
        case morning        // CBTmin earlier than the population reference
        case intermediate
        case evening        // CBTmin later than the population reference
    }

    /// The reference CBTmin clock hour a lean is measured against: population wake hour minus
    /// `cbtMinBeforeWakeHours`, so the anchor follows the engine's own model.
    public static var chronotypeAnchorHour: Double {
        wrap24(chronotypeReferenceWakeHour - cbtMinBeforeWakeHours)
    }

    /// The chronotype-ideal sleep window for a night of `durationHours`, as clock hours.
    ///
    /// Anchored on the temperature minimum: ideal wake = `tempMinHour + cbtMinBeforeWakeHours`, ideal
    /// bedtime = that minus the night's own length. Using the actual duration makes the comparison
    /// purely about phase, so a short night reads as aligned-but-short, not misaligned.
    /// Nil for a non-positive duration or one longer than a day (it cannot sit on a 24 h ring).
    public static func idealSleepWindow(tempMinHour: Double,
                                        durationHours: Double) -> (bedHour: Double, wakeHour: Double)? {
        guard durationHours > 0, durationHours < 24 else { return nil }
        let wake = wrap24(tempMinHour + cbtMinBeforeWakeHours)
        return (bedHour: wrap24(wake - durationHours), wakeHour: wake)
    }

    /// Signed hours the actual sleep window sits later (+) or earlier (-) than the chronotype-ideal one.
    ///
    /// Not `offsetVsScheduleMinutes`: a dial drawing actual against ideal arcs must be captioned with
    /// the distance between those arcs. Anchored on wake, because the ideal window is built from the
    /// wake end and comparing bedtimes would fold duration into a phase reading.
    public static func sleepWindowOffsetHours(tempMinHour: Double, actualWakeHour: Double) -> Double {
        signedHourDelta(from: wrap24(tempMinHour + cbtMinBeforeWakeHours), to: wrap24(actualWakeHour))
    }

    /// Buckets an absolute temperature-minimum clock hour into a lean, compared circularly
    /// (23:30 is five hours before the 04:30 anchor, a morning lean, not evening).
    public static func chronotype(tempMinHour: Double) -> Chronotype {
        let delta = signedHourDelta(from: chronotypeAnchorHour, to: wrap24(tempMinHour))
        if delta < -chronotypeBandHours { return .morning }
        if delta > chronotypeBandHours { return .evening }
        return .intermediate
    }

    /// The lean for a phase estimate, or nil when the fit is not `.solid`. A named category reads as a
    /// fact about the person, so `.wide` and `.unreadable` never name one.
    public static func chronotype(_ estimate: PhaseEstimate) -> Chronotype? {
        guard estimate.confidence == .solid else { return nil }
        return chronotype(tempMinHour: estimate.tempMinHour)
    }

    /// Signed shortest delta in hours from `a` to `b` on the 24 h clock, in (-12, 12].
    static func signedHourDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 24.0)
        if d > 12.0 { d -= 24.0 }
        if d <= -12.0 { d += 24.0 }
        return d
    }

    /// Formats a clock hour as "HH:MM" (24 h), locale-free.
    static func clock(_ hour: Double) -> String {
        let h = wrap24(hour)
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60.0).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}
