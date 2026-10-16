#if DEBUG
import Foundation
import StrandAnalytics

/// DEBUG only: a scripted provider for screenshots and UI checks without an API key. Enabled with the
/// launch argument `-zoopPlanChatDemo`; release builds do not contain it.
enum PlanChatDemo {

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-zoopPlanChatDemo") }

    /// `-zoopPlanChatOpen plan|routine|training`: start on the Training tab and, for plan / routine,
    /// open that builder right away.
    static var openTarget: String? { UserDefaults.standard.string(forKey: "zoopPlanChatOpen") }
    static var opensTraining: Bool { isEnabled && openTarget != nil }

    /// `-zoopPlanChatAnswers N`: send the first N scripted answers by themselves (screenshots without taps).
    static var autoAnswers: Int { UserDefaults.standard.integer(forKey: "zoopPlanChatAnswers") }
    /// `-zoopPlanChatAccept YES`: accept the draft once it is there.
    static var autoAccept: Bool { UserDefaults.standard.bool(forKey: "zoopPlanChatAccept") }

    /// `-zoopPlanChatSeedUpdate YES`: put a sample weekly update on the current plan.
    @MainActor static func seedUpdateIfRequested() {
        guard isEnabled, UserDefaults.standard.bool(forKey: "zoopPlanChatSeedUpdate"),
              let sessions = TrainingPlanStore.plan.sessions, sessions.count >= 3 else { return }
        let ordered = sessions.sorted { ($0.weekday + 5) % 7 < ($1.weekday + 5) % 7 }
        let strength = ordered.first { $0.programId != nil } ?? ordered[0]
        let other = ordered.first { $0.programId == nil && $0.id != strength.id } ?? ordered[1]
        let third = ordered.last { $0.programId != nil && $0.id != strength.id } ?? ordered[2]
        let items: [PlanWeeklyReview.Item] = [
            .init(change: .move(sessionId: third.id, from: third.weekday, to: 4), reason: .missedTwice),
            .init(change: .shorten(sessionId: other.id, from: other.minutes, to: max(15, other.minutes - 10)),
                  reason: .lowRecovery(days: 4)),
            .init(change: .addSet(sessionId: strength.id, programId: strength.programId ?? ""), reason: .steady(weeks: 3)),
        ]
        TrainingPlanStore.pending = .init(revision: .init(weekKey: PlanReviewRunner.weekKey(for: Date()), items: items),
                                          applied: false)
    }

    static func answers(_ kind: PlanInterview.Kind) -> [String] {
        let de = CoachLanguage.code == "de"
        switch kind {
        case .plan:
            return de ? ["Fitness, Mobility & Kraft", "Offen", "4 Tage: Mo., Mi., Fr., So.", "45 Min. zu Hause mit Bändern",
                         "Abends", "Einsteiger", "Keine"]
                      : ["Fitness, mobility & strength", "Open-ended", "4 days: Mon, Wed, Fri, Sun", "45 min at home with bands",
                         "Evenings", "Beginner", "None"]
        case .routine:
            return de ? ["Oberkörper", "Klimmzugstange und Bänder", "30 Min.", "Einsteiger"]
                      : ["Upper body", "Pull-up bar and bands", "30 min", "Beginner"]
        }
    }

    static let transport: PlanChatModel.Transport = { system, messages in
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let german = CoachLanguage.code == "de"
        if system.contains("weekly training plans") { return reply(plan(german: german), seconds: 9) }
        if system.contains("strength-training routines") { return reply(routine(german: german), seconds: 6) }
        return reply(german ? "Alles klar." : "Alright.", seconds: 2)
    }

    private static func reply(_ text: String, seconds: Double) -> CoachTurnReply {
        CoachTurnReply(text: text, reasoning: "Scripted demo reply.", seconds: seconds)
    }

    private static func plan(german: Bool) -> String {
        let start = TrainingPlan.dayKey(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        let a = german ? "Kraft A" : "Strength A", b = german ? "Kraft B" : "Strength B"
        let swim = german ? "Schwimmen" : "Swim", mob = german ? "Mobility" : "Mobility"
        let ex = german
            ? #"[{"name":"Kniebeuge","muscle":"quads","sets":3,"reps":10,"restSec":90},{"name":"Liegestütze","muscle":"chest","sets":3,"reps":10,"restSec":75},{"name":"Rudern mit Band","muscle":"upperBack","sets":3,"reps":12,"restSec":60}]"#
            : #"[{"name":"Squat","muscle":"quads","sets":3,"reps":10,"restSec":90},{"name":"Push-up","muscle":"chest","sets":3,"reps":10,"restSec":75},{"name":"Band row","muscle":"upperBack","sets":3,"reps":12,"restSec":60}]"#
        let summary = german ? "Zwei Krafteinheiten plus lockeres Schwimmen und Mobility, gut machbar neben deinen Spaziergängen."
                             : "Two strength sessions plus easy swimming and mobility, easy to fit around your walks."
        let name = german ? "Offener Plan" : "Open plan"
        let focus = german ? "Fitness, Mobility & Kraft" : "Fitness, Mobility & Strength"
        return """
        {"name":"\(name)","focus":"\(focus)","kind":"open","startDate":"\(start)","summary":"\(summary)",
         "sessions":[{"day":"Mon","title":"\(a)","sport":"Strength","minutes":40,"time":"18:00","exercises":\(ex)},
          {"day":"Wed","title":"\(swim)","sport":"Pool swim","minutes":30,"time":"07:00"},
          {"day":"Fri","title":"\(b)","sport":"Strength","minutes":40,"time":"18:00","exercises":\(ex)},
          {"day":"Sun","title":"\(mob)","sport":"Yoga","minutes":20,"time":"09:00"}]}
        """
    }

    private static func routine(german: Bool) -> String {
        german
            ? #"{"name":"Oberkörper mit Band","note":"Langsam ablassen.","exercises":[{"name":"Klimmzüge","muscle":"lats","sets":3,"reps":6,"restSec":120},{"name":"Liegestütze","muscle":"chest","sets":3,"reps":12,"restSec":90},{"name":"Band-Rudern","muscle":"upperBack","sets":3,"reps":15,"restSec":60},{"name":"Band-Seitheben","muscle":"sideDelts","sets":2,"reps":15,"restSec":60}]}"#
            : #"{"name":"Upper body with bands","note":"Lower slowly.","exercises":[{"name":"Pull-up","muscle":"lats","sets":3,"reps":6,"restSec":120},{"name":"Push-up","muscle":"chest","sets":3,"reps":12,"restSec":90},{"name":"Band row","muscle":"upperBack","sets":3,"reps":15,"restSec":60},{"name":"Band lateral raise","muscle":"sideDelts","sets":2,"reps":15,"restSec":60}]}"#
    }
}
#endif
