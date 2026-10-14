#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Fasting preferences and the one write path
//
// The screen, the quick action and the Shortcuts intents all start and stop fasts through `FastingLog`,
// so the reminder is (re)scheduled and the row shape is decided in exactly one place.

/// The chosen plan and the goal reminder (`zoop.fasting.*`).
enum FastingPreferences {
    private static let planKey = "zoop.fasting.planId"
    private static let customHoursKey = "zoop.fasting.customHours"
    private static let reminderKey = "zoop.fasting.goalReminder"

    static var plan: FastingPlan {
        let d = UserDefaults.standard
        let hours = d.object(forKey: customHoursKey) as? Int ?? Int(FastingPlan.defaultPlan.fastingHours)
        return FastingPlan.resolve(id: d.string(forKey: planKey) ?? FastingPlan.defaultPlan.id, customHours: hours)
    }

    static func setPlan(_ plan: FastingPlan) {
        UserDefaults.standard.set(plan.id, forKey: planKey)
        if plan.isCustom { UserDefaults.standard.set(Int(plan.fastingHours), forKey: customHoursKey) }
    }

    /// Opt-in, like every other Zoop reminder.
    static var reminderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: reminderKey) }
        set { UserDefaults.standard.set(newValue, forKey: reminderKey) }
    }
}

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
    enum Source: String { case app, shortcut }

    /// How far back the screen reads. The 30-day consistency window plus room for the pattern split,
    /// which needs weeks of nights on both sides before it says anything.
    static let historyWindow: TimeInterval = 180 * 86_400

    static func load(store: WhoopStore, now: Date) async -> [FastingSessionRow] {
        let since = Int(now.addingTimeInterval(-historyWindow).timeIntervalSince1970)
        return (try? await store.fastingSessions(sinceTs: since)) ?? []
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
        FastingReminder.sync(active: row)
        return row
    }

    /// Ends the running fast at `end`. Returns the finished row, or nil when nothing was running.
    @discardableResult
    static func stop(store: WhoopStore, at end: Date) async throws -> FastingSessionRow? {
        guard var row = try await store.activeFastingSession() else { return nil }
        row.endTs = max(row.startTs + 1, Int(end.timeIntervalSince1970))
        try await store.saveFastingSession(row)
        FastingReminder.sync(active: nil)
        return row
    }

    /// Saves an edited (backdated) fast. The caller validated it with `FastingEngine.validate`.
    static func save(store: WhoopStore, _ row: FastingSessionRow) async throws {
        try await store.saveFastingSession(row)
        if row.endTs == nil {
            FastingReminder.sync(active: row)
        } else if (try? await store.activeFastingSession()) == nil {
            FastingReminder.sync(active: nil)
        }
    }

    static func delete(store: WhoopStore, _ row: FastingSessionRow) async throws {
        try await store.deleteFastingSession(id: row.id)
        if row.endTs == nil { FastingReminder.sync(active: nil) }
    }
}
#endif
