import Foundation

// MARK: - Fitness Age copy (zoop.fitnessage.* catalogue entries)
//
// Every string of the Fitness Age feature, keyed so the German and English entries sit together.
// Interpolated values arrive already formatted in the user's locale; the catalogue only orders them.

enum FitnessAgeStrings {

    // Screen and card
    static let title = LocalizedStringResource("zoop.fitnessage.title", defaultValue: "Fitness Age")
    static let openSettings = LocalizedStringResource("zoop.fitnessage.openSettings", defaultValue: "Open Settings")
    static let refresh = LocalizedStringResource("zoop.fitnessage.refresh", defaultValue: "Refresh")
    static func week(_ date: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.week", defaultValue: "Week of \(date)")
    }
    static func band(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.band", defaultValue: "Estimate, ± \(years) years")
    }
    static func hero(_ age: String, _ delta: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.hero.a11y", defaultValue: "Fitness Age \(age), \(delta)")
    }

    // Delta against the real age
    static let sameAge = LocalizedStringResource("zoop.fitnessage.delta.same", defaultValue: "About the same as your age")
    static func younger(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.delta.younger", defaultValue: "\(years) years younger than your age")
    }
    static func older(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.delta.older", defaultValue: "\(years) years older than your age")
    }

    // Factors
    static let factorsTitle = LocalizedStringResource("zoop.fitnessage.factors.title", defaultValue: "What shapes it")
    static let factorsHint = LocalizedStringResource("zoop.fitnessage.factors.hint",
        defaultValue: "Add your waist in Settings or a VO₂max in Apple Health to include your fitness.")
    static let labelVO2 = LocalizedStringResource("zoop.fitnessage.label.vo2", defaultValue: "VO₂max")
    static let labelVO2Estimated = LocalizedStringResource("zoop.fitnessage.label.vo2est", defaultValue: "VO₂max (estimated)")
    static let labelRHR = LocalizedStringResource("zoop.fitnessage.label.rhr", defaultValue: "Resting heart rate baseline")
    static let labelHRV = LocalizedStringResource("zoop.fitnessage.label.hrv", defaultValue: "HRV baseline")
    static let labelActivity = LocalizedStringResource("zoop.fitnessage.label.activity", defaultValue: "Activity")
    static let labelBodyFat = LocalizedStringResource("zoop.fitnessage.label.bodyfat", defaultValue: "Body fat")
    static let labelBMI = LocalizedStringResource("zoop.fitnessage.label.bmi", defaultValue: "BMI")
    static let labelSleep = LocalizedStringResource("zoop.fitnessage.label.sleep", defaultValue: "Sleep regularity")

    static func years(_ signed: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.row.years", defaultValue: "\(signed) yrs")
    }
    static func yearsSpoken(_ signed: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.row.years.spoken", defaultValue: "\(signed) years")
    }
    static func removes(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.meaning.removes", defaultValue: "Takes about \(years) years off your fitness age.")
    }
    static func adds(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.meaning.adds", defaultValue: "Adds about \(years) years to your fitness age.")
    }
    static let neutral = LocalizedStringResource("zoop.fitnessage.meaning.neutral",
        defaultValue: "Has almost no effect on your fitness age.")

    static let trendImproving = LocalizedStringResource("zoop.fitnessage.trend.improving", defaultValue: "Improving")
    static let trendWorsening = LocalizedStringResource("zoop.fitnessage.trend.worsening", defaultValue: "Worsening")
    static let trendSteady = LocalizedStringResource("zoop.fitnessage.trend.steady", defaultValue: "Steady")

    // Lever ("Hebel")
    static let leverTitle = LocalizedStringResource("zoop.fitnessage.lever.title", defaultValue: "Lever")
    static let leverNone = LocalizedStringResource("zoop.fitnessage.lever.none",
        defaultValue: "No single change stands out: your factors sit close to their reference.")
    static let leverFootnote = LocalizedStringResource("zoop.fitnessage.lever.footnote",
        defaultValue: "A what-if from the same model as your number, not a prediction. Levers overlap, so their years do not add up, and your 30-day averages need about 8 weeks to follow.")
    static let leverAerobic = LocalizedStringResource("zoop.fitnessage.lever.aerobic.title", defaultValue: "Aerobic fitness")
    static let leverRHR = LocalizedStringResource("zoop.fitnessage.lever.rhr.title", defaultValue: "Resting heart rate")
    static let leverActivity = LocalizedStringResource("zoop.fitnessage.lever.activity.title", defaultValue: "Weekly activity")
    static let leverSleep = LocalizedStringResource("zoop.fitnessage.lever.sleep.title", defaultValue: "Sleep regularity")
    static let leverBody = LocalizedStringResource("zoop.fitnessage.lever.body.title", defaultValue: "Body composition")
    static func leverAerobicText(_ step: String, _ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.lever.aerobic.text",
            defaultValue: "With a VO₂max \(step) higher, the model puts your fitness age about \(years) years lower.")
    }
    static func leverRHRText(_ step: String, _ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.lever.rhr.text",
            defaultValue: "With a resting heart rate \(step) lower, the model puts your fitness age about \(years) years lower.")
    }
    static func leverActivityText(_ step: String, _ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.lever.activity.text",
            defaultValue: "With your activity index \(step) higher, the model puts your fitness age about \(years) years lower.")
    }
    static func leverSleepText(_ step: String, _ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.lever.sleep.text",
            defaultValue: "With your sleep regularity \(step) higher, the model puts your fitness age about \(years) years lower.")
    }
    static func leverBodyText(_ step: String, _ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.lever.body.text",
            defaultValue: "With \(step) less on the body measure, the model puts your fitness age about \(years) years lower.")
    }

    // Charts
    static let historyTitle = LocalizedStringResource("zoop.fitnessage.history.title", defaultValue: "Last 90 days")
    static let historyEmpty = LocalizedStringResource("zoop.fitnessage.history.empty",
        defaultValue: "A line appears after a second week.")
    static func historyNote(_ years: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.history.note", defaultValue: "The shaded band is the ± \(years) years this estimate can be off.")
    }
    static let vo2Title = LocalizedStringResource("zoop.fitnessage.vo2.title", defaultValue: "VO₂max over time")
    static let vo2Empty = LocalizedStringResource("zoop.fitnessage.vo2.empty",
        defaultValue: "A line appears once there are two VO₂max values.")
    static let vo2Note = LocalizedStringResource("zoop.fitnessage.vo2.note",
        defaultValue: "The shaded band is typical for people within 5 years of your age.")

    // Method
    static let methodTitle = LocalizedStringResource("zoop.fitnessage.method.title", defaultValue: "Method")
    static let methodBlend = LocalizedStringResource("zoop.fitnessage.method.blend",
        defaultValue: "Six factors, each turned into years older or younger than a typical person of your age and sex, then blended. VO₂max counts most at 40 %.")
    static let methodCadence = LocalizedStringResource("zoop.fitnessage.method.cadence",
        defaultValue: "Inputs are 30-day middle values and the number is written once a week, so it moves slowly.")
    static let methodSources = LocalizedStringResource("zoop.fitnessage.method.sources",
        defaultValue: "Based on Nes et al. 2011 and 2013, Kaminsky et al. 2015 and Kodama et al. 2009. An estimate for tracking direction, not a medical measurement.")

    // Explainer: what it is, method name and summary, per factor
    static let confidenceWeekly = LocalizedStringResource("zoop.fitnessage.confidence.weekly",
        defaultValue: "Judged on a 30-day middle value and updated weekly, so one odd night barely moves it.")
    static func confidenceEstimate(_ see: String) -> LocalizedStringResource {
        LocalizedStringResource("zoop.fitnessage.confidence.vo2est",
            defaultValue: "Estimated from age, waist, resting heart rate and activity, not measured. Typical error ± \(see) ml/kg/min.")
    }
}
