import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Today's Energy Bank estimate, assembled from what the Repository already holds: today's heart rate,
/// the sleeps, last night's recovery and sleep, the resting-HR baseline and today's intraday stress.
///
/// The window opens when last night's main sleep ended (or at midnight while no night has ended today)
/// and runs to now. Today's heart rate is read only when `Repository`'s cheap heart-rate fingerprint says
/// it moved, so the Home card can re-ask every few minutes without re-reading the day each time.
enum EnergyBankDay {

    private struct Memo {
        let day: String
        let count: Int
        let maxTs: Int
        let samples: [HRSample]
    }
    @MainActor private static var memo: Memo?

    /// Today's curve, or nil when the repository is not open yet.
    @MainActor
    static func today(repo: Repository, maxHR: Double?, now: Date = Date(),
                      calendar: Calendar = .current) async -> EnergyBank.Result? {
        let startOfDay = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        let todayKey = Repository.localDayKey(now)

        // The main night that ended today anchors the morning value; naps after it recharge.
        let endedToday = repo.sleeps.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == todayKey && $0.endTs <= nowTs
        }
        let mainNight = SleepView.mainNightGroup(endedToday)
        let start = min(max(mainNight.last?.endTs ?? startOfDay, startOfDay), nowTs)
        let mainStarts = Set(mainNight.map(\.startTs))
        let spans = repo.sleeps
            .filter { !mainStarts.contains($0.startTs) && $0.endTs > start && $0.effectiveStartTs < nowTs }
            .map { s in
                EnergyBank.SleepSpan(start: s.effectiveStartTs, end: s.endTs,
                                     quality: s.efficiency.map { $0 > 1 ? $0 / 100 : $0 })
            }

        guard let fingerprint = await repo.hrFingerprint(from: start, to: nowTs) else { return nil }
        let samples: [HRSample]
        if let m = memo, m.day == "\(todayKey)-\(start)", m.count == fingerprint.count, m.maxTs == fingerprint.maxTs {
            samples = m.samples
        } else if let m = memo, m.day == "\(todayKey)-\(start)", fingerprint.maxTs > m.maxTs,
                  fingerprint.count > m.count {
            // Zoop: the strap streams a sample a second, so read only what arrived since the last read
            // instead of the whole day again (that full re-read on every tick was a source of lag).
            let newer = await repo.hrSamples(from: m.maxTs + 1, to: nowTs, limit: 200_000)
            samples = m.samples + newer
            memo = Memo(day: m.day, count: fingerprint.count, maxTs: fingerprint.maxTs, samples: samples)
        } else {
            samples = await repo.hrSamples(from: start, to: nowTs, limit: 200_000)
            memo = Memo(day: "\(todayKey)-\(start)", count: fingerprint.count, maxTs: fingerprint.maxTs,
                        samples: samples)
        }

        let stress = await StressDayCurve.today(
            repo: repo, now: now, calendar: calendar,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result.timeline ?? []
        let stressPoints = stress.compactMap { p in p.level.map { EnergyBank.StressPoint(ts: p.startTs, level: $0) } }

        let today = repo.today
        // Nothing to estimate from: no recovery to open the day and no heart rate to walk it.
        if today?.recovery == nil && samples.isEmpty { return nil }
        let need = SleepModel.debtNeedMin(days: repo.days)
        let sufficiency = today?.totalSleepMin.flatMap { need > 0 ? $0 / need : nil }
        let rests = repo.days.suffix(14).compactMap(\.restingHr).sorted()
        let restingHR = rests.isEmpty ? nil : Double(rests[rests.count / 2])

        let input = EnergyBank.Inputs(start: start, end: nowTs, heartRate: samples, sleeps: spans,
                                      stress: stressPoints, morningRecovery: today?.recovery,
                                      sleepSufficiency: sufficiency, restingHR: restingHR, maxHR: maxHR)
        return await runUnescalated { EnergyBank.compute(input) }
    }
}
