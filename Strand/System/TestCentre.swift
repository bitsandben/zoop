import Foundation
import StrandAnalytics

/// Test Centre orchestration: per-domain activation, a single consolidated prefs namespace, and a
/// one-time read-through migration over the scattered legacy keys (not renamed). `active(_:)` is the
/// zero-cost gate engines check before emitting a tagged line.
public enum TestCentre {

    // Single namespace for all new Test Centre flags; migrated legacy keys keep their original names.
    private static let activePrefix = "testcentre.active."          // + domain.id  -> Bool
    private static let startedPrefix = "testcentre.startedAt."      // + domain.id  -> Double (unix)
    private static let guidedTargetPrefix = "testcentre.target."    // + domain.id  -> Int (nights/days)
    private static let answersPrefix = "testcentre.answers."        // + domain.id  -> [String:String] (Data)
    private static let migratedKey = "testcentre.migrated.v1"

    private static let master = TestDomain.master

    /// The zero-cost gate: `if TestCentre.active(.sleep) { live.append(log:domain:) }`. `nonisolated`
    /// plus one Bool read so any actor pays almost nothing when the mode is off.
    public nonisolated static func active(_ d: TestDomain) -> Bool {
        if d == .universal { return anyActive }      // universal rides whatever mode is on
        if UserDefaults.standard.bool(forKey: activePrefix + master.id) { return true }  // master = all on
        return UserDefaults.standard.bool(forKey: activePrefix + d.id)
    }

    /// True when any non-universal mode is on (drives the "testing on" banner and universal traces).
    public nonisolated static var anyActive: Bool {
        TestDomain.allCases.contains {
            $0 != .universal && UserDefaults.standard.bool(forKey: activePrefix + $0.id)
        }
    }

    @MainActor public static func activate(_ d: TestDomain) {
        UserDefaults.standard.set(true, forKey: activePrefix + d.id)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: startedPrefix + d.id)
    }

    @MainActor public static func deactivate(_ d: TestDomain) {
        UserDefaults.standard.set(false, forKey: activePrefix + d.id)
    }

    public static func startedAt(_ d: TestDomain) -> Date? {
        let t = UserDefaults.standard.double(forKey: startedPrefix + d.id)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The guided capture target (nights for Sleep, days for Battery), 0 when unset.
    public static func guidedTarget(_ d: TestDomain) -> Int {
        UserDefaults.standard.integer(forKey: guidedTargetPrefix + d.id)
    }

    @MainActor public static func setGuidedTarget(_ count: Int, for d: TestDomain) {
        UserDefaults.standard.set(count, forKey: guidedTargetPrefix + d.id)
    }

    public static func answers(_ d: TestDomain) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: answersPrefix + d.id),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    @MainActor public static func setAnswers(_ m: [String: String], for d: TestDomain) {
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: answersPrefix + d.id)
        }
    }

    // MARK: - All-time drained-rows tally

    /// Key for the all-time drained (persisted) row counter. It accrues unconditionally (not test-mode
    /// gated), so it answers "has this install ever drained anything" even though the per-session
    /// counter resets on every reconnect.
    private static let cumulativeDrainedKey = "testcentre.cumulativeDrainedRows"

    /// Folds one session's drained rows into the all-time tally; called from the LiveState log sink when
    /// the Backfiller's "session persisted N rows" summary lands. `nonisolated`.
    public nonisolated static func noteDrainedRows(_ rows: Int) {
        guard rows > 0 else { return }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: cumulativeDrainedKey) + rows, forKey: cumulativeDrainedKey)
    }

    /// The all-time drained-rows tally (0 before anything drained); shown beside the per-session count.
    public nonisolated static func cumulativeDrainedRows() -> Int {
        UserDefaults.standard.integer(forKey: cumulativeDrainedKey)
    }

    /// One-time migration: gathers the scattered @AppStorage / PuffinExperiment / ScheduledDebugExport
    /// keys behind this surface without renaming or deleting them. Idempotent via `migratedKey`.
    @MainActor public static func migrate() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        // Nothing to seed from the legacy toggles (they aren't domain activations), so this only stamps the
        // guard. Legacy keys are read in place (PuffinExperiment.*Key, ScheduledDebugExport "debugExport.*").
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
