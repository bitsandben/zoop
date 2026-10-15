import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

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
        // Show the score first; the store reads must never hold the screen blank.
        content = build(repo: repo, now: now, calibrationOn: calibrationOn, checkIns: [:], journal: [])
        let checkIns = calibrationOn ? await repo.morningCheckIns() : [:]
        let journal = await repo.journalEntries(days: 400)
        content = build(repo: repo, now: now, calibrationOn: calibrationOn, checkIns: checkIns, journal: journal)
    }

    private func build(repo: Repository, now: Date, calibrationOn: Bool,
                       checkIns: [String: MorningCheckIn], journal: [JournalEntry]) -> RecoveryContent {
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
            todayKey: Repository.logicalDayKey(now),
            sleeps: repo.sleeps,
            journal: journal,
            illnessSignals: illnessSignals))
    }

    /// The illness engine's one decision for today; a quiet or confounded result names no signals.
    private var illnessSignals: Int {
        guard let result = AppModel.shared?.illnessSignal else { return 0 }
        switch result.level {
        case .mild, .raised: return result.signalCount
        case .quiet, .suppressed, .alreadyUnwell: return 0
        }
    }
}
