import Foundation
import StrandAnalytics

/// The wearer's sleep-onset detection settings: strictness of the HR-confirmed onset rule, and whether a
/// personal offset is learned from their corrections. Read once per scoring pass and threaded into
/// detection as a `SleepOnsetTuning` (math in `StrandAnalytics/SleepOnsetTuning.swift`).
enum SleepOnsetPrefs {
    static let strictnessKey = "zoop.sleepOnsetStrictness"
    static let learnKey = "zoop.sleepOnsetLearn"
    static let correctionsKey = "zoop.sleepOnsetCorrections"

    static var strictness: SleepOnsetStrictness {
        SleepOnsetStrictness(rawValue: UserDefaults.standard.string(forKey: strictnessKey) ?? "") ?? .standard
    }

    /// Default ON: an install that never opens the setting still learns once it has corrections.
    static var learnEnabled: Bool {
        UserDefaults.standard.object(forKey: learnKey) as? Bool ?? true
    }

    static var corrections: [OnsetCorrectionLearning.Correction] {
        OnsetCorrectionLearning.decode(UserDefaults.standard.string(forKey: correctionsKey))
    }

    /// The learned offset in minutes, or nil while learning is off or there is nothing to apply yet.
    static var learnedOffsetMin: Int? {
        learnEnabled ? OnsetCorrectionLearning.learnedOffsetMin(corrections) : nil
    }

    /// What detection runs with right now.
    static var tuning: SleepOnsetTuning {
        SleepOnsetTuning(strictness: strictness, personalOffsetMin: learnedOffsetMin ?? 0)
    }

    /// Records a start-time correction of a MAIN night (never a nap). No-op while learning is off or when the
    /// start did not move. Measured against the bare rule, so the offset currently applied is added back.
    static func recordCorrection(nightKey: Int, detectedStartTs: Int, correctedStartTs: Int) {
        guard learnEnabled, correctedStartTs != detectedStartTs else { return }
        let c = OnsetCorrectionLearning.correction(nightKey: nightKey, detectedStartTs: detectedStartTs,
                                                   correctedStartTs: correctedStartTs,
                                                   appliedOffsetMin: learnedOffsetMin ?? 0)
        let list = OnsetCorrectionLearning.recording(c, into: corrections)
        UserDefaults.standard.set(OnsetCorrectionLearning.encode(list), forKey: correctionsKey)
    }

    static func resetCorrections() {
        UserDefaults.standard.removeObject(forKey: correctionsKey)
    }
}
