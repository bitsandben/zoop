#if os(iOS)
import Foundation
import Observation
import StrandAnalytics
import WhoopStore

/// What Today's fasting card shows at one instant. Nothing at all for people who don't use fasting.
enum FastingTodayState: Equatable {
    case hidden
    case running(Running)
    case next(Next)

    struct Running: Equatable {
        let progress: Double
        /// "13h 20min"
        let elapsed: String
        /// "Goal at 12:30" or "Goal reached".
        let status: LocalizedStringResource
        let goalReached: Bool
    }

    struct Next: Equatable {
        /// "from 20:00", or "now" when the planned start has passed.
        let when: LocalizedStringResource
    }

    /// A fast counts as "using the feature" when one started in the last week.
    static let recentWindow: TimeInterval = 7 * 86_400

    static func make(rows: [FastingSessionRow], plan: FastingPlan, now: Date) -> FastingTodayState {
        let intervals = rows.map(FastingInterval.init)
        if let active = intervals.first(where: \.isActive) {
            let s = FastingEngine.status(of: active, now: now)
            return .running(Running(
                progress: s.progress,
                elapsed: FastingFormat.duration(s.elapsed),
                status: s.goalReached ? FastingTodayStrings.goalReached
                    : FastingTodayStrings.goalAt(FastingFormat.time(s.goalDate)),
                goalReached: s.goalReached))
        }
        let cutoff = now.addingTimeInterval(-recentWindow)
        guard intervals.contains(where: { $0.start >= cutoff }),
              let lastEnd = intervals.compactMap(\.end).max() else { return .hidden }
        let planned = lastEnd.addingTimeInterval(plan.eatingHours * 3600)
        return .next(Next(when: planned > now ? FastingTodayStrings.plannedAt(FastingFormat.time(planned))
                                              : FastingTodayStrings.startNow))
    }
}

/// Loads the fasting log for Today's card and starts / stops through `FastingLog`, the same write path
/// as the Fasting screen and the Shortcuts intents. The card reloads on `FastingLog.didChange`.
@Observable @MainActor
final class FastingTodayModel {
    private(set) var rows: [FastingSessionRow] = []
    private var repo: Repository?

    var now: () -> Date = Date.init

    func load(repo: Repository) async {
        self.repo = repo
        guard let store = await repo.storeHandle() else { return }
        rows = await FastingLog.load(store: store, now: now())
    }

    /// The card at `date`; the card's TimelineView supplies the tick.
    func state(at date: Date) -> FastingTodayState {
        .make(rows: rows, plan: FastingPreferences.plan, now: date)
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
    static let nextTitle = r("zoop.today.fasting.next", "Next fast")
    static func plannedAt(_ time: String) -> LocalizedStringResource { r("zoop.today.fasting.plannedAt", "from \(time)") }
    static let startNow = r("zoop.today.fasting.now", "now")
}
#endif
