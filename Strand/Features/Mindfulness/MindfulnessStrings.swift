import Foundation
import StrandAnalytics

// MARK: - Mindfulness copy (zoop.mindful.* catalogue entries)
//
// German-first in the catalogue; the English default values below are the fallback for tests/previews.

enum MindfulnessStrings {

    // Section
    static let title = LocalizedStringResource("zoop.mindful.title", defaultValue: "Mindfulness", bundle: .main)
    static let subtitle = LocalizedStringResource("zoop.mindful.subtitle", defaultValue: "Yoga, meditation and breathing", bundle: .main)
    static let effectTitle = LocalizedStringResource("zoop.mindful.effect.title", defaultValue: "What it does", bundle: .main)
    static let effectSubtitle = LocalizedStringResource("zoop.mindful.effect.subtitle",
                                                        defaultValue: "Heart rate, HRV and stress around your practice", bundle: .main)
    static let recentTitle = LocalizedStringResource("zoop.mindful.recent.title", defaultValue: "Recent sessions", bundle: .main)
    static let emptyTitle = LocalizedStringResource("zoop.mindful.empty.title", defaultValue: "No mindfulness yet", bundle: .main)
    static let emptyMessage = LocalizedStringResource("zoop.mindful.empty.message",
        defaultValue: "Yoga, meditation and breathing show up here, with their effect on heart rate and stress.", bundle: .main)
    static let meditate = LocalizedStringResource("zoop.mindful.action.meditate", defaultValue: "Meditate", bundle: .main)
    static let breathe = LocalizedStringResource("zoop.mindful.action.breathe", defaultValue: "Breathe", bundle: .main)

    // Labels
    static let minutesLabel = LocalizedStringResource("zoop.mindful.minutes.label", defaultValue: "Last 7 days", bundle: .main)
    static let daysLabel = LocalizedStringResource("zoop.mindful.days.label", defaultValue: "Practice days", bundle: .main)
    static let hrDropLabel = LocalizedStringResource("zoop.mindful.hrDrop.label", defaultValue: "Heart rate drop", bundle: .main)
    static let hrvChangeLabel = LocalizedStringResource("zoop.mindful.hrvChange.label", defaultValue: "HRV during practice", bundle: .main)
    static let stressLabel = LocalizedStringResource("zoop.mindful.stress.label", defaultValue: "Stress afterwards", bundle: .main)
    static let rhrLabel = LocalizedStringResource("zoop.mindful.rhr.label", defaultValue: "Resting HR after practice days", bundle: .main)
    static let hrvNightLabel = LocalizedStringResource("zoop.mindful.hrvNight.label", defaultValue: "Night HRV after practice days", bundle: .main)

    // Meanings: practice volume
    static let minutesNone = LocalizedStringResource("zoop.mindful.minutes.none", defaultValue: "No practice in the last 7 days yet.", bundle: .main)
    static let minutesAbove = LocalizedStringResource("zoop.mindful.minutes.above", defaultValue: "More practice than in a normal week.", bundle: .main)
    static let minutesTypical = LocalizedStringResource("zoop.mindful.minutes.typical", defaultValue: "About as much as in a normal week.", bundle: .main)
    static let minutesBelow = LocalizedStringResource("zoop.mindful.minutes.below",
                                                      defaultValue: "Less than usual; a few minutes already count.", bundle: .main)
    static func streak(_ days: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.days.streak", defaultValue: "You have practised \(days) days in a row.", bundle: .main)
    }
    static let daysMeaning = LocalizedStringResource("zoop.mindful.days.meaning",
                                                     defaultValue: "Regular short sessions tend to matter more than long ones.", bundle: .main)

    // Meanings: session response
    static func needSessions(_ have: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.effect.needSessions",
                                defaultValue: "Needs 3 sessions of 5+ minutes with heart data; \(have) so far.", bundle: .main)
    }
    static func hrDropClear(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.hrDrop.clear", defaultValue: "Your heart clearly settles while you practise (\(n) sessions).", bundle: .main)
    }
    static func hrDropNone(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.hrDrop.none", defaultValue: "No clear heart-rate drop yet (\(n) sessions).", bundle: .main)
    }
    static let hrDropRises = LocalizedStringResource("zoop.mindful.hrDrop.rises",
                                                     defaultValue: "Your heart rate rises while practising, as in dynamic yoga.", bundle: .main)
    static let trendDeeper = LocalizedStringResource("zoop.mindful.trend.deeper",
                                                     defaultValue: "Lately you settle deeper than in your first sessions.", bundle: .main)
    static let trendShallower = LocalizedStringResource("zoop.mindful.trend.shallower",
                                                        defaultValue: "Lately you settle less deeply than in your first sessions.", bundle: .main)
    static func hrvUp(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.hrv.up", defaultValue: "Your HRV rises while you practise (\(n) sessions).", bundle: .main)
    }
    static func hrvFlat(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.hrv.flat", defaultValue: "No clear HRV change while practising (\(n) sessions).", bundle: .main)
    }
    static func hrvDown(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.hrv.down", defaultValue: "Your HRV falls while practising (\(n) sessions).", bundle: .main)
    }
    static func stressCalmer(_ calmer: Int, _ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.stress.calmer",
                                defaultValue: "Stress was lower afterwards in \(calmer) of \(n) sessions.", bundle: .main)
    }
    static func stressNeed(_ have: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.stress.need",
                                defaultValue: "Needs 3 sessions with stress hours before and after; \(have) so far.", bundle: .main)
    }

    // Meanings: days with vs without
    static func contrastNeed(_ with: Int, _ without: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.contrast.need",
                                defaultValue: "Needs 5 nights each with and without practice; \(with) and \(without) so far.", bundle: .main)
    }
    static func contrastBetter(_ with: Int, _ without: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.contrast.better",
                                defaultValue: "Nights after practice look better (\(with) vs \(without) nights).", bundle: .main)
    }
    static func contrastWorse(_ with: Int, _ without: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.contrast.worse",
                                defaultValue: "Nights after practice look worse (\(with) vs \(without) nights).", bundle: .main)
    }
    static func contrastNone(_ with: Int, _ without: Int) -> LocalizedStringResource {
        LocalizedStringResource("zoop.mindful.contrast.none",
                                defaultValue: "No clear difference yet (\(with) vs \(without) nights).", bundle: .main)
    }

    // Kinds and sources
    static func kind(_ k: MindfulPractice.Kind) -> String {
        switch k {
        case .meditation: return String(localized: "zoop.mindful.kind.meditation", defaultValue: "Meditation", bundle: .main)
        case .yoga: return String(localized: "zoop.mindful.kind.yoga", defaultValue: "Yoga", bundle: .main)
        case .breathing: return String(localized: "zoop.mindful.kind.breathing", defaultValue: "Breathing", bundle: .main)
        case .pilates: return String(localized: "zoop.mindful.kind.pilates", defaultValue: "Pilates", bundle: .main)
        case .stretching: return String(localized: "zoop.mindful.kind.stretching", defaultValue: "Stretching", bundle: .main)
        case .taiChi: return String(localized: "zoop.mindful.kind.taichi", defaultValue: "Tai chi", bundle: .main)
        }
    }

    static func source(_ s: MindfulPractice.Source) -> String {
        switch s {
        case .app: return String(localized: "zoop.mindful.source.app", defaultValue: "Zoop", bundle: .main)
        case .workout: return String(localized: "zoop.mindful.source.workout", defaultValue: "Workout", bundle: .main)
        case .appleHealth: return String(localized: "zoop.mindful.source.health", defaultValue: "Apple Health", bundle: .main)
        }
    }
}
