#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Sleep type (chronotype)
//
// One resolver for the sleep type: the Sleep screen's card and the Insights summary row both render
// this content, so the type, the mid-sleep and the social jetlag can never disagree between them.
// The math lives in `Chronotype` (StrandAnalytics); this only words and formats it.

struct SleepChronotypeContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: LocalizedStringResource
        let value: String
        /// Closed vocabulary (Low / Medium / High), nil where a band would mean nothing.
        let verdict: LocalizedStringResource?
        let note: LocalizedStringResource
    }

    let profile: Chronotype.Profile
    let typeName: LocalizedStringResource
    let meaning: LocalizedStringResource
    let advice: LocalizedStringResource
    /// The mid-sleep the type is read from, as a clock time.
    let typeMidSleep: String
    let rows: [Row]
    /// The one sentence about workdays vs free days, or what it waits for.
    let shiftSentence: LocalizedStringResource
    let sample: LocalizedStringResource
    /// Set while the profile is still building; says what makes it solid.
    let building: LocalizedStringResource?

    /// Timing variation bands (SD of mid-sleep, minutes): ≤ 30 low, ≤ 60 medium, above high.
    static let steadySpreadMin = 30.0
    static let wobblySpreadMin = 60.0
    /// A free-day shift smaller than this reads as no shift.
    static let noShiftMin = 15.0

    static func build(_ p: Chronotype.Profile) -> SleepChronotypeContent {
        let midSleep = SleepInsightFormat.clock(p.habitualMidSleepSignedMin)
        var rows = [Row(id: "mid", label: SleepChronotypeStrings.midSleep, value: midSleep, verdict: nil,
                        note: SleepChronotypeStrings.midSleepNote)]
        rows.append(Row(id: "spread", label: SleepChronotypeStrings.spread,
                        value: "± " + SleepReadouts.durationText(seconds: p.spreadMin * 60),
                        verdict: spreadBand(p.spreadMin).text, note: SleepChronotypeStrings.spreadNote))
        if let jetlag = p.socialJetlagMin {
            rows.append(Row(id: "jetlag", label: SleepChronotypeStrings.jetlag,
                            value: SleepReadouts.durationText(seconds: jetlag * 60),
                            verdict: jetlagBand(p.jetlagBand ?? .low).text, note: SleepChronotypeStrings.jetlagNote))
        }
        return SleepChronotypeContent(
            profile: p, typeName: SleepChronotypeStrings.name(p.kind), meaning: SleepChronotypeStrings.meaning(p.kind),
            advice: SleepChronotypeStrings.advice(p.kind),
            typeMidSleep: SleepInsightFormat.clock(p.chronotypeMidSleepSignedMin), rows: rows,
            shiftSentence: shift(p), sample: SleepChronotypeStrings.sample(p.nightCount, p.freeNightCount),
            building: p.isSolid ? nil : SleepChronotypeStrings.building)
    }

    private static func shift(_ p: Chronotype.Profile) -> LocalizedStringResource {
        guard let free = p.freeDayMidSleepSignedMin, let work = p.workdayMidSleepSignedMin else {
            return SleepChronotypeStrings.jetlagPending
        }
        let delta = free - work
        guard abs(delta) >= noShiftMin else { return SleepChronotypeStrings.shiftSteady }
        let text = SleepReadouts.durationText(seconds: abs(delta) * 60)
        return delta > 0 ? SleepChronotypeStrings.shiftLater(text) : SleepChronotypeStrings.shiftEarlier(text)
    }

    static func spreadBand(_ minutes: Double) -> ScoreBand {
        if minutes <= steadySpreadMin { return .low }
        return minutes <= wobblySpreadMin ? .medium : .high
    }

    static func jetlagBand(_ band: Chronotype.JetlagBand) -> ScoreBand {
        switch band {
        case .low: return .low
        case .moderate: return .medium
        case .high: return .high
        }
    }

    /// The content from the stored nights, or nil under `Chronotype.minNights`.
    static func load(sleeps: [CachedSleepSession], days: [DailyMetric]) -> SleepChronotypeContent? {
        let nights = SleepInsightsSection.nights(sleeps: sleeps, days: days, withLatency: false)
        return Chronotype.profile(nights).map(build)
    }
}

// MARK: - Copy

enum SleepChronotypeStrings {
    static let title = LocalizedStringResource("zoop.sleep.chronotype.title", defaultValue: "Sleep type")
    static let midSleep = LocalizedStringResource("zoop.sleep.chronotype.midSleep", defaultValue: "Mid-sleep")
    static let midSleepNote = LocalizedStringResource("zoop.sleep.chronotype.midSleep.note",
                                                      defaultValue: "Halfway through your usual night")
    static let spread = LocalizedStringResource("zoop.sleep.chronotype.spread", defaultValue: "Timing variation")
    static let spreadNote = LocalizedStringResource("zoop.sleep.chronotype.spread.note",
                                                    defaultValue: "How much your mid-sleep moves night to night")
    static let jetlag = LocalizedStringResource("zoop.sleep.chronotype.jetlag", defaultValue: "Social jetlag")
    static let jetlagNote = LocalizedStringResource("zoop.sleep.chronotype.jetlag.note",
                                                    defaultValue: "Gap between free days and workdays")
    static let jetlagPending = LocalizedStringResource("zoop.sleep.chronotype.jetlag.pending",
                                                       defaultValue: "Social jetlag appears after two weekends with the strap.")
    static let shiftSteady = LocalizedStringResource("zoop.sleep.chronotype.shift.steady",
                                                     defaultValue: "Your timing barely shifts between workdays and free days.")
    static func shiftLater(_ d: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.chronotype.shift.later", defaultValue: "On free days you sleep \(d) later than on workdays.")
    }
    static func shiftEarlier(_ d: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.chronotype.shift.earlier", defaultValue: "On free days you sleep \(d) earlier than on workdays.")
    }
    static func sample(_ nights: Int, _ free: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.chronotype.sample", defaultValue: "\(nights) nights · \(free) before free days")
    }
    static let building = LocalizedStringResource("zoop.sleep.chronotype.building",
                                                  defaultValue: "Still building: solid from 14 nights including two weekends.")
    static func typeMidSleep(_ clock: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.sleep.chronotype.typeMidSleep", defaultValue: "Free-day mid-sleep \(clock)")
    }
    static let chart = LocalizedStringResource("zoop.sleep.chronotype.chart", defaultValue: "Mid-sleep per night")
    static let freeDay = LocalizedStringResource("zoop.sleep.chronotype.freeDay", defaultValue: "Free day")
    static let workday = LocalizedStringResource("zoop.sleep.chronotype.workday", defaultValue: "Workday")
    static let whatTitle = LocalizedStringResource("zoop.sleep.chronotype.what.title", defaultValue: "What it is")
    static let what = LocalizedStringResource("zoop.sleep.chronotype.what",
                                              defaultValue: "Your chronotype is when your inner clock prefers to sleep; it is largely innate and shifts with age.")
    static let methodTitle = LocalizedStringResource("zoop.sleep.chronotype.method.title", defaultValue: "How it's computed")
    static let method = LocalizedStringResource("zoop.sleep.chronotype.method",
                                                defaultValue: "Mid-sleep on free days, corrected for catch-up sleep, over your last 42 nights. Before 3:30 reads as early, from 5:00 as late.")
    static let adviceTitle = LocalizedStringResource("zoop.sleep.chronotype.advice.title", defaultValue: "What helps")
    static let scaleEarly = LocalizedStringResource("zoop.sleep.chronotype.scale.early", defaultValue: "Early")
    static let scaleLate = LocalizedStringResource("zoop.sleep.chronotype.scale.late", defaultValue: "Late")

    static func name(_ k: Chronotype.Kind) -> LocalizedStringResource {
        switch k {
        case .early: return LocalizedStringResource("zoop.sleep.chronotype.early", defaultValue: "Early type")
        case .intermediate: return LocalizedStringResource("zoop.sleep.chronotype.intermediate", defaultValue: "Intermediate type")
        case .late: return LocalizedStringResource("zoop.sleep.chronotype.late", defaultValue: "Late type")
        }
    }

    static func meaning(_ k: Chronotype.Kind) -> LocalizedStringResource {
        switch k {
        case .early: return LocalizedStringResource("zoop.sleep.chronotype.meaning.early",
                                                    defaultValue: "You naturally sleep and wake early; mornings are your strong time.")
        case .intermediate: return LocalizedStringResource("zoop.sleep.chronotype.meaning.intermediate",
                                                           defaultValue: "Your rhythm sits in the middle; most schedules suit you.")
        case .late: return LocalizedStringResource("zoop.sleep.chronotype.meaning.late",
                                                   defaultValue: "You naturally sleep and wake late; early alarms cost you more.")
        }
    }

    static func advice(_ k: Chronotype.Kind) -> LocalizedStringResource {
        switch k {
        case .early: return LocalizedStringResource("zoop.sleep.chronotype.advice.early",
                                                    defaultValue: "Protect your early bedtime; late evenings cost you the most.")
        case .intermediate: return LocalizedStringResource("zoop.sleep.chronotype.advice.intermediate",
                                                           defaultValue: "Keep workday and free-day timing within an hour of each other.")
        case .late: return LocalizedStringResource("zoop.sleep.chronotype.advice.late",
                                                   defaultValue: "Morning light and a steady wake time pull your clock earlier.")
        }
    }
}
#endif
