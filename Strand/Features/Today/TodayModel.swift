#if os(iOS)
import Foundation
import Observation
import StrandAnalytics
import StrandDesign

/// What a Today load needs from the app, passed in so the model holds no environment of its own.
struct TodayEnvironment {
    let repo: Repository
    let profile: ProfileStore
    /// The user's Effort scale is WHOOP's 0–21 rather than Zoop's 0–100.
    let whoopScale: Bool
    let temperatureUnit: TemperatureUnit
    let dayCycleMode: DayCycleMode
    /// The tiles of My Dashboard, in the user's order.
    let dashboardTiles: [TodayTileKind]
}

/// The Today screen's state and intents. One `load` per data or day change resolves everything the screen
/// shows and writes it once; the views hold no logic of their own.
@Observable @MainActor
final class TodayModel {
    private(set) var content: TodayContent?
    /// Days back from today (0 = today).
    private(set) var dayOffset = 0
    private(set) var maxDayOffset = 0
    private(set) var explanationInputs = TodayExplanations.Inputs()

    /// Today's hourly stress, kept between loads so the live refresh can re-pick the moment card.
    @ObservationIgnored var stressHours: [DaytimeStress.HourPoint] = []

    // MARK: Day navigation

    func step(_ delta: Int) {
        select(TodayLogic.clampedDayOffset(current: dayOffset, delta: delta, maxOffset: maxDayOffset))
    }

    func select(_ offset: Int) {
        let next = min(max(0, offset), maxDayOffset)
        guard next != dayOffset else { return }
        dayOffset = next
    }

    /// A return from the background lands on today again.
    func returnToToday() { select(0) }

    /// The logical day an offset resolves to (rolls at 04:00).
    static func logicalDay(offset: Int, now: Date = Date()) -> Date {
        let base = Repository.logicalDay(now)
        return Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
    }

    // MARK: Explainers

    func explanation(for readout: MetricReadout) -> MetricExplanation {
        TodayExplanations.explanation(for: readout.id, inputs: explanationInputs)
    }

    // MARK: Check-in intents

    func acceptCheckInInvite() {
        UserDefaults.standard.set(true, forKey: RecoveryCalibrationStore.enabledKey)
        content?.checkIn = .hidden
    }

    func dismissCheckInInvite() {
        UserDefaults.standard.set(true, forKey: RecoveryCalibrationStore.inviteDismissedKey)
        content?.checkIn = .hidden
    }

    /// A saved or dismissed detected workout leaves the list straight away; the next load confirms it.
    func removeDetectedWorkout() {
        content?.activities.removeAll { $0.kind == .detected }
    }

    // MARK: Load

    /// Resolves the selected day and writes it in one assignment. A load that finishes after the user
    /// moved to another day is dropped, so a slow read can never paint the wrong day.
    func load(_ env: TodayEnvironment, now: Date = Date()) async {
        let offset = dayOffset
        maxDayOffset = TodayLogic.maxDayOffset(earliestDayKey: env.repo.freshness.earliestDay,
                                               todayKey: Repository.logicalDayKey(now))
        let loaded = await TodayLoader(env: env, offset: offset, now: now).load()
        guard offset == dayOffset, !Task.isCancelled else { return }
        stressHours = loaded.stressHours
        explanationInputs = loaded.explanations
        content = loaded.content
    }

    /// Re-reads the parts of today that move while the screen is open: the stress tile, the moment card
    /// and the Energy Bank. Today only; a past day does not change.
    func refreshLive(_ env: TodayEnvironment, now: Date = Date()) async {
        guard dayOffset == 0, var updated = content, updated.isToday else { return }
        let loader = TodayLoader(env: env, offset: 0, now: now)
        let live = await loader.liveParts()
        guard dayOffset == 0, !Task.isCancelled else { return }
        updated.stress = live.stress
        updated.energy = live.energy
        updated.moment = live.moment
        updated.dashboard = TodayDashboardPrefs.replacingEnergyTile(updated.dashboard, with: live.energy)
        stressHours = live.stressHours
        content = updated
    }
}
#endif
