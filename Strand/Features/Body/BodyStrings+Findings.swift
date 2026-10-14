#if os(iOS)
import Foundation

// MARK: - Insights copy (zoop.body.* catalogue entries), findings and patterns
//
// Generated alongside the German and English catalogue entries; edit both together.

extension BodyStrings {
    static let hrvTrendTitle = LocalizedStringResource("zoop.body.hrv.title", defaultValue: "HRV trend")
    static let rhrTrendTitle = LocalizedStringResource("zoop.body.rhr.title", defaultValue: "Resting heart rate trend")
    static func hrvBelowStreak(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.hrv.belowStreak", defaultValue: "Your HRV has been below your normal for \(days) days.")
    }
    static func hrvAboveStreak(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.hrv.aboveStreak", defaultValue: "Your HRV has been above your normal for \(days) days.")
    }
    static let hrvLowerWeek = LocalizedStringResource("zoop.body.hrv.lowerWeek", defaultValue: "Your HRV has run lower than usual this week.")
    static let hrvHigherWeek = LocalizedStringResource("zoop.body.hrv.higherWeek", defaultValue: "Your HRV has run higher than usual this week.")
    static func rhrBelowStreak(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.rhr.belowStreak", defaultValue: "Your resting heart rate has been below your normal for \(days) days.")
    }
    static func rhrAboveStreak(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.rhr.aboveStreak", defaultValue: "Your resting heart rate has been above your normal for \(days) days.")
    }
    static let rhrLowerWeek = LocalizedStringResource("zoop.body.rhr.lowerWeek", defaultValue: "Your resting heart rate has run lower than usual this week.")
    static let rhrHigherWeek = LocalizedStringResource("zoop.body.rhr.higherWeek", defaultValue: "Your resting heart rate has run higher than usual this week.")
    static let weekVsNormal = LocalizedStringResource("zoop.body.direction.comparison", defaultValue: "last 7 days vs. the 30 days before")
    static let hrvTrendWhat = LocalizedStringResource("zoop.body.hrv.what", defaultValue: "Whether your nightly HRV has drifted away from your own normal over the last days.")
    static let rhrTrendWhat = LocalizedStringResource("zoop.body.rhr.what", defaultValue: "Whether your sleeping heart rate has drifted away from your own normal over the last days.")
    static let directionMethod = LocalizedStringResource("zoop.body.direction.method", defaultValue: "Rolling comparison")
    static let directionMethodSummary = LocalizedStringResource("zoop.body.direction.method.summary", defaultValue: "Each night is compared with the 30 days before it; a run counts nights at least half a standard deviation away.")
    static func recentVsNormal(_ recent: String, _ normal: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.direction.data", defaultValue: "Last 7 days: \(recent). Your normal: \(normal).")
    }
    static let sensitivityTitle = LocalizedStringResource("zoop.body.sensitivity.title", defaultValue: "Effort and recovery")
    static let sensitivityStrong = LocalizedStringResource("zoop.body.sensitivity.strong", defaultValue: "Hard days hit your next-morning recovery hard.")
    static let sensitivityNoticeable = LocalizedStringResource("zoop.body.sensitivity.noticeable", defaultValue: "Hard days lower your next-morning recovery noticeably.")
    static let sensitivityLittle = LocalizedStringResource("zoop.body.sensitivity.little", defaultValue: "Hard days barely move your next-morning recovery.")
    static let per10Effort = LocalizedStringResource("zoop.body.sensitivity.per10", defaultValue: "recovery points per 10 strain")
    static let perEffortPoint = LocalizedStringResource("zoop.body.sensitivity.perPoint", defaultValue: "recovery points per strain point")
    static let sensitivityWhat = LocalizedStringResource("zoop.body.sensitivity.what", defaultValue: "How much a harder day tends to lower your recovery the next morning.")
    static let sensitivityMethod = LocalizedStringResource("zoop.body.sensitivity.method", defaultValue: "Straight-line fit")
    static let sensitivityMethodSummary = LocalizedStringResource("zoop.body.sensitivity.method.summary", defaultValue: "Each day's strain against the next morning's recovery over the last 180 days.")
    static func daysWithEffortAndRecovery(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.sensitivity.data", defaultValue: "\(count) days with both strain and next-morning recovery.")
    }
    static let bounceTitle = LocalizedStringResource("zoop.body.bounce.title", defaultValue: "Bounce-back")
    static let bounceNextMorning = LocalizedStringResource("zoop.body.bounce.nextMorning", defaultValue: "After your hardest days, your recovery is back to normal by the next morning.")
    static func bounceDays(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.bounce.days", defaultValue: "After your hardest days, your recovery takes about \(days) days to get back to normal.")
    }
    static let bounceOverWeek = LocalizedStringResource("zoop.body.bounce.overWeek", defaultValue: "After your hardest days, your recovery often takes over a week to get back to normal.")
    static let overSevenDays = LocalizedStringResource("zoop.body.bounce.overSeven", defaultValue: "> 7 days")
    static let bounceComparison = LocalizedStringResource("zoop.body.bounce.comparison", defaultValue: "until recovery is back at your normal")
    static let hardDay = LocalizedStringResource("zoop.body.bounce.hardDay", defaultValue: "Day 0")
    static let bounceWhat = LocalizedStringResource("zoop.body.bounce.what", defaultValue: "How long your recovery needs to get back to normal after a hard day.")
    static let bounceMethod = LocalizedStringResource("zoop.body.bounce.method", defaultValue: "Median return time")
    static let bounceMethodSummary = LocalizedStringResource("zoop.body.bounce.method.summary", defaultValue: "Your hardest fifth of days, each compared with the median recovery of the 30 days before it.")
    static func bounceDataDip(_ events: Int, _ dip: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.bounce.data", defaultValue: "\(events) hard days; the next morning sits \(dip) points below normal on average.")
    }
    static let zonesTitle = LocalizedStringResource("zoop.body.zones.title", defaultValue: "Training intensity")
    static let zonesMostlyEasy = LocalizedStringResource("zoop.body.zones.mostlyEasy", defaultValue: "Most of your training is easy, close to an 80/20 split.")
    static let zonesMixed = LocalizedStringResource("zoop.body.zones.mixed", defaultValue: "Your training leans easy but carries a lot of hard time.")
    static let zonesMostlyHard = LocalizedStringResource("zoop.body.zones.mostlyHard", defaultValue: "Most of your training time is hard, in zones 3 to 5.")
    static let zonesEasyShare = LocalizedStringResource("zoop.body.zones.easyShare", defaultValue: "of zone time easy (zones 1–2)")
    static let zonesHardShare = LocalizedStringResource("zoop.body.zones.hardShare", defaultValue: "of zone time hard (zones 3–5)")
    static let zonesWhat = LocalizedStringResource("zoop.body.zones.what", defaultValue: "How your workout time splits between easy and hard heart-rate zones.")
    static let zonesMethod = LocalizedStringResource("zoop.body.zones.method", defaultValue: "Zone time share")
    static let zonesMethodSummary = LocalizedStringResource("zoop.body.zones.method.summary", defaultValue: "Heart-rate zone time of your workouts in the last four weeks; zones 1–2 count as easy, 3–5 as hard.")
    static func zonesData(_ workouts: Int, _ minutes: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.zones.data", defaultValue: "\(workouts) workouts with \(minutes) minutes of zone time.")
    }
    static let stressTimingTitle = LocalizedStringResource("zoop.body.stressTiming.title", defaultValue: "Stress timing")
    static func stressTimingMeaning(_ peak: String, _ calm: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.stressTiming.meaning", defaultValue: "Your stress usually peaks around \(peak) and is lowest around \(calm).")
    }
    static func calmestAt(_ calm: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.stressTiming.comparison", defaultValue: "peak hour; calmest around \(calm)")
    }
    static let stressTimingWhat = LocalizedStringResource("zoop.body.stressTiming.what", defaultValue: "When in the day your stress level tends to rise and settle.")
    static let stressTimingMethod = LocalizedStringResource("zoop.body.stressTiming.method", defaultValue: "Hourly average")
    static let stressTimingMethodSummary = LocalizedStringResource("zoop.body.stressTiming.method.summary", defaultValue: "Hourly stress of your last 14 days between 07:00 and 23:00, averaged for each hour.")
    static func stressTimingData(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.stressTiming.data", defaultValue: "\(days) days with enough heart-rate data.")
    }
    static let hrrTitle = LocalizedStringResource("zoop.body.hrr.title", defaultValue: "Heart-rate recovery")
    static let hrrTypical = LocalizedStringResource("zoop.body.hrr.typical", defaultValue: "Your heart rate drops quickly after training, a sign of good fitness.")
    static let hrrLow = LocalizedStringResource("zoop.body.hrr.low", defaultValue: "Your heart rate drops slowly after training; heat or fatigue can do this.")
    static func hrrComparison(_ average: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.hrr.comparison", defaultValue: "drop after one minute, last workout; average \(average)")
    }
    static let hrrWhat = LocalizedStringResource("zoop.body.hrr.what", defaultValue: "How far your heart rate falls in the first minute after a hard workout.")
    static let hrrMethod = LocalizedStringResource("zoop.body.hrr.method", defaultValue: "One-minute heart-rate recovery")
    static let hrrMethodSummary = LocalizedStringResource("zoop.body.hrr.method.summary", defaultValue: "Peak heart rate at the end of the workout minus the median one minute later; 12 bpm or less counts as low.")
    static func habitHigher(_ habit: String, _ metric: String, _ amount: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.habit.higher", defaultValue: "On days with “\(habit)”, \(metric) was \(amount) higher.")
    }
    static func habitLower(_ habit: String, _ metric: String, _ amount: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.habit.lower", defaultValue: "On days with “\(habit)”, \(metric) was \(amount) lower.")
    }
    static func habitNoClear(_ habit: String, _ metric: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.habit.noClear", defaultValue: "On days with “\(habit)”, \(metric) showed no clear difference.")
    }
    static let habitWhat = LocalizedStringResource("zoop.body.habit.what", defaultValue: "How a metric differs between days you answered yes and days you answered no in the logbook.")
    static let habitMethod = LocalizedStringResource("zoop.body.habit.method", defaultValue: "Welch's t-test and Cohen's d")
    static let habitMethodSummary = LocalizedStringResource("zoop.body.habit.method.summary", defaultValue: "Yes days against no days at the strongest of three lags; clear means p < 0.05 with at least 5 days each.")
    static func habitData(_ with: String, _ nWith: Int, _ without: String, _ nWithout: Int, _ d: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.habit.data", defaultValue: "With: \(with) (\(nWith) days). Without: \(without) (\(nWithout) days). Effect size d = \(d).")
    }
    static let habitConfidence = LocalizedStringResource("zoop.body.habit.confidence", defaultValue: "Many habits are tested at once and not yet corrected for that, so a single clear result can still be chance.")
    static let habitAlcohol = LocalizedStringResource("zoop.body.habit.name.alcohol", defaultValue: "Alcohol")
    static let habitLateCaffeine = LocalizedStringResource("zoop.body.habit.name.lateCaffeine", defaultValue: "Late caffeine")
    static let habitScreen = LocalizedStringResource("zoop.body.habit.name.screen", defaultValue: "Screen in bed")
    static let habitLateMeal = LocalizedStringResource("zoop.body.habit.name.lateMeal", defaultValue: "Late meal")
    static let habitStress = LocalizedStringResource("zoop.body.habit.name.stress", defaultValue: "Stress")
    static let habitSauna = LocalizedStringResource("zoop.body.habit.name.sauna", defaultValue: "Sauna")
    static let habitSharedBed = LocalizedStringResource("zoop.body.habit.name.sharedBed", defaultValue: "Shared bed")
    static let habitIll = LocalizedStringResource("zoop.body.habit.name.ill", defaultValue: "Feeling ill")
    static let habitMagnesium = LocalizedStringResource("zoop.body.habit.name.magnesium", defaultValue: "Magnesium")
    static let habitReading = LocalizedStringResource("zoop.body.habit.name.reading", defaultValue: "Reading before bed")
    static let weekdayTitle = LocalizedStringResource("zoop.body.weekday.title", defaultValue: "Weekdays")
    static func weekdayWeakest(_ day: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.weekday.weakest", defaultValue: "\(day) is usually your weakest recovery day.")
    }
    static func weekdayStrongest(_ day: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.weekday.strongest", defaultValue: "\(day) is usually your strongest recovery day.")
    }
    static let weekdayNone = LocalizedStringResource("zoop.body.weekday.none", defaultValue: "No weekday stands out in your recovery.")
    static func weekdayVsOthers(_ mean: String, _ others: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.weekday.comparison", defaultValue: "average \(mean) vs. \(others) on other days")
    }
    static let weekdaySpread = LocalizedStringResource("zoop.body.weekday.spread", defaultValue: "points between best and weakest weekday")
    static let weekdayWhat = LocalizedStringResource("zoop.body.weekday.what", defaultValue: "Whether one day of the week regularly brings higher or lower recovery.")
    static let weekdayMethod = LocalizedStringResource("zoop.body.weekday.method", defaultValue: "Weekday average and consistency")
    static let weekdayMethodSummary = LocalizedStringResource("zoop.body.weekday.method.summary", defaultValue: "Average recovery per weekday over 26 weeks; a day is named only when it is 8 points off and stood out in most weeks.")
    static let eveningTitle = LocalizedStringResource("zoop.body.evening.title", defaultValue: "Evening stress and deep sleep")
    static let eveningLess = LocalizedStringResource("zoop.body.evening.less", defaultValue: "After stressful evenings you get less deep sleep.")
    static let eveningMore = LocalizedStringResource("zoop.body.evening.more", defaultValue: "After stressful evenings you get more deep sleep, not less.")
    static let eveningNoClear = LocalizedStringResource("zoop.body.evening.noClear", defaultValue: "Evening stress barely changes your deep sleep.")
    static let eveningComparison = LocalizedStringResource("zoop.body.evening.comparison", defaultValue: "deep sleep, stressful vs. calm evenings")
    static let stressfulEvenings = LocalizedStringResource("zoop.body.evening.stressful", defaultValue: "Stressful")
    static let calmEvenings = LocalizedStringResource("zoop.body.evening.calm", defaultValue: "Calm")
    static let eveningWhat = LocalizedStringResource("zoop.body.evening.what", defaultValue: "Whether a stressful evening is followed by less deep sleep.")
    static let eveningMethod = LocalizedStringResource("zoop.body.evening.method", defaultValue: "Top third vs. bottom third")
    static let eveningMethodSummary = LocalizedStringResource("zoop.body.evening.method.summary", defaultValue: "Evenings from 17:00 to 23:00 over four weeks, most against least stressful third; under 10 minutes counts as no clear difference.")
    static func eveningData(_ stressful: String, _ calm: String, _ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.body.evening.data", defaultValue: "Deep sleep after stressful evenings: \(stressful); after calm ones: \(calm); \(count) evenings.")
    }
}
#endif
