import Foundation
import StrandAnalytics
import StrandDesign
import UserNotifications
import WhoopStore

/// The weekly plan review: once per week (on Sunday evening for the coming week, otherwise on the
/// first open of a week) the plan is checked against last weeks and the body's signals, and
/// `PlanWeeklyReview` proposes changes. With "Plan automatisch anpassen" on they are applied (undoable)
/// and announced; otherwise they wait as the "Plan-Update" card. Entirely on-device.
@MainActor
enum PlanReviewRunner {

    /// Monday-first week start of `date`, as yyyy-MM-dd.
    static func weekKey(for date: Date) -> String {
        TrainingPlan.dayKey(weekStart(date))
    }

    static func weekStart(_ date: Date) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    /// The week a review run now would be for: next week from Sunday 18:00, else this week.
    static func targetWeek(now: Date) -> Date {
        let cal = Calendar.current
        let start = weekStart(now)
        if cal.component(.weekday, from: now) == 1, cal.component(.hour, from: now) >= 18 {
            return cal.date(byAdding: .day, value: 7, to: start) ?? start
        }
        return start
    }

    static func runIfDue(repo: Repository, now: Date = Date()) async {
        let plan = TrainingPlanStore.plan
        guard let sessions = plan.sessions, !sessions.isEmpty, let meta = plan.meta else { return }
        let target = targetWeek(now: now)
        let key = TrainingPlan.dayKey(target)
        let defaults = UserDefaults.standard
        if let done = defaults.string(forKey: TrainingPlanStore.reviewedWeekKey), done >= key { return }
        defaults.set(key, forKey: TrainingPlanStore.reviewedWeekKey)

        guard let startDate = PlanFormat.date(meta.startDay), startDate < target else { return }
        let signals = await signals(sessions: sessions, planStart: startDate, target: target, repo: repo, now: now)
        guard let revision = PlanWeeklyReview.review(sessions: sessions, signals: signals, weekKey: key) else { return }

        if defaults.bool(forKey: TrainingPlanStore.autoAdaptKey) {
            await TrainingPlanStore.apply(revision.items, label: PlanFormat.t("zoop.plan.history.update"), repo: repo)
            TrainingPlanStore.pending = .init(revision: revision, applied: true)
            notify(revision, sessions: sessions)
        } else {
            TrainingPlanStore.pending = .init(revision: revision, applied: false)
        }
    }

    // MARK: Signals

    static func signals(sessions: [PlanSession], planStart: Date, target: Date, repo: Repository,
                        now: Date) async -> PlanWeeklyReview.Signals {
        let cal = Calendar.current
        let rows = await repo.workoutRows(days: 35)
        let nowTs = Int(now.timeIntervalSince1970)
        let store = await repo.storeHandle()
        let lifts = (try? await store?.liftSessions(deviceId: repo.deviceId, fromTs: nowTs - 35 * 86_400, toTs: nowTs)) ?? []

        func day(_ ts: Int) -> Date { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))) }
        let workoutDays = rows.map { (day: day($0.startTs), family: family($0.sport)) }
        let liftDays = lifts.map { (day: day($0.startTs), programId: $0.programId, rpe: $0.sessionRpe) }

        var adherence: [String: [Bool]] = [:]
        var rpe: [String: Double] = [:]
        for weeksBack in (1...3).reversed() {
            // Days before the plan began or not yet past are skipped below, so they never count as missed.
            guard let weekStart = cal.date(byAdding: .day, value: -7 * weeksBack, to: target) else { continue }
            for s in sessions {
                guard let date = cal.date(byAdding: .day, value: (s.weekday + 5) % 7, to: weekStart),
                      date >= cal.startOfDay(for: planStart), date < cal.startOfDay(for: now) else { continue }
                let near = { (d: Date) in abs(d.timeIntervalSince(date)) <= 86_400 * 1.5 }
                let lift = liftDays.first { near($0.day) && $0.programId != nil && $0.programId == s.programId }
                let done = lift != nil || workoutDays.contains { near($0.day) && $0.family == family(s.sport) }
                adherence[s.id, default: []].append(done)
                if weeksBack == 1, let r = lift?.rpe { rpe[s.id] = r }
            }
        }

        var active: [Int: Int] = [:]
        for row in rows where row.startTs >= nowTs - 28 * 86_400 {
            active[cal.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(row.startTs))), default: 0] += 1
        }

        let days = repo.days
        let recovery = days.suffix(7).compactMap(\.recovery)
        let hrv = days.compactMap(\.avgHrv)
        let baseline = median(Array(hrv.dropLast(7).suffix(30)))
        var streak = 0
        if let baseline {
            for value in days.reversed().map(\.avgHrv) {
                guard let v = value, v < baseline * 0.95 else { break }
                streak += 1
            }
        }
        let gauge = TrainingLoadGauge.cardio(TrainingLoadEngine.evaluate(days: days.map {
            TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain)
        }))
        let load: PlanWeeklyReview.LoadState = switch gauge.state {
        case .calibrating: .unknown
        case .low: .low
        case .optimal: .optimal
        case .high: .high
        }
        let weeks = max(0, (cal.dateComponents([.day], from: planStart, to: target).day ?? 0) / 7)
        return .init(adherence: adherence, activeWeekdays: active, recentRecovery: recovery,
                     hrvBelowBaselineStreak: streak, load: load, sessionRpe: rpe, weeksActive: weeks)
    }

    /// Sports that count as the same planned session (a run for a run, any lifting for strength).
    static func family(_ sport: String) -> String {
        guard let type = KnownWorkoutType.resolving(sport) else { return sport.lowercased() }
        switch type {
        case .strength, .bodybuilding, .weightlifting, .crossfit, .calisthenics: return "strength"
        case .running, .treadmillRun: return "run"
        case .walking, .nordicWalking, .hiking, .treadmillWalk: return "walk"
        case .cycling, .indoorCycle: return "ride"
        case .poolSwim, .openWaterSwim: return "swim"
        case .yoga, .pilates, .stretching: return "mobility"
        default: return type.rawValue.lowercased()
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 0 ? (s[s.count / 2 - 1] + s[s.count / 2]) / 2 : s[s.count / 2]
    }

    private static func notify(_ revision: PlanWeeklyReview.Revision, sessions: [PlanSession]) {
        let title = PlanFormat.t("zoop.plan.update.pushTitle")
        let body = revision.items.prefix(2).map { PlanFormat.sentence($0, sessions: sessions) }.joined(separator: "\n")
        NotificationWork.withSettings { center, settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "zoop.plan.update", content: content, trigger: nil))
        }
    }
}
