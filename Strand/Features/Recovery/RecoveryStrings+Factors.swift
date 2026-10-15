import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Recovery factor copy (zoop.recovery.factor.* catalogue entries)
//
// One sentence per (factor, direction, sized or not). Numbers are whole percent, whole points and
// locale-formatted durations; the sizes come from `RecoveryFactors`, never from this file.

extension RecoveryStrings {

    private static func f(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value, bundle: .main)
    }

    // Card
    static let factorsTitle = f("zoop.recovery.factors.title", "What set your recovery today")
    static let factorsNote = f("zoop.recovery.factors.note",
        "Estimated from your own days. Factors overlap, so the points do not add up.")
    static let factorsNone = f("zoop.recovery.factors.none",
        "Nothing stood out: yesterday, your sleep and your vitals were close to your normal.")
    static let factorLowers = f("zoop.recovery.factor.lowers", "Lowered your recovery")
    static let factorRaises = f("zoop.recovery.factor.raises", "Supported your recovery")
    static let helpsTitle = f("zoop.recovery.helps.title", "What helps")
    static let helpsCoach = f("zoop.recovery.helps.coach", "More in the coach")
    static let measurementsTitle = f("zoop.recovery.measurements.title", "Your measurements")

    // Logged names
    static let loggedAlcohol = f("zoop.recovery.logged.alcohol", "alcohol")
    static let loggedCaffeine = f("zoop.recovery.logged.caffeine", "late caffeine")
    static let loggedLateMeal = f("zoop.recovery.logged.lateMeal", "a late meal")
    static let loggedStress = f("zoop.recovery.logged.stress", "stress")
    static let loggedSick = f("zoop.recovery.logged.sick", "feeling ill")

    static func factorSentence(_ factor: RecoveryFactors.Factor, name: String) -> LocalizedStringResource {
        let pts = factor.points.map { Int(abs($0).rounded()) }
        let sized = pts.map { $0 >= 1 } ?? false
        let p = pts ?? 0
        let lower = (factor.points ?? 0) < 0
        switch factor.kind {
        case .illness:
            return f("zoop.recovery.factor.illness",
                     "Several body signals are outside your range. Strain, alcohol, heat or an infection starting can do this.")
        case .strain:
            let pct = Int(abs(factor.deviation).rounded())
            if factor.deviation > 0 {
                if sized && lower {
                    return f("zoop.recovery.factor.strain.up.sized",
                             "Your training yesterday was \(pct)% above your average. After days like that your recovery is usually \(p) points lower.")
                }
                if factor.points != nil {
                    return f("zoop.recovery.factor.strain.up.little",
                             "Your training yesterday was \(pct)% above your average. For you, that rarely moves recovery.")
                }
                return f("zoop.recovery.factor.strain.up", "Your training yesterday was \(pct)% above your average.")
            }
            if sized && !lower {
                return f("zoop.recovery.factor.strain.down.sized",
                         "Yesterday was \(pct)% lighter than your average. After days like that your recovery is usually \(p) points higher.")
            }
            return f("zoop.recovery.factor.strain.down", "Yesterday was \(pct)% lighter than your average.")
        case .sleep:
            if lower {
                let dur = duration(minutes: abs(factor.deviation))
                return f("zoop.recovery.factor.sleep.short", "You slept \(dur) less than you need, which cost about \(p) points.")
            }
            return f("zoop.recovery.factor.sleep.enough", "Your sleep covered your need, worth about \(p) points.")
        case .bedtime:
            let dur = duration(minutes: factor.deviation)
            if sized && lower {
                return f("zoop.recovery.factor.bedtime.sized",
                         "You went to bed \(dur) later than usual. For you, that usually means \(p) points less.")
            }
            return f("zoop.recovery.factor.bedtime", "You went to bed \(dur) later than usual.")
        case .hrv:
            let pct = Int(abs(factor.deviation).rounded())
            if lower {
                return f("zoop.recovery.factor.hrv.low", "Your HRV was \(pct)% below your normal, which cost about \(p) points.")
            }
            return f("zoop.recovery.factor.hrv.high", "Your HRV was \(pct)% above your normal, worth about \(p) points.")
        case .restingHR:
            let bpm = Int(abs(factor.deviation).rounded())
            if lower {
                return f("zoop.recovery.factor.rhr.high",
                         "Your resting heart rate was \(bpm) bpm above your normal, which cost about \(p) points.")
            }
            return f("zoop.recovery.factor.rhr.low",
                     "Your resting heart rate was \(bpm) bpm below your normal, worth about \(p) points.")
        case .logged:
            guard sized else {
                return f("zoop.recovery.factor.logged", "You logged \(name). Zoop needs more logged days to size its effect.")
            }
            if lower {
                return f("zoop.recovery.factor.logged.lower", "You logged \(name). On those days your recovery is usually \(p) points lower.")
            }
            return f("zoop.recovery.factor.logged.higher", "You logged \(name). On those days your recovery is usually \(p) points higher.")
        }
    }

    static func advice(_ advice: RecoveryFactors.Advice) -> LocalizedStringResource {
        switch advice {
        case .rest: return f("zoop.recovery.advice.rest", "Rest more today and move hard training to later.")
        case .lightDay: return f("zoop.recovery.advice.lightDay",
            "Keep today light: easy movement helps more than another hard session.")
        case .earlierBed: return f("zoop.recovery.advice.earlierBed", "Go to bed earlier tonight to make up the missing sleep.")
        case .usualBedtime: return f("zoop.recovery.advice.usualBedtime", "Aim for your usual bedtime tonight.")
        case .calmDay: return f("zoop.recovery.advice.calmDay",
            "Plan a calmer day; a walk or a breathing session helps your body settle.")
        case .skipLogged: return f("zoop.recovery.advice.skipLogged",
            "Leave out what you logged today and see how your recovery responds.")
        }
    }

    private static func duration(minutes: Double) -> String {
        MetricUnit.duration.format((minutes / 5).rounded() * 5 * 60, locale: AppLanguage.activeLocale)
    }
}
