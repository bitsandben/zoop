import Foundation

// MARK: - Add / Edit workout copy (zoop.workout.manual.* catalogue entries)

enum ManualWorkoutStrings {
    static var addTitle: String { String(localized: "zoop.workout.manual.addTitle", defaultValue: "New workout", bundle: .main) }
    static var editTitle: String { String(localized: "zoop.workout.manual.editTitle", defaultValue: "Edit workout", bundle: .main) }
    static var sport: String { String(localized: "zoop.workout.manual.sport", defaultValue: "Sport", bundle: .main) }
    static var chooseSport: String { String(localized: "zoop.workout.manual.chooseSport", defaultValue: "Choose a sport", bundle: .main) }
    static var recent: String { String(localized: "zoop.workout.manual.recent", defaultValue: "Recent", bundle: .main) }
    static var allSports: String { String(localized: "zoop.workout.manual.allSports", defaultValue: "All sports", bundle: .main) }
    static func useTyped(_ text: String) -> String {
        String(localized: "zoop.workout.manual.useTyped", defaultValue: "Use \u{201C}\(text)\u{201D}", bundle: .main)
    }
    static var whenTitle: String { String(localized: "zoop.workout.manual.when", defaultValue: "When", bundle: .main) }
    static var date: String { String(localized: "zoop.workout.manual.date", defaultValue: "Date", bundle: .main) }
    static func endsAt(_ time: String) -> String {
        String(localized: "zoop.workout.manual.endsAt", defaultValue: "Ends at \(time)", bundle: .main)
    }
    static var optionalTitle: String { String(localized: "zoop.workout.manual.optional", defaultValue: "Details", bundle: .main) }
    static var optionalFooter: String {
        String(localized: "zoop.workout.manual.optional.footer",
               defaultValue: "All optional. Leave out what you do not know.", bundle: .main)
    }
    static var effortTitle: String { String(localized: "zoop.workout.manual.effort", defaultValue: "Effort", bundle: .main) }
    static var effortEstimated: String {
        String(localized: "zoop.workout.manual.effort.estimated",
               defaultValue: "Estimate from your average heart rate and the duration.", bundle: .main)
    }
    static var effortCaptured: String {
        String(localized: "zoop.workout.manual.effort.captured",
               defaultValue: "Recorded live during this session.", bundle: .main)
    }
    static var effortFromStrap: String {
        String(localized: "zoop.workout.manual.effort.fromStrap",
               defaultValue: "Add your average heart rate for an estimate. Otherwise Zoop scores it from your strap after saving.",
               bundle: .main)
    }
}
