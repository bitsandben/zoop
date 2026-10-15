import Foundation
import Combine
import StrandAnalytics

/// Settings for the strap's physical inputs and the automations built on the live event and biometric
/// stream. UserDefaults-backed.
@MainActor
final class BehaviorStore: ObservableObject {

    // MARK: Double-tap → Mac action
    @Published var doubleTapAction: MacActionKind { didSet { d.set(doubleTapAction.rawValue, forKey: K.dtAction) } }
    @Published var doubleTapShortcut: String { didSet { d.set(doubleTapShortcut, forKey: K.dtShortcut) } }

    // MARK: Wear automation
    @Published var autoLockOnWristOff: Bool { didSet { d.set(autoLockOnWristOff, forKey: K.autoLock) } }
    @Published var wristOffShortcut: String { didSet { d.set(wristOffShortcut, forKey: K.wristOffShortcut) } }
    @Published var wristOnShortcut: String { didSet { d.set(wristOnShortcut, forKey: K.wristOnShortcut) } }

    // MARK: HR-zone haptic coaching (during a live session)
    @Published var zoneCoaching: Bool { didSet { d.set(zoneCoaching, forKey: K.zoneCoaching) } }

    // MARK: Haptic biofeedback — Stress check-ins (L3)
    // Stress check-in (haptic) toggles. Default off. These mirror the keys `BiofeedbackPrefs` reads, so a
    // write through either path is seen by both.
    @Published var stressCheckIn: Bool { didSet { d.set(stressCheckIn, forKey: K.stressCheckIn) } }
    @Published var stressAutoNudge: Bool { didSet { d.set(stressAutoNudge, forKey: K.stressAutoNudge) } }
    @Published var stressQuietHours: Bool { didSet { d.set(stressQuietHours, forKey: K.stressQuietHours) } }
    @Published var stressUseResonancePace: Bool { didSet { d.set(stressUseResonancePace, forKey: K.stressUseResonance) } }

    // MARK: Smart alarm
    @Published var smartAlarmEnabled: Bool { didSet { d.set(smartAlarmEnabled, forKey: K.alarmOn) } }
    @Published var smartAlarmMinutes: Int { didSet { d.set(smartAlarmMinutes, forKey: K.alarmTime) } }
    /// Weekdays the alarm fires on (1 = Sun ... 7 = Sat). Empty means every day.
    @Published var smartAlarmWeekdays: Set<Int> { didSet { d.set(Array(smartAlarmWeekdays).sorted(), forKey: K.alarmWeekdays) } }

    // MARK: Illness early-warning
    @Published var illnessWatch: Bool { didSet { d.set(illnessWatch, forKey: K.illness) } }

    // MARK: Strap battery alerts
    /// Low-battery (<=15%) and full-charge notifications. Default on (#368).
    @Published var batteryAlerts: Bool { didSet { d.set(batteryAlerts, forKey: K.batteryAlerts) } }
    /// Predictive "recharge tonight" warning at ~24h runtime left; sub-gate under batteryAlerts.
    @Published var batteryPredictiveAlerts: Bool { didSet { d.set(batteryPredictiveAlerts, forKey: K.batteryPredictiveAlerts) } }

    // MARK: Strain target nudge (#593)
    /// Once-a-day nudge when Effort reaches the low end of today's recovery-derived optimal band.
    @Published var strainTargetNudge: Bool { didSet { d.set(strainTargetNudge, forKey: K.strainTargetNudge) } }

    private let d = UserDefaults.standard
    private enum K {
        static let dtAction = "behavior.doubleTapAction"
        static let dtShortcut = "behavior.doubleTapShortcut"
        static let autoLock = "behavior.autoLockOnWristOff"
        static let wristOffShortcut = "behavior.wristOffShortcut"
        static let wristOnShortcut = "behavior.wristOnShortcut"
        static let zoneCoaching = "behavior.zoneCoaching"
        // Keys match BiofeedbackPrefs (one source of truth, two readers).
        static let stressCheckIn = "biofeedback.stressCheckIn"
        static let stressAutoNudge = "biofeedback.stressAutoNudge"
        static let stressQuietHours = "biofeedback.stressQuietHours"
        static let stressUseResonance = "biofeedback.stressUseResonancePace"
        static let alarmOn = "behavior.smartAlarmEnabled"
        static let alarmTime = "behavior.smartAlarmMinutes"
        static let alarmWeekdays = "behavior.smartAlarmWeekdays"
        // The retired "behavior.smartAlarmWindow" key is left orphaned on purpose.
        static let illness = "behavior.illnessWatch"
        static let batteryAlerts = "behavior.batteryAlerts"
        static let batteryPredictiveAlerts = "behavior.batteryPredictiveAlerts"
        static let strainTargetNudge = "behavior.strainTargetNudge"
    }

    init() {
        doubleTapAction = MacActionKind(rawValue: d.string(forKey: K.dtAction) ?? "") ?? .none
        doubleTapShortcut = d.string(forKey: K.dtShortcut) ?? ""
        autoLockOnWristOff = d.object(forKey: K.autoLock) as? Bool ?? false
        wristOffShortcut = d.string(forKey: K.wristOffShortcut) ?? ""
        wristOnShortcut = d.string(forKey: K.wristOnShortcut) ?? ""
        zoneCoaching = d.object(forKey: K.zoneCoaching) as? Bool ?? false
        stressCheckIn = d.object(forKey: K.stressCheckIn) as? Bool ?? false
        stressAutoNudge = d.object(forKey: K.stressAutoNudge) as? Bool ?? false
        stressQuietHours = d.object(forKey: K.stressQuietHours) as? Bool ?? true
        stressUseResonancePace = d.object(forKey: K.stressUseResonance) as? Bool ?? true
        smartAlarmEnabled = d.object(forKey: K.alarmOn) as? Bool ?? false
        smartAlarmMinutes = d.object(forKey: K.alarmTime) as? Int ?? 7 * 60       // 07:00
        // Only valid weekday numbers (1...7) are kept so a corrupted entry cannot schedule a bogus day.
        smartAlarmWeekdays = Set((d.array(forKey: K.alarmWeekdays) as? [Int] ?? []).filter { (1...7).contains($0) })
        illnessWatch = d.object(forKey: K.illness) as? Bool ?? false
        batteryAlerts = d.object(forKey: K.batteryAlerts) as? Bool ?? true
        batteryPredictiveAlerts = d.object(forKey: K.batteryPredictiveAlerts) as? Bool ?? true
        strainTargetNudge = d.object(forKey: K.strainTargetNudge) as? Bool ?? false
    }

    // MARK: Charge baseline recalibration

    /// Epoch seconds of the last manual Charge baseline reset, or 0. Reads the canonical
    /// `Baselines.recoveryBaselineEpochKey`.
    var chargeBaselineEpoch: Double { Baselines.recoveryBaselineEpoch(d) }

    /// True once the user has recalibrated Charge, so surfaces can explain why the score is calibrating again.
    var didRecalibrateCharge: Bool { chargeBaselineEpoch > 0 }

}
