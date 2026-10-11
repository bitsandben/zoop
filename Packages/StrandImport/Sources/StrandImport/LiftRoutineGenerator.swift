import Foundation
import WhoopStore

// Turn an AI coach reply into a Lift Log program draft.
//
// The app asks the user's own configured coach provider for a routine as strict JSON. This file owns
// both halves of that contract — the instruction the model receives and the parser for what comes
// back — so the two cannot drift apart. It is pure: no network, no store. The caller sends the
// prompt, hands the reply text here, and shows the resulting `ImportedProgram` for review before
// anything is saved.

public enum LiftRoutineGenerator {

    public enum ParseError: Error, Equatable {
        /// No JSON object could be found in the reply.
        case noJSON
        /// JSON was found but it carried no usable exercise.
        case noExercises
    }

    /// What the user asked for. Every field is free text except the session length.
    public struct Request: Sendable, Equatable {
        public var goal: String
        public var equipment: String
        public var minutes: Int
        public var focus: String
        /// BCP-47 language the routine's names should be written in, e.g. "de".
        public var language: String

        public init(goal: String, equipment: String, minutes: Int, focus: String, language: String) {
            self.goal = goal
            self.equipment = equipment
            self.minutes = minutes
            self.focus = focus
            self.language = language
        }
    }

    /// Bounds on what a reply can create. A model can return anything; these keep a runaway reply
    /// from producing a program nobody could run.
    static let maxExercises = 30
    static let maxNameLength = 80
    static let maxNoteLength = 300

    /// The system prompt: the JSON schema and nothing else.
    public static let systemPrompt: String = {
        let muscles = LiftMuscle.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You design strength-training routines. Reply with ONE JSON object and nothing else — no prose, \
        no markdown fences. Schema:
        {"name": string, "note": string, "exercises": [{"name": string, "muscle": string, \
        "sets": integer, "reps": integer, "restSec": integer, "note": string}]}
        "muscle" is the primary muscle and must be one of: \(muscles).
        Keep "note" fields to one short technique cue. Fit the routine into the requested time, \
        including rest.
        """
    }()

    /// The user turn sent with `systemPrompt`.
    public static func userPrompt(for request: Request) -> String {
        var lines: [String] = []
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let equipment = request.equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = request.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Goal: \(goal.isEmpty ? "general strength" : goal)")
        lines.append("Equipment: \(equipment.isEmpty ? "full gym" : equipment)")
        lines.append("Session length: \(max(10, min(180, request.minutes))) minutes")
        if !focus.isEmpty { lines.append("Focus: \(focus)") }
        lines.append("Write the routine name, exercise names and notes in language: \(request.language).")
        return lines.joined(separator: "\n")
    }

    /// Parse a reply into a program draft. Tolerates markdown fences and surrounding prose by reading
    /// the outermost `{…}`; drops exercise lines without a name rather than failing the whole reply.
    public static func parse(_ reply: String) throws -> ImportedProgram {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else { throw ParseError.noJSON }
        let slice = String(reply[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.noJSON
        }

        let rawExercises = (obj["exercises"] as? [Any]) ?? []
        var lines: [ImportedProgramLine] = []
        for case let item as [String: Any] in rawExercises {
            guard lines.count < maxExercises else { break }
            guard let name = text(item["name"] ?? item["exercise"], limit: maxNameLength) else { continue }
            let muscle = (item["muscle"] ?? item["primaryMuscle"]).flatMap { muscleValue($0) }
            lines.append(ImportedProgramLine(
                exercise: name,
                primaryMuscle: muscle,
                secondaryMuscles: [],
                targetSets: int(item["sets"]).map { max(1, min(20, $0)) },
                targetReps: int(item["reps"]).map { max(1, min(100, $0)) },
                targetWeightKg: nil,
                targetMaxRpe: nil,
                restSec: int(item["restSec"] ?? item["rest_sec"] ?? item["rest"]).map { max(0, min(900, $0)) },
                note: text(item["note"], limit: maxNoteLength)))
        }
        guard !lines.isEmpty else { throw ParseError.noExercises }

        let name = text(obj["name"], limit: maxNameLength) ?? "Routine"
        return ImportedProgram(name: name, note: text(obj["note"], limit: maxNoteLength), lines: lines)
    }

    // MARK: - Field coercion

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    /// An integer from a number or from the leading digits of a string ("8-10" → 8, "90s" → 90).
    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            return Int(d.rounded())
        }
        if let s = value as? String {
            let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    /// A muscle from its raw token, case- and separator-insensitively ("Upper back" → upperBack).
    private static func muscleValue(_ value: Any) -> LiftMuscle? {
        guard let s = value as? String else { return nil }
        let key = s.lowercased().filter { $0.isLetter }
        return LiftMuscle.allCases.first { $0.rawValue.lowercased() == key }
    }
}
