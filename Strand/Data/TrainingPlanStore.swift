import Foundation
import StrandAnalytics
import WhoopStore

/// Reads and writes the training plan with an undo history, plus the weekly-review state.
///
/// Everything goes through UserDefaults under the plan's `@AppStorage` key, so every reader updates the
/// moment a change lands. Each change pushes the plan it replaced onto a short history, together with
/// the program set bumps it made, so the latest change can be undone exactly.
@MainActor
enum TrainingPlanStore {

    struct Version: Codable, Equatable {
        var savedAt: TimeInterval
        /// What the change was, shown in the history ("Plan übernommen", "Plan-Update").
        var label: String
        /// The plan as it was BEFORE the change.
        var previousRaw: String
        /// Programs that got one more set on every line with this change.
        var setBumps: [String]
    }

    /// A weekly revision waiting for the user, or applied automatically and still undoable.
    struct PendingUpdate: Codable, Equatable {
        var revision: PlanWeeklyReview.Revision
        /// True once applied automatically: the card then offers undo instead of accept / decline.
        var applied: Bool
    }

    static let historyKey = "zoop.trainingPlan.history.v1"
    static let pendingKey = "zoop.trainingPlan.pendingUpdate.v1"
    static let reviewedWeekKey = "zoop.trainingPlan.reviewedWeek"
    /// "Plan automatisch anpassen": off proposes, on applies and notifies.
    static let autoAdaptKey = "zoop.trainingPlan.autoAdapt"
    static let maxHistory = 12

    private static var defaults: UserDefaults { .standard }

    static var plan: TrainingPlan {
        TrainingPlan.decode(defaults.string(forKey: TrainingPlan.storageKey) ?? "")
    }

    static var history: [Version] {
        guard let data = defaults.data(forKey: historyKey),
              let list = try? JSONDecoder().decode([Version].self, from: data) else { return [] }
        return list
    }

    /// Replaces the plan, remembering the one it replaced.
    static func save(_ new: TrainingPlan, label: String, setBumps: [String] = []) {
        var list = history
        list.append(Version(savedAt: Date().timeIntervalSince1970, label: label,
                            previousRaw: defaults.string(forKey: TrainingPlan.storageKey) ?? "",
                            setBumps: setBumps))
        if let data = try? JSONEncoder().encode(Array(list.suffix(maxHistory))) {
            defaults.set(data, forKey: historyKey)
        }
        defaults.set(new.encoded(), forKey: TrainingPlan.storageKey)
    }

    /// Restores the plan before the latest change and takes back its set bumps.
    @discardableResult
    static func undoLast(repo: Repository) async -> Version? {
        var list = history
        guard let last = list.popLast() else { return nil }
        defaults.set(last.previousRaw, forKey: TrainingPlan.storageKey)
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: historyKey) }
        for programId in last.setBumps { await bumpSets(programId: programId, by: -1, repo: repo) }
        if pending?.applied == true { pending = nil }
        return last
    }

    static var pending: PendingUpdate? {
        get {
            guard let data = defaults.data(forKey: pendingKey) else { return nil }
            return try? JSONDecoder().decode(PendingUpdate.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: pendingKey)
            } else {
                defaults.removeObject(forKey: pendingKey)
            }
            NotificationCenter.default.post(name: pendingChanged, object: nil)
        }
    }

    static let pendingChanged = Notification.Name("zoop.trainingPlan.pendingChanged")

    /// Applies the chosen items of a revision: schedule changes to the plan, set bumps to programs.
    static func apply(_ items: [PlanWeeklyReview.Item], label: String, repo: Repository) async {
        var next = plan
        next.sessions = PlanWeeklyReview.apply(items, to: next.sessions ?? [])
        next.syncProgramWeekdays()
        var bumps: [String] = []
        for item in items {
            if case .addSet(_, let programId) = item.change {
                await bumpSets(programId: programId, by: 1, repo: repo)
                bumps.append(programId)
            }
        }
        save(next, label: label, setBumps: bumps)
    }

    /// One set more (or fewer) on every line of a program, kept between 1 and 8.
    static func bumpSets(programId: String, by delta: Int, repo: Repository) async {
        guard let store = await repo.storeHandle(),
              let items = try? await store.liftProgramItems(programId: programId), !items.isEmpty else { return }
        let changed = items.map { item -> LiftProgramItemRow in
            var row = item
            row.targetSets = max(1, min(8, (item.targetSets ?? 3) + delta))
            return row
        }
        _ = try? await store.replaceLiftProgramItems(programId: programId, items: changed)
    }
}
