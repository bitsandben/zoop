#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

/// Collects what moved this morning's recovery for `MorningBriefDrivers`, from the resolvers the
/// Recovery and Sleep screens use: the ranked recovery factors (scorer driver points, bedtime, strain,
/// logged answers, illness), the raw HRV / resting HR / sleep deviations behind them, the personal
/// recovery range, and last night's movement against earlier nights.
@MainActor
enum CoachMorningExplain {

    /// Nights of stored motion read for the personal stillness range.
    private static let motionNights = 40

    static func gather(repo: Repository, illness: Bool, now: Date) async -> MorningBriefDrivers.Input {
        var out = MorningBriefDrivers.Input()
        let journal = await repo.journalEntries(days: 400)
        let recovery = RecoveryModel.input(repo: repo, now: now, journal: journal)
        out.recovery = recovery.anchor?.day == recovery.todayKey ? recovery.anchor?.recovery : nil
        out.recoveryRange = RecoveryContentBuilder.recoveryRange(days: repo.days.filter { $0.day < recovery.todayKey })
        out.illness = illness

        if let row = recovery.anchor, let baselines = recovery.baselines {
            let drivers = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row,
                                                          charge: recovery.scoring)?.drivers ?? []
            if let factors = RecoveryFactorsBuilder.factorsInput(recovery, drivers: drivers) {
                out.factors = RecoveryFactors.rank(factors, limit: .max)
                out.hrvPercent = factors.hrvPercent
                out.restingHRDelta = factors.restingHRDelta
                out.sleepMinutesVsNeed = factors.sleepMinutesVsNeed
            }
        }
        if !repo.activeDeviceIsOura { await addRestlessness(to: &out, repo: repo, todayKey: recovery.todayKey) }
        return out
    }

    /// Last night's movement bouts and restless minutes, with the earlier nights as the personal range.
    /// The same grouping and analysis as the Sleep screen's stillness card.
    private static func addRestlessness(to out: inout MorningBriefDrivers.Input, repo: Repository, todayKey: String) async {
        let sessions = await repo.allSleepSessions(days: motionNights)
        guard !sessions.isEmpty else { return }
        let habitual = await repo.habitualMidsleepSec()
        let motions = await repo.sessionMotions(sessions: sessions)
        let navDays = SleepModel.navDays(navSessions: sessions)
        let entries = SleepRestlessReadouts.entries(navDays: navDays, habitualMidsleepSec: habitual, motions: motions)
        guard let tonight = entries[0], tonight.day == todayKey else { return }
        let earlier = entries.filter { $0.key > 0 }.sorted { $0.key > $1.key }.map(\.value.night)
        out.restlessBouts = tonight.night.bouts
        out.restlessMinutes = tonight.night.restlessMinutes
        out.restlessHistoryBouts = earlier.map { Double($0.bouts) }
        out.restlessHistoryMinutes = earlier.map(\.restlessMinutes)
        out.restlessSolid = tonight.night.confidence == .solid
    }
}
#endif
