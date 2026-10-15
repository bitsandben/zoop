import Foundation

// MARK: - Live workout copy (zoop.workout.live.* catalogue entries)
//
// Resolved to `String` at the point of use against the main bundle, like `TrainingStrings`, so the
// app-language override applies and previews fall back to the English default.

enum LiveWorkoutStrings {

    // Field names
    static var fieldTime: String { String(localized: "zoop.workout.live.field.time", defaultValue: "Time", bundle: .main) }
    static var fieldDistance: String { String(localized: "zoop.workout.live.field.distance", defaultValue: "Distance", bundle: .main) }
    static var fieldCurrentPace: String { String(localized: "zoop.workout.live.field.currentPace", defaultValue: "Current pace", bundle: .main) }
    static var fieldAveragePace: String { String(localized: "zoop.workout.live.field.averagePace", defaultValue: "Average pace", bundle: .main) }
    static var fieldHeartRate: String { String(localized: "zoop.workout.live.field.heartRate", defaultValue: "Heart rate", bundle: .main) }
    static var fieldZone: String { String(localized: "zoop.workout.live.field.zone", defaultValue: "Heart-rate zone", bundle: .main) }
    static var fieldAverageHeartRate: String {
        String(localized: "zoop.workout.live.field.averageHeartRate", defaultValue: "Average heart rate", bundle: .main)
    }
    static var fieldCalories: String { String(localized: "zoop.workout.live.field.calories", defaultValue: "Calories", bundle: .main) }
    static var fieldEffort: String { String(localized: "zoop.workout.live.field.effort", defaultValue: "Effort", bundle: .main) }
    static var fieldElevation: String { String(localized: "zoop.workout.live.field.elevation", defaultValue: "Elevation gain", bundle: .main) }
    static var fieldSplits: String { String(localized: "zoop.workout.live.field.splits", defaultValue: "Splits", bundle: .main) }

    // Status and controls
    static var recording: String { String(localized: "zoop.workout.live.status.recording", defaultValue: "Recording", bundle: .main) }
    static var paused: String { String(localized: "zoop.workout.live.status.paused", defaultValue: "Paused", bundle: .main) }
    static var minimize: String { String(localized: "zoop.workout.live.minimize", defaultValue: "Minimize", bundle: .main) }
    static var customize: String { String(localized: "zoop.workout.live.customize", defaultValue: "Customize fields", bundle: .main) }
    static var openWorkout: String {
        String(localized: "zoop.workout.live.bar.open", defaultValue: "Open the running workout", bundle: .main)
    }

    static var deleteTitle: String {
        String(localized: "zoop.workout.live.delete.title", defaultValue: "Delete this workout?", bundle: .main)
    }
    static var deleteMessage: String {
        String(localized: "zoop.workout.live.delete.message",
               defaultValue: "Nothing from this session is saved.", bundle: .main)
    }

    // States in place of a number
    static var noSignal: String { String(localized: "zoop.workout.live.state.noSignal", defaultValue: "No signal", bundle: .main) }
    static var searchingGPS: String { String(localized: "zoop.workout.live.state.searchingGPS", defaultValue: "Searching GPS", bundle: .main) }
    static var notMoving: String { String(localized: "zoop.workout.live.state.notMoving", defaultValue: "Not moving", bundle: .main) }
    static var needsDistance: String { String(localized: "zoop.workout.live.state.needsDistance", defaultValue: "After a few metres", bundle: .main) }
    static var waitingAltitude: String {
        String(localized: "zoop.workout.live.state.waitingAltitude", defaultValue: "Waiting for altitude", bundle: .main)
    }
    static var needsHeartRate: String {
        String(localized: "zoop.workout.live.state.needsHeartRate", defaultValue: "Needs heart rate", bundle: .main)
    }
    static var belowZone1: String { String(localized: "zoop.workout.live.zone.below", defaultValue: "Below zone 1", bundle: .main) }
    static func zone(_ n: Int) -> String {
        String(localized: "zoop.workout.live.zone.value", defaultValue: "Zone \(n)", bundle: .main)
    }

    // Location
    static var gpsDeniedTitle: String {
        String(localized: "zoop.workout.live.gps.denied.title", defaultValue: "Location access is off", bundle: .main)
    }
    static var gpsDeniedMessage: String {
        String(localized: "zoop.workout.live.gps.denied.message",
               defaultValue: "Distance and pace need location access. Heart rate and effort keep recording.", bundle: .main)
    }
    static var gpsUnavailable: String {
        String(localized: "zoop.workout.live.gps.unavailable",
               defaultValue: "This device has no GPS, so distance and pace stay off.", bundle: .main)
    }
    static var gpsAsk: String {
        String(localized: "zoop.workout.live.gps.ask",
               defaultValue: "Allow location access to record distance and pace.", bundle: .main)
    }
    static var gpsUnavailableShort: String { String(localized: "zoop.workout.live.gps.off", defaultValue: "No GPS", bundle: .main) }
    static var openSettings: String { String(localized: "zoop.workout.live.gps.openSettings", defaultValue: "Open Settings", bundle: .main) }

    // Splits
    static func kilometer(_ n: Int) -> String {
        String(localized: "zoop.workout.live.split.km", defaultValue: "Kilometre \(n)", bundle: .main)
    }
    static func mile(_ n: Int) -> String {
        String(localized: "zoop.workout.live.split.mile", defaultValue: "Mile \(n)", bundle: .main)
    }
    static var splitInProgress: String { String(localized: "zoop.workout.live.split.current", defaultValue: "In progress", bundle: .main) }
    static var firstSplitKm: String {
        String(localized: "zoop.workout.live.split.firstKm", defaultValue: "Your first split appears after 1 km.", bundle: .main)
    }
    static var firstSplitMile: String {
        String(localized: "zoop.workout.live.split.firstMile", defaultValue: "Your first split appears after 1 mile.", bundle: .main)
    }

    // Field editor
    static var editorPrimary: String { String(localized: "zoop.workout.live.editor.primary", defaultValue: "Large field", bundle: .main) }
    static var editorPrimaryFooter: String {
        String(localized: "zoop.workout.live.editor.primary.footer", defaultValue: "Shown at the top in large type.", bundle: .main)
    }
    static var editorFields: String { String(localized: "zoop.workout.live.editor.fields", defaultValue: "Fields", bundle: .main) }
    static func editorSavedFor(_ sport: String) -> String {
        String(localized: "zoop.workout.live.editor.savedFor", defaultValue: "Saved for \(sport).", bundle: .main)
    }
    static var editorGPSOnly: String {
        String(localized: "zoop.workout.live.editor.gpsOnly",
               defaultValue: "Distance, pace and splits are only offered for GPS sports.", bundle: .main)
    }
    static var editorReset: String { String(localized: "zoop.workout.live.editor.reset", defaultValue: "Reset to default", bundle: .main) }
}
