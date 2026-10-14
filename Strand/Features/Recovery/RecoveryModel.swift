import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - RecoveryModel
//
// Gathers what the builder needs from the repository and publishes the finished content. All numbers,
// verdicts and sentences are made in `RecoveryContentBuilder`; the screen only renders them.

@MainActor
final class RecoveryModel: ObservableObject {
    @Published private(set) var content: RecoveryContent?

    func load(repo: Repository) async {
        let now = Date()
        let calibrationOn = RecoveryCalibrationStore.isEnabled
        // Show the score first; the check-in read hits the store and must never hold the screen blank.
        content = build(repo: repo, now: now, calibrationOn: calibrationOn, checkIns: [:])
        guard calibrationOn else { return }
        let checkIns = await repo.morningCheckIns()
        content = build(repo: repo, now: now, calibrationOn: true, checkIns: checkIns)
    }

    private func build(repo: Repository, now: Date, calibrationOn: Bool,
                       checkIns: [String: MorningCheckIn]) -> RecoveryContent {
        RecoveryContentBuilder.build(RecoveryInput(
            days: repo.days,
            // The same anchor Home resolves its Recovery ring through, so the two cannot disagree.
            anchor: Repository.widgetAnchor(days: repo.days, now: now),
            baselines: repo.chargeBaselines,
            scoring: RecoveryCalibrationStore.lastScoring,
            checkIns: checkIns,
            calibrationEnabled: calibrationOn,
            calibration: RecoveryCalibrationStore.lastResult,
            now: now,
            todayKey: Repository.logicalDayKey(now)))
    }
}
