import Foundation
import WhoopStore

// Turn an AI coach reply into a training-plan draft.
//
// Same contract shape as `LiftRoutineGenerator`: this file owns both the schema the model is told to
// follow and the validator for what comes back, so the two cannot drift. Pure — the caller sends the
// prompt, hands the reply here and shows the draft for review before anything is saved.

public struct TrainingPlanDraft: Equatable, Sendable {

    public enum Kind: String, Sendable, Equatable { case open, targetDate }

    public struct Session: Equatable, Sendable {
        /// `Calendar` weekday: 1 = Sunday … 7 = Saturday.
        public var weekday: Int
        public var title: String
        /// A catalogue sport name after resolution, or the model's text when nothing matched.
        public var sport: String
        public var minutes: Int
        /// "HH:mm", or nil.
        public var time: String?
        /// The exercises of a strength session, when the model gave any.
        public var program: ImportedProgram?
    }

    public var name: String
    public var focus: String?
    public var kind: Kind
    /// Local yyyy-MM-dd.
    public var startDay: String
    public var targetDay: String?
    public var summary: String?
    /// Monday-first order.
    public var sessions: [Session]
}

public enum TrainingPlanDraftParser {

    public enum ParseError: Error, Equatable { case noJSON, noSessions }

    static let maxSessions = 14
    static let maxPerDay = 2
    static let maxText = 80

    /// The system prompt: the JSON schema and the rules. `sports` is the catalogue to choose from.
    public static func systemPrompt(sports: [String]) -> String {
        let muscles = LiftMuscle.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You design weekly training plans. Reply with ONE JSON object and nothing else — no prose, no \
        markdown fences. Schema:
        {"name": string, "focus": string, "kind": "open" | "targetDate", "startDate": "YYYY-MM-DD", \
        "targetDate": "YYYY-MM-DD" or null, "summary": string, "sessions": [{"day": "Mon"|"Tue"|"Wed"|"Thu"|"Fri"|"Sat"|"Sun", \
        "title": string, "sport": string, "minutes": integer, "time": "HH:MM" or null, \
        "exercises": [{"name": string, "muscle": string, "sets": integer, "reps": integer, "restSec": integer}]}]}
        "sport" must be one of: \(sports.joined(separator: ", ")).
        Give "exercises" only for strength sessions; "muscle" must be one of: \(muscles).
        "focus" is 2–4 words like "Fitness, Mobility & Strength". "summary" is ONE short sentence.
        Only use the weekdays the user offered, respect their limitations and keep each session within \
        the time they gave. Short titles (max 3 words).
        """
    }

    /// Parse and validate. `today` (yyyy-MM-dd) bounds the start date; `resolveSport` maps a model's
    /// sport text onto the catalogue (nil keeps the text).
    public static func parse(_ reply: String, today: String,
                             resolveSport: (String) -> String? = { _ in nil }) throws -> TrainingPlanDraft {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.noJSON
        }

        var perDay: [Int: Int] = [:]
        var sessions: [TrainingPlanDraft.Session] = []
        for case let item as [String: Any] in (obj["sessions"] as? [Any]) ?? [] {
            guard sessions.count < maxSessions,
                  let weekday = weekday(item["day"] ?? item["weekday"]),
                  perDay[weekday, default: 0] < maxPerDay,
                  let title = text(item["title"] ?? item["name"]) else { continue }
            let sportText = text(item["sport"]) ?? title
            var program: ImportedProgram?
            if let exercises = item["exercises"] as? [Any], !exercises.isEmpty {
                program = try? LiftRoutineGenerator.program(from: ["name": title, "exercises": exercises])
            }
            sessions.append(.init(weekday: weekday, title: title,
                                  sport: resolveSport(sportText) ?? sportText,
                                  minutes: max(5, min(240, int(item["minutes"] ?? item["duration"]) ?? 45)),
                                  time: time(item["time"]), program: program))
            perDay[weekday, default: 0] += 1
        }
        guard !sessions.isEmpty else { throw ParseError.noSessions }
        sessions.sort { mondayFirst($0.weekday) < mondayFirst($1.weekday) }

        let startDay = day(obj["startDate"]).map { max($0, today) } ?? today
        var target = day(obj["targetDate"])
        if let t = target, t <= startDay { target = nil }
        let kindText = (obj["kind"] as? String)?.lowercased() ?? ""
        let kind: TrainingPlanDraft.Kind = target != nil && !kindText.hasPrefix("open") ? .targetDate : .open
        return TrainingPlanDraft(name: text(obj["name"]) ?? "Training plan",
                                 focus: text(obj["focus"]), kind: kind, startDay: startDay,
                                 targetDay: kind == .targetDate ? target : nil,
                                 summary: (obj["summary"] as? String).flatMap { s in
                                     let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                     return t.isEmpty ? nil : String(t.prefix(200))
                                 },
                                 sessions: sessions)
    }

    /// The draft as compact JSON, sent back with an edit request so the model changes the plan it made.
    public static func json(_ draft: TrainingPlanDraft) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var obj: [String: Any] = ["name": draft.name, "kind": draft.kind.rawValue, "startDate": draft.startDay]
        if let f = draft.focus { obj["focus"] = f }
        if let t = draft.targetDay { obj["targetDate"] = t }
        obj["sessions"] = draft.sessions.map { s -> [String: Any] in
            var row: [String: Any] = ["day": names[s.weekday - 1], "title": s.title, "sport": s.sport, "minutes": s.minutes]
            if let t = s.time { row["time"] = t }
            if let p = s.program {
                row["exercises"] = p.lines.map { l -> [String: Any] in
                    var e: [String: Any] = ["name": l.exercise]
                    if let m = l.primaryMuscle { e["muscle"] = m.rawValue }
                    if let v = l.targetSets { e["sets"] = v }
                    if let v = l.targetReps { e["reps"] = v }
                    if let v = l.restSec { e["restSec"] = v }
                    return e
                }
            }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Field coercion

    /// Monday = 0 … Sunday = 6, for sorting.
    public static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    /// A `Calendar` weekday from "Mon", "monday", "Mo", "Montag", or an ISO number (1 = Monday).
    static func weekday(_ value: Any?) -> Int? {
        if let n = value as? NSNumber {
            let iso = n.intValue
            return (1...7).contains(iso) ? iso % 7 + 1 : nil
        }
        guard let s = value as? String else { return nil }
        let key = s.lowercased().filter(\.isLetter)
        let table: [(Int, [String])] = [
            (2, ["mon", "mo", "montag", "monday"]), (3, ["tue", "di", "dienstag", "tuesday", "tu"]),
            (4, ["wed", "mi", "mittwoch", "wednesday", "we"]), (5, ["thu", "do", "donnerstag", "thursday", "th"]),
            (6, ["fri", "fr", "freitag", "friday"]), (7, ["sat", "sa", "samstag", "saturday"]),
            (1, ["sun", "so", "sonntag", "sunday", "su"])]
        if let match = table.first(where: { $0.1.contains(key) }) { return match.0 }
        if let match = table.first(where: { entry in entry.1.contains { key.hasPrefix($0) && $0.count >= 3 } }) {
            return match.0
        }
        if let iso = Int(s.trimmingCharacters(in: .whitespaces)), (1...7).contains(iso) { return iso % 7 + 1 }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(maxText))
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, n.doubleValue.isFinite { return Int(n.doubleValue.rounded()) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) }
        return nil
    }

    /// "7:30" / "07:30" / "18:00 Uhr" → "07:30" / "18:00"; anything else nil.
    static func time(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// A valid yyyy-MM-dd string, or nil.
    static func day(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), s.count >= 10 else { return nil }
        let head = String(s.prefix(10))
        let parts = head.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (2000...2100).contains(parts[0]), (1...12).contains(parts[1]),
              (1...31).contains(parts[2]) else { return nil }
        return head
    }
}
