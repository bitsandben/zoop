import XCTest
@testable import StrandImport

final class TrainingPlanDraftTests: XCTestCase {

    private let reply = """
    Hier ist dein Plan:
    ```json
    {"name": "Offener Plan", "focus": "Fitness, Mobility & Kraft", "kind": "open", "startDate": "2026-10-01",
     "summary": "Drei ruhige Einheiten pro Woche.",
     "sessions": [
       {"day": "Fri", "title": "Mobility", "sport": "yoga", "minutes": 20, "time": "7:30"},
       {"day": "Montag", "title": "Kraft A", "sport": "Strength", "minutes": 45, "time": "18:00 Uhr",
        "exercises": [{"name": "Kniebeuge", "muscle": "quads", "sets": 3, "reps": 10, "restSec": 90}]},
       {"day": "Funday", "title": "Bad", "sport": "x", "minutes": 30},
       {"day": 3, "title": "Schwimmen", "sport": "Pool swim", "minutes": 999}
     ]}
    ```
    """

    func testParsesValidatesAndSortsMondayFirst() throws {
        let draft = try TrainingPlanDraftParser.parse(reply, today: "2026-10-10") { $0.lowercased() == "yoga" ? "Yoga" : nil }
        XCTAssertEqual(draft.kind, .open)
        XCTAssertEqual(draft.startDay, "2026-10-10", "a start in the past moves to today")
        XCTAssertEqual(draft.sessions.map(\.title), ["Kraft A", "Schwimmen", "Mobility"])
        XCTAssertEqual(draft.sessions.map(\.weekday), [2, 4, 6])
        XCTAssertEqual(draft.sessions[0].time, "18:00")
        XCTAssertEqual(draft.sessions[0].program?.lines.first?.exercise, "Kniebeuge")
        XCTAssertEqual(draft.sessions[1].minutes, 240)
        XCTAssertEqual(draft.sessions[2].sport, "Yoga")
        XCTAssertEqual(draft.sessions[2].time, "07:30")
        XCTAssertEqual(draft.focus, "Fitness, Mobility & Kraft")
    }

    func testTargetDateNeedsAValidLaterDate() throws {
        let json = #"{"name":"Lauf","kind":"targetDate","startDate":"2026-10-12","targetDate":"2026-12-20","sessions":[{"day":"Sat","title":"Lauf","sport":"Running","minutes":40}]}"#
        let draft = try TrainingPlanDraftParser.parse(json, today: "2026-10-10")
        XCTAssertEqual(draft.kind, .targetDate)
        XCTAssertEqual(draft.targetDay, "2026-12-20")
        let bad = json.replacingOccurrences(of: "2026-12-20", with: "2026-01-01")
        XCTAssertEqual(try TrainingPlanDraftParser.parse(bad, today: "2026-10-10").kind, .open)
    }

    func testRejectsRepliesWithoutSessions() {
        XCTAssertThrowsError(try TrainingPlanDraftParser.parse("no json", today: "2026-10-10"))
        XCTAssertThrowsError(try TrainingPlanDraftParser.parse(#"{"sessions":[]}"#, today: "2026-10-10")) {
            XCTAssertEqual($0 as? TrainingPlanDraftParser.ParseError, .noSessions)
        }
    }

    func testJSONRoundTripKeepsTheSchedule() throws {
        let draft = try TrainingPlanDraftParser.parse(reply, today: "2026-10-10")
        let again = try TrainingPlanDraftParser.parse(TrainingPlanDraftParser.json(draft), today: "2026-10-10")
        XCTAssertEqual(again.sessions.map(\.weekday), draft.sessions.map(\.weekday))
        XCTAssertEqual(again.sessions.map(\.minutes), draft.sessions.map(\.minutes))
        XCTAssertEqual(again.sessions[0].program?.lines.count, 1)
    }
}
