#if os(iOS)
import Foundation
import Observation
import StrandAnalytics
import WhoopStore

/// Loads the fasting log for Today's card and starts / ends fasts through `FastingLog`, the same write
/// path as the Fasting screen and the Shortcuts intents. The card reloads on `FastingLog.didChange`.
/// Loading reconciles (automatic start, reminders), so opening the app keeps the cycle current.
@Observable @MainActor
final class FastingTodayModel {
    private(set) var rows: [FastingSessionRow] = []
    private var repo: Repository?

    var now: () -> Date = Date.init

    func load(repo: Repository) async {
        self.repo = repo
        guard let store = await repo.storeHandle() else { return }
        rows = await FastingLog.reconcile(store: store, now: now())
    }

    /// Reload after another screen wrote; no reconcile (the writer already did).
    func reload() async {
        guard let store = await repo?.storeHandle() else { return }
        rows = await FastingLog.load(store: store, now: now())
    }

    /// The card at `date`; the card's TimelineView supplies the tick.
    func state(at date: Date) -> FastingTodayState {
        .make(rows: rows, state: FastingLog.state(rows, now: date),
              showOnToday: FastingPreferences.showOnToday, now: date)
    }

    func start() async { await write { store, t in _ = try await FastingLog.start(store: store, at: t, now: t, source: .app) } }
    func stop() async { await write { store, t in _ = try await FastingLog.stop(store: store, at: t) } }

    private func write(_ body: (WhoopStore, Date) async throws -> Void) async {
        guard let repo, let store = await repo.storeHandle() else { return }
        try? await body(store, now())
        rows = await FastingLog.load(store: store, now: now())
    }
}

enum FastingTodayStrings {
    private static func r(_ key: StaticString, _ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: value)
    }
    static func goalAt(_ time: String) -> LocalizedStringResource { r("zoop.today.fasting.goalAt", "Goal at \(time)") }
    static let goalReached = r("zoop.today.fasting.goalReached", "Goal reached")
    static func plannedAt(_ time: String) -> LocalizedStringResource { r("zoop.today.fasting.nextAt", "Next fast at \(time)") }
    static func fastingCaption(_ phase: String) -> LocalizedStringResource {
        r("zoop.today.fasting.caption", "Fasting · \(phase)")
    }
    static let eatingCaption = r("zoop.today.fasting.eatingCaption", "Eating window")
    static func closesIn(_ left: String) -> LocalizedStringResource { r("zoop.today.fasting.closesIn", "Closes in \(left)") }
    static func closedCaption(_ time: String) -> LocalizedStringResource {
        r("zoop.today.fasting.closedCaption", "Eating window closed at \(time)")
    }
    static let idleCaption = r("zoop.today.fasting.idleCaption", "Fasting")
}
#endif
