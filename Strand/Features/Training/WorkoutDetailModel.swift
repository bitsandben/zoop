import Foundation
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Workout detail model
//
// Everything one session's detail reads from the repository: the heart-rate curve over its window, the
// zone split, the after-the-workout recovery, steps, the on-device GPS route, and how the session compares
// with the user's other sessions of the same sport. The view only lays out what is published here.

@MainActor
final class WorkoutDetailModel: ObservableObject {

    /// Steps over the session window for an on-foot sport (#398), and whether they came from the strap's
    /// own counter (MG/5.0) or the phone pedometer (fallback for WHOOP 4.0, unsynced windows, CSV import).
    struct StepReadout: Equatable {
        let count: Int
        let fromStrap: Bool
    }

    let row: WorkoutRow

    @Published private(set) var loaded = false
    /// HR curve over the session window (5-minute-ish bucket means).
    @Published private(set) var hrPoints: [TrendPoint] = []
    /// Per-zone MINUTES: the imported split when the row has one, else the window's raw HR binned into
    /// %HRmax zones. Nil = no split to show.
    @Published private(set) var zoneMinutes: [Double]?
    /// True when the split came from the imported percentages rather than the strap's raw heart rate.
    @Published private(set) var zonesFromImport = false
    @Published private(set) var afterWorkout: PostWorkoutRecovery.Result?
    @Published private(set) var afterWorkoutTrend: PostWorkoutRecovery.Trend?
    /// The GPS route captured on-device (#524); empty = none was recorded, so no map is drawn.
    @Published private(set) var route: [RouteMath.LatLng] = []
    @Published private(set) var steps: StepReadout?
    /// "Sessions like this usually..." from `ActivityCostEngine`, only once the sport has enough sessions.
    @Published private(set) var recoveryCost: String?
    /// The user's other sessions of this sport, newest first; the baseline for every "typical" range.
    @Published private(set) var sportHistory: [WorkoutRow] = []

    init(row: WorkoutRow) {
        self.row = row
    }

    func load(repo: Repository, profile: ProfileStore) async {
        // The route is a cheap read keyed by the row's natural key; it only counts with >= 2 points.
        let decoded = RouteStore.load(startTs: row.startTs, sport: row.sport).map { RouteMath.decode($0.polyline) } ?? []
        let routePoints = decoded.count >= 2 ? decoded : []

        // A finer bucket than the 24 h chart, so a short run still reads as a curve.
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        let (minutes, fromImport) = await zoneSplit(repo: repo, profile: profile)
        let after = await repo.postWorkoutRecovery(row: row, maxHR: Double(profile.hrMax))
        let stepReadout = await steps(repo: repo, profile: profile)

        let all = await repo.workoutRows()
        let sport = WorkoutSource.displaySport(row.sport)
        let history = all.filter { WorkoutSource.displaySport($0.sport) == sport && $0.startTs != row.startTs }
        let cost = TrainingActivityCost.sentence(forSport: row.sport, workouts: all, days: repo.days)

        guard !Task.isCancelled else { return }
        route = routePoints
        hrPoints = points
        zoneMinutes = minutes
        zonesFromImport = fromImport
        afterWorkout = after.result
        afterWorkoutTrend = after.trend
        steps = stepReadout
        sportHistory = history
        recoveryCost = cost
        loaded = true
    }

    /// Prefer the imported per-workout percentages (a WHOOP-computed split); only derive zone minutes from
    /// the strap's own heart rate when the row has none, so an imported split is never overwritten by an
    /// on-device approximation.
    private func zoneSplit(repo: Repository, profile: ProfileStore) async -> ([Double]?, Bool) {
        if let percents = WorkoutZones.percents(row.zonesJSON) {
            let minutes = (row.durationS ?? Double(row.endTs - row.startTs)) / 60
            if minutes > 0 { return (percents.map { minutes * $0 / 100 }, true) }
        }
        let derived = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: profile.hrZoneSet,
                                                    source: row.source)
        return (derived, false)
    }

    /// Computed at display time over the exact window, so it fills in after sync. Never for sports without
    /// footfalls, and "no data" stays nil rather than a fabricated 0.
    private func steps(repo: Repository, profile: ProfileStore) async -> StepReadout? {
        guard WorkoutCatalog.isOnFoot(row.sport) else { return nil }
        if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
            // The same per-user ticks-per-step calibration the daily total applies (#139), floor 0.5.
            let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
            if scaled > 0 { return StepReadout(count: scaled, fromStrap: true) }
        }
        if let phone = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), phone > 0 {
            return StepReadout(count: phone, fromStrap: false)
        }
        return nil
    }

    // MARK: Readouts

    func effortReadout(scale: EffortScale) -> MetricReadout {
        WorkoutReadouts.effort(strain: row.strain, others: sportHistory.compactMap(\.strain), scale: scale)
    }

    /// Method, data and trend behind the Effort readout, for the explainer sheet.
    func effortExplanation(scale: EffortScale) -> MetricExplanation {
        let month = Date().addingTimeInterval(-30 * 86_400)
        let trend = sportHistory
            .filter { Date(timeIntervalSince1970: TimeInterval($0.startTs)) >= month }
            .compactMap { r in r.strain.map {
                MetricExplanation.TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(r.startTs)),
                                             value: TrainingEffort.value($0, scale: scale))
            } }
            .sorted { $0.date < $1.date }
        return MetricExplanation(
            whatItIs: LocalizedStringResource("zoop.training.detail.effort.whatItIs",
                defaultValue: "Effort shows how hard a session was for your heart, from 0 to 100. More time at higher heart rates scores more.",
                bundle: .main),
            method: .init(
                name: LocalizedStringResource("zoop.training.detail.effort.method",
                    defaultValue: "Heart-rate load", bundle: .main),
                summary: LocalizedStringResource("zoop.training.detail.effort.methodSummary",
                    defaultValue: "Time in five heart-rate zones is weighted towards the hard zones and compressed logarithmically, so each extra point takes more work.",
                    bundle: .main),
                citation: "Edwards 1993; Banister 1991"),
            dataUsed: .init(count: .samples(hrPoints.count),
                            window: DateInterval(start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                                                 end: Date(timeIntervalSince1970: TimeInterval(max(row.endTs, row.startTs + 1))))),
            trend: trend)
    }

    func avgHeartRateReadout() -> MetricReadout? {
        WorkoutReadouts.heartRate(id: "workout_avg_hr", label: LocalizedStringResource("Avg HR"),
                                  value: row.avgHr, others: sportHistory.compactMap(\.avgHr))
    }

    func maxHeartRateReadout() -> MetricReadout? {
        WorkoutReadouts.heartRate(id: "workout_max_hr", label: LocalizedStringResource("Max HR"),
                                  value: row.maxHr, others: sportHistory.compactMap(\.maxHr))
    }
}
