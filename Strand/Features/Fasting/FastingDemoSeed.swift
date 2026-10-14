#if os(iOS) && DEBUG
import Foundation
import WhoopStore

/// DEBUG-only: under `--demo-seed`, give the Fasting screen five weeks of synthetic 16:8 history and a
/// fast 13:20 into its goal, so every card renders in screenshots. Runs only when the log is
/// empty and never in Release (the AppleDemoSeeder contract).
enum FastingDemoSeed {
    static func seedIfRequested(store: WhoopStore, now: Date) async {
        guard AppleDemoSeeder.requested,
              (try? await store.fastingSessions(sinceTs: 0))?.isEmpty ?? false else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for back in 1...35 {
            // Fixed pattern, not random: skip every third day, end one in five early.
            guard back % 3 != 0, let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let start = day.addingTimeInterval(-(3 * 3600 + Double(back % 4) * 900))   // ~20:15–21:00
            let hours = back % 5 == 0 ? 13.5 : 16.0 + Double(back % 3) * 0.5
            try? await store.saveFastingSession(FastingSessionRow(
                id: "demo-\(back)", startTs: Int(start.timeIntervalSince1970),
                endTs: Int(start.addingTimeInterval(hours * 3600).timeIntervalSince1970),
                goalSec: 16 * 3600, planId: "16:8", source: "app"))
        }
        let running = now.addingTimeInterval(-(13 * 3600 + 20 * 60))   // 13:20 into a 16 h goal
        try? await store.saveFastingSession(FastingSessionRow(
            id: "demo-running", startTs: Int(running.timeIntervalSince1970), endTs: nil,
            goalSec: 16 * 3600, planId: "16:8", source: "app"))
    }
}
#endif
