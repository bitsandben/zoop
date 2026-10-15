#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Interpretations ("What your body shows")
//
// Turns the engine readings into findings. A reading the engine could not make is simply absent; a
// steady HRV or resting heart rate is left to the vitals tiles, which already say "Typical".

enum BodyFindings {

    static func build(_ s: BodySnapshot, effortScale: EffortScale) -> [BodyFinding] {
        var out: [BodyFinding] = []
        if let d = s.hrv, d.trend != .steady { out.append(direction(d, hrv: true)) }
        if let d = s.restingHR, d.trend != .steady { out.append(direction(d, hrv: false)) }
        if let x = s.sensitivity { out.append(sensitivity(x, effortScale: effortScale)) }
        if let b = s.bounceBack { out.append(bounceBack(b)) }
        if let z = s.zoneMix { out.append(zoneMix(z)) }
        if let t = s.stressTiming { out.append(stressTiming(t)) }
        if let h = s.hrr { out.append(heartRateRecovery(h)) }
        return out
    }

    // MARK: HRV / resting HR direction

    private static func direction(_ d: BodyInsights.Direction, hrv: Bool) -> BodyFinding {
        let unit: MetricUnit = hrv ? .milliseconds : .beatsPerMinute
        let below = d.trend == .belowStreak || d.trend == .lowerThisWeek
        let meaning: LocalizedStringResource
        switch (d.trend, hrv) {
        case (.belowStreak, true): meaning = BodyStrings.hrvBelowStreak(d.streakDays)
        case (.aboveStreak, true): meaning = BodyStrings.hrvAboveStreak(d.streakDays)
        case (.lowerThisWeek, true): meaning = BodyStrings.hrvLowerWeek
        case (.belowStreak, false): meaning = BodyStrings.rhrBelowStreak(d.streakDays)
        case (.aboveStreak, false): meaning = BodyStrings.rhrAboveStreak(d.streakDays)
        case (.lowerThisWeek, false): meaning = BodyStrings.rhrLowerWeek
        case (_, true): meaning = BodyStrings.hrvHigherWeek
        case (_, false): meaning = BodyStrings.rhrHigherWeek
        }
        let points = d.series.map { MetricExplanation.TrendPoint(date: BodyFormat.date($0.day), value: $0.value) }
        let recent = unit.format(d.recentMean, locale: BodyFormat.locale)
        let normal = unit.format(d.baselineMean, locale: BodyFormat.locale)
        // The number and its comparison describe the same reading as the verdict: a run is told as its
        // length in nights (each against its own trailing month), a weekly drift as the 7-day change.
        // Mixing them showed "above your normal" beside a negative weekly percentage.
        let streak = d.trend == .belowStreak || d.trend == .aboveStreak
        let value = streak ? String(localized: BodyStrings.days(d.streakDays))
            : MetricUnit.percent.formatDelta(d.deltaPercent, locale: BodyFormat.locale)
        let comparison = !streak ? BodyStrings.weekVsNormal : below ? BodyStrings.streakBelow : BodyStrings.streakAbove
        return BodyFinding(
            id: hrv ? "hrv" : "rhr",
            title: hrv ? BodyStrings.hrvTrendTitle : BodyStrings.rhrTrendTitle,
            meaning: meaning,
            value: value,
            comparison: comparison,
            // Lower HRV is worse, lower resting heart rate is better.
            verdict: below == hrv ? .worse : .better,
            sample: BodyStrings.readingsIn30Days(d.series.count),
            explanation: BodyFindingExplanation(
                whatItIs: hrv ? BodyStrings.hrvTrendWhat : BodyStrings.rhrTrendWhat,
                methodName: BodyStrings.directionMethod,
                methodSummary: BodyStrings.directionMethodSummary,
                citation: hrv ? "Plews et al., 2012" : nil,
                dataUsed: streak ? BodyStrings.streakData(d.streakDays) : BodyStrings.recentVsNormal(recent, normal),
                confidence: .confidence(samples: d.series.count, solidAt: 21),
                confidenceReason: BodyStrings.readingsIn30Days(d.series.count)),
            visual: .line(points: points, normal: d.baselineMean, spread: d.baselineSD, unit: unit))
    }

    // MARK: Effort sensitivity

    private static func sensitivity(_ s: BodyInsights.StrainSensitivity, effortScale: EffortScale) -> BodyFinding {
        // Stored effort is 0–100; WHOOP-scale users read it on 0–21, so the slope is per one of their points.
        let whoop = effortScale == .whoop
        let factor = whoop ? 0.21 : 1.0
        let perUnit = s.pointsPer10 / 10 / factor
        let shown = whoop ? perUnit : s.pointsPer10
        let verdict: BodyVerdict
        let meaning: LocalizedStringResource
        switch s.level {
        case .strong: verdict = .strong; meaning = BodyStrings.sensitivityStrong
        case .noticeable: verdict = .noticeable; meaning = BodyStrings.sensitivityNoticeable
        case .little: verdict = .little; meaning = BodyStrings.sensitivityLittle
        }
        let points = s.points.map { BodyInsights.StrainSensitivity.Pair(strain: $0.strain * factor, recovery: $0.recovery) }
        return BodyFinding(
            id: "sensitivity",
            title: BodyStrings.sensitivityTitle,
            meaning: meaning,
            value: MetricUnit.score(fractionDigits: 1).formatDelta(shown, locale: BodyFormat.locale),
            comparison: whoop ? BodyStrings.perEffortPoint : BodyStrings.per10Effort,
            verdict: verdict,
            sample: BodyStrings.days(s.pairs),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.sensitivityWhat,
                methodName: BodyStrings.sensitivityMethod,
                methodSummary: BodyStrings.sensitivityMethodSummary,
                citation: nil,
                dataUsed: BodyStrings.daysWithEffortAndRecovery(s.pairs),
                confidence: .confidence(samples: s.pairs, solidAt: 60),
                confidenceReason: BodyStrings.sampleReason(s.pairs, 60)),
            visual: .scatter(points: points, slope: perUnit))
    }

    // MARK: Bounce-back

    private static func bounceBack(_ b: BodyInsights.BounceBack) -> BodyFinding {
        let days = max(1, Int(b.medianDays.rounded(.up)))
        let verdict: BodyVerdict = days <= 1 ? .quick : days <= 3 ? .typical : .slow
        let meaning: LocalizedStringResource = days <= 1 ? BodyStrings.bounceNextMorning
            : days <= 7 ? BodyStrings.bounceDays(days) : BodyStrings.bounceOverWeek
        let dip = Int((-b.nextMorningDip).rounded())
        return BodyFinding(
            id: "bounce",
            title: BodyStrings.bounceTitle,
            meaning: meaning,
            value: days > 7 ? String(localized: BodyStrings.overSevenDays) : String(localized: BodyStrings.days(days)),
            comparison: BodyStrings.bounceComparison,
            verdict: verdict,
            sample: BodyStrings.hardDays(b.events),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.bounceWhat,
                methodName: BodyStrings.bounceMethod,
                methodSummary: BodyStrings.bounceMethodSummary,
                citation: nil,
                dataUsed: dip >= 1 ? BodyStrings.bounceDataDip(b.events, dip) : BodyStrings.hardDays(b.events),
                confidence: .confidence(samples: b.events, solidAt: 10),
                confidenceReason: BodyStrings.sampleReason(b.events, 10)),
            visual: .trajectory(b.trajectory))
    }

    // MARK: Training intensity

    private static func zoneMix(_ z: BodyInsights.ZoneMix) -> BodyFinding {
        let hard = z.style == .mostlyHard
        let verdict: BodyVerdict
        let meaning: LocalizedStringResource
        switch z.style {
        case .mostlyEasy: verdict = .mostlyEasy; meaning = BodyStrings.zonesMostlyEasy
        case .mixed: verdict = .mixed; meaning = BodyStrings.zonesMixed
        case .mostlyHard: verdict = .mostlyHard; meaning = BodyStrings.zonesMostlyHard
        }
        let share = (hard ? z.hardShare : z.easyShare) * 100
        return BodyFinding(
            id: "zones",
            title: BodyStrings.zonesTitle,
            meaning: meaning,
            value: MetricUnit.percent.format(share, locale: BodyFormat.locale),
            comparison: hard ? BodyStrings.zonesHardShare : BodyStrings.zonesEasyShare,
            verdict: verdict,
            sample: BodyStrings.workouts(z.sessions),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.zonesWhat,
                methodName: BodyStrings.zonesMethod,
                methodSummary: BodyStrings.zonesMethodSummary,
                citation: "Seiler, 2010",
                dataUsed: BodyStrings.zonesData(z.sessions, Int(z.totalMinutes.rounded())),
                confidence: .confidence(samples: z.sessions, solidAt: 8),
                confidenceReason: BodyStrings.sampleReason(z.sessions, 8)),
            visual: .zones(z.minutes))
    }

    // MARK: Stress timing

    private static func stressTiming(_ s: BodyInsights.StressTiming) -> BodyFinding {
        let peak = BodyFormat.clock(hour: s.peakHour)
        let calm = BodyFormat.clock(hour: s.calmHour)
        return BodyFinding(
            id: "stressTiming",
            title: BodyStrings.stressTimingTitle,
            meaning: BodyStrings.stressTimingMeaning(peak, calm),
            value: peak,
            comparison: BodyStrings.calmestAt(calm),
            verdict: s.consistency >= 0.6 ? .clearPattern : .weakPattern,
            sample: BodyStrings.days(s.days),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.stressTimingWhat,
                methodName: BodyStrings.stressTimingMethod,
                methodSummary: BodyStrings.stressTimingMethodSummary,
                citation: nil,
                dataUsed: BodyStrings.stressTimingData(s.days),
                confidence: .confidence(samples: s.days, solidAt: 10),
                confidenceReason: BodyStrings.sampleReason(s.days, 10)),
            visual: .hours(s.hourMeans, peak: s.peakHour, calm: s.calmHour))
    }

    // MARK: Heart-rate recovery

    /// A one-minute drop of 12 bpm or less is the classic abnormal cut-off (Cole et al., 1999).
    static let hrrCutoff = 12.0

    private static func heartRateRecovery(_ h: BodyHRR) -> BodyFinding {
        let typical = h.averageDrop > hrrCutoff
        let bpm = MetricUnit.beatsPerMinute
        return BodyFinding(
            id: "hrr",
            title: BodyStrings.hrrTitle,
            meaning: typical ? BodyStrings.hrrTypical : BodyStrings.hrrLow,
            value: bpm.format(Double(h.latestDrop), locale: BodyFormat.locale),
            comparison: BodyStrings.hrrComparison(bpm.format(h.averageDrop, locale: BodyFormat.locale)),
            verdict: typical ? .typical : .below,
            sample: BodyStrings.workouts(h.workouts),
            explanation: BodyFindingExplanation(
                whatItIs: BodyStrings.hrrWhat,
                methodName: BodyStrings.hrrMethod,
                methodSummary: BodyStrings.hrrMethodSummary,
                citation: "Cole et al., 1999",
                dataUsed: BodyStrings.workouts(h.workouts),
                confidence: .confidence(samples: h.workouts, solidAt: 6),
                confidenceReason: BodyStrings.sampleReason(h.workouts, 6)),
            visual: .groups(first: Double(h.latestDrop), second: h.averageDrop,
                            firstLabel: BodyStrings.hrrLatest, secondLabel: BodyStrings.hrrAverage, unit: bpm))
    }
}

// MARK: - Formatting (app locale, never `String(format:)`)

enum BodyFormat {
    static var locale: Locale { AppLanguage.activeLocale }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date { dayParser.date(from: day) ?? Date() }

    static func clock(hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }

    /// Full weekday name for an ISO weekday (1 = Monday).
    static func weekday(_ iso: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.standaloneWeekdaySymbols[iso % 7]
    }

    static func shortWeekday(_ iso: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.shortStandaloneWeekdaySymbols[iso % 7]
    }
}
#endif
