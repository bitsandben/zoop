#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - The one fasting write path
//
// The screen, the quick action and the Shortcuts intents all start and stop fasts through `FastingLog`,
// so the reminders are (re)scheduled and the row shape is decided in exactly one place.

extension FastingInterval {
    init(_ row: FastingSessionRow) {
        self.init(id: row.id,
                  start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                  end: row.endTs.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                  goal: TimeInterval(row.goalSec))
    }
}

@MainActor
enum FastingLog {
    /// Posted after every write so other screens (Today's fasting card) reload. Shortcuts run in this
    /// process, so the same signal covers them.
    static let didChange = Notification.Name("zoop.fasting.didChange")

    private static func notifyChanged() { NotificationCenter.default.post(name: didChange, object: nil) }

    enum Source: String { case app, shortcut }

    /// How far back the screen reads. The 30-day consistency window plus room for the pattern split,
    /// which needs weeks of nights on both sides before it says anything.
    static let historyWindow: TimeInterval = 180 * 86_400

    static func load(store: WhoopStore, now: Date) async -> [FastingSessionRow] {
        let since = Int(now.addingTimeInterval(-historyWindow).timeIntervalSince1970)
        return (try? await store.fastingSessions(sinceTs: since)) ?? []
    }

    /// The cycle state for `rows` at `now` under the saved schedule. The one resolver Today, the screen,
    /// the reminders and the intents all read, so they can't disagree about which phase is on.
    static func state(_ rows: [FastingSessionRow], now: Date) -> FastingCycleState {
        FastingCycle.state(rows.map(FastingInterval.init), schedule: FastingPreferences.schedule,
                           now: now, calendar: .current)
    }

    /// Runs on every load: starts the due fast when "start automatically" is on (backdated to the
    /// planned start, once per window), then re-arms the reminders from the current state. Returns
    /// the rows as they are afterwards.
    static func reconcile(store: WhoopStore, now: Date) async -> [FastingSessionRow] {
        var rows = await load(store: store, now: now)
        if FastingPreferences.autoStart,
           let start = FastingCycle.autoStart(state(rows, now: now), lastAutoStart: FastingPreferences.lastAutoStart) {
            FastingPreferences.lastAutoStart = start
            if (try? await self.start(store: store, at: start, now: now, source: .app)) != nil {
                rows = await load(store: store, now: now)
            }
        }
        FastingReminder.sync(state: state(rows, now: now), now: now)
        return rows
    }

    /// Starts a fast at `start` with the current plan. Returns nil when one is already running or the
    /// start overlaps a logged fast.
    @discardableResult
    static func start(store: WhoopStore, at start: Date, now: Date, source: Source) async throws -> FastingSessionRow? {
        let existing = await load(store: store, now: now)
        guard !existing.contains(where: { $0.endTs == nil }) else { return nil }
        guard FastingEngine.validate(start: start, end: nil, now: now,
                                     others: existing.map(FastingInterval.init)) == .ok else { return nil }
        let plan = FastingPreferences.plan
        let row = FastingSessionRow(id: UUID().uuidString, startTs: Int(start.timeIntervalSince1970), endTs: nil,
                                    goalSec: Int(plan.goal), planId: plan.id, source: source.rawValue)
        try await store.saveFastingSession(row)
        // Using the timer once is the signal to keep the card on Today.
        FastingPreferences.showOnToday = true
        await afterWrite(store: store, now: now)
        return row
    }

    /// Ends the running fast at `end`, which opens the eating window. Returns the finished row, or nil
    /// when nothing was running.
    @discardableResult
    static func stop(store: WhoopStore, at end: Date) async throws -> FastingSessionRow? {
        guard var row = try await store.activeFastingSession() else { return nil }
        row.endTs = max(row.startTs + 1, Int(end.timeIntervalSince1970))
        try await store.saveFastingSession(row)
        await afterWrite(store: store, now: end)
        return row
    }

    /// Saves an edited (backdated) fast. The caller validated it with `FastingEngine.validate`.
    static func save(store: WhoopStore, _ row: FastingSessionRow) async throws {
        try await store.saveFastingSession(row)
        await afterWrite(store: store, now: Date())
    }

    /// Moves an eating window: the earlier fast now ends at `opens` (first meal) and the later one starts
    /// at `closes` (last meal). The caller validated it with `FastingCycle.validateWindow`.
    static func saveWindow(store: WhoopStore, previous: FastingSessionRow, next: FastingSessionRow,
                           opens: Date, closes: Date) async throws {
        var p = previous, n = next
        p.endTs = Int(opens.timeIntervalSince1970)
        n.startTs = Int(closes.timeIntervalSince1970)
        try await store.saveFastingSession(p)
        try await store.saveFastingSession(n)
        await afterWrite(store: store, now: Date())
    }

    static func delete(store: WhoopStore, _ row: FastingSessionRow) async throws {
        try await store.deleteFastingSession(id: row.id)
        await afterWrite(store: store, now: Date())
    }

    /// Re-arms the reminders from the new state and tells the other screens to reload.
    private static func afterWrite(store: WhoopStore, now: Date) async {
        let rows = await load(store: store, now: now)
        FastingReminder.sync(state: state(rows, now: now), now: now)
        notifyChanged()
    }
}
#endif
