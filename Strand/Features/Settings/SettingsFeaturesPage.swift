import SwiftUI
import StrandDesign

/// Features: the optional parts of Zoop a person switches on or off for themselves.
struct SettingsFeaturesPage: View {
    /// Coach master switch. Read by the Coach tab/accessory, Today's launcher card and
    /// `CoachBriefScheduler`; the saved provider key is kept, so off is a flip rather than a re-setup.
    @AppStorage("zoop.coachEnabled") private var coachEnabled = true
    /// #627: the persistent logbook card on Today.
    @AppStorage(PuffinExperiment.journalReminderKey) private var journalReminderEnabled = true
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Suggests, never saves: a detected session becomes a workout only when the user taps Save.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkoutsEnabled = true
    /// #703: read by the live-workout view while a manual recording runs.
    @AppStorage("workoutKeepScreenOn") private var workoutKeepScreenOn = false

    var body: some View {
        SettingsPageScaffold(title: "Features") {
            SettingsGroup(title: "zoop.settings.group.coachAndLogbook") {
                SettingsToggleRow(label: "AI Coach", isOn: $coachEnabled,
                                  note: "zoop.settings.features.coachNote", isFirst: true)
                    // Off has to take down the brief the widget already shows, not only stop the next one.
                    .onChangeCompat(of: coachEnabled) { CoachBriefScheduler.applyMasterSwitch($0) }
                SettingsLinkRow(label: "zoop.settings.features.checkIn") { RecoveryCalibrationView() }
                SettingsToggleRow(label: "Logbook reminder", isOn: $journalReminderEnabled,
                                  note: "zoop.settings.features.logbookNote")
            }
            SettingsGroup(title: "zoop.settings.group.tracking") {
                SettingsToggleRow(label: "Hydration tracking", isOn: $hydrationEnabled,
                                  note: "zoop.settings.features.hydrationNote", isFirst: true)
                SettingsToggleRow(label: "Auto-detect workouts", isOn: $autoDetectWorkoutsEnabled,
                                  note: "zoop.settings.features.autoDetectNote")
                SettingsToggleRow(label: "Keep screen on during a workout", isOn: $workoutKeepScreenOn,
                                  note: "zoop.settings.features.keepScreenNote")
            }
            #if os(iOS)
            SettingsGroup {
                SettingsLinkRow(label: "Siri & Shortcuts", icon: "mic.fill", isFirst: true) {
                    SiriShortcutsSettingsView()
                }
            }
            #endif
        }
    }
}
