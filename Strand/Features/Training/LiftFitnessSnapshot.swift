import SwiftUI
import StrandAnalytics
import WhoopStore

/// Everything the Training page shows about lifting and muscle load, loaded once per refresh.
struct LiftFitnessSnapshot: Equatable {
    /// Nil when there is no lift session in the last 180 days: the muscular gauge then hides.
    var muscular: TrainingLoadGauge.Reading?
    var week: TrainingLoadGauge.StrengthWeek
    /// A lift session ended within the last 14 days: gates the Strength totals.
    var hasRecentLifts: Bool
    /// Per-muscle load from every workout (`MuscleLoad`); nil when nothing ended in the last 14 days.
    var muscleLoad: MuscleLoad.Result?
    /// The instant `muscleLoad` was computed at; its week boundaries hang off it.
    var computedAt: Int

    static let empty = LiftFitnessSnapshot(muscular: nil, week: .init(workingSets: 0, volumeKg: 0),
                                           hasRecentLifts: false, muscleLoad: nil, computedAt: 0)

    /// Read finished lift sessions (180 days) with the sets of the last 28 days, plus the workouts of
    /// the last four weeks for the muscle-load model.
    static func load(repo: Repository, hrMax: Int?, now: Date = Date()) async -> LiftFitnessSnapshot {
        guard let store = await repo.storeHandle() else { return .empty }
        let nowTs = Int(now.timeIntervalSince1970)
        let sessions = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                       fromTs: nowTs - 180 * 86_400,
                                                       toTs: nowTs)) ?? [])
            .filter { $0.endTs != nil }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func daysAgo(_ ts: Int) -> Int {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            return cal.dateComponents([.day], from: d, to: today).day ?? 0
        }

        var liftDays: [TrainingLoadGauge.LiftDay] = []
        var loadSessions: [MuscleLoad.Session] = []
        var liftStarts = Set<Int>()
        let loadDays = MuscleLoad.weeks * 7 + 1
        let loadCutoff = nowTs - loadDays * 86_400
        for row in sessions {
            let end = row.endTs ?? row.startTs
            let ago = daysAgo(end)
            guard ago < TrainingLoadGauge.chronicWindowDays || end >= loadCutoff else { continue }
            let sets = (try? await store.liftSets(sessionId: row.id)) ?? []
            let day = TrainingLoadGauge.LiftDay(daysAgo: ago, sets: sets)
            liftDays.append(day)
            if end >= loadCutoff {
                loadSessions.append(.lift(sport: row.sport, startTs: row.startTs, endTs: end, sets: sets))
                liftStarts.insert(row.startTs)
            }
        }

        // Every other workout goes through its sport table. A logged lift shares its workout row's
        // start, so that row is skipped: its sets already counted.
        let restingHr = await MainActor.run { repo.days.last(where: { $0.restingHr != nil })?.restingHr }
        for row in await repo.workoutRows(days: loadDays)
        where row.endTs >= loadCutoff && !liftStarts.contains(row.startTs) {
            loadSessions.append(.workout(row, hrMax: hrMax, restingHr: restingHr))
        }

        let latestEnd = sessions.compactMap(\.endTs).max() ?? 0
        let first = sessions.map(\.startTs).min()
        return LiftFitnessSnapshot(
            muscular: first.flatMap {
                TrainingLoadGauge.muscular(sessions: liftDays, historyDays: daysAgo($0) + 1)
            },
            week: TrainingLoadGauge.strengthWeek(sessions: liftDays),
            hasRecentLifts: latestEnd >= nowTs - 14 * 86_400,
            muscleLoad: MuscleLoad.compute(sessions: loadSessions, now: nowTs),
            computedAt: nowTs)
    }
}
