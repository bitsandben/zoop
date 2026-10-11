import XCTest
import WhoopStore
@testable import StrandImport

final class LiftRoutineGeneratorTests: XCTestCase {

    func testParsesFencedReplyWithProse() throws {
        let reply = """
        Here you go:
        ```json
        {"name": "Oberkörper A", "note": "Push focus",
         "exercises": [
           {"name": "Bankdrücken", "muscle": "chest", "sets": 4, "reps": 8, "restSec": 120, "note": "Scapula zurück"},
           {"name": "Rudern", "muscle": "Upper back", "sets": "3", "reps": "8-10", "rest": "90s"}
         ]}
        ```
        """
        let program = try LiftRoutineGenerator.parse(reply)
        XCTAssertEqual(program.name, "Oberkörper A")
        XCTAssertEqual(program.note, "Push focus")
        XCTAssertEqual(program.lines.count, 2)
        XCTAssertEqual(program.lines[0].exercise, "Bankdrücken")
        XCTAssertEqual(program.lines[0].primaryMuscle, .chest)
        XCTAssertEqual(program.lines[0].targetSets, 4)
        XCTAssertEqual(program.lines[0].targetReps, 8)
        XCTAssertEqual(program.lines[0].restSec, 120)
        XCTAssertEqual(program.lines[0].note, "Scapula zurück")
        XCTAssertEqual(program.lines[1].primaryMuscle, .upperBack)
        XCTAssertEqual(program.lines[1].targetSets, 3)
        XCTAssertEqual(program.lines[1].targetReps, 8)
        XCTAssertEqual(program.lines[1].restSec, 90)
        XCTAssertNil(program.lines[1].note)
    }

    func testClampsAndSkipsNamelessLines() throws {
        let reply = """
        {"exercises": [{"sets": 3}, {"name": "Squat", "muscle": "nope", "sets": 99, "reps": 0, "restSec": 5000}]}
        """
        let program = try LiftRoutineGenerator.parse(reply)
        XCTAssertEqual(program.name, "Routine")
        XCTAssertEqual(program.lines.count, 1)
        XCTAssertNil(program.lines[0].primaryMuscle)
        XCTAssertEqual(program.lines[0].targetSets, 20)
        XCTAssertEqual(program.lines[0].targetReps, 1)
        XCTAssertEqual(program.lines[0].restSec, 900)
    }

    func testRejectsReplyWithoutJSONOrExercises() {
        XCTAssertThrowsError(try LiftRoutineGenerator.parse("Sorry, I can't.")) {
            XCTAssertEqual($0 as? LiftRoutineGenerator.ParseError, .noJSON)
        }
        XCTAssertThrowsError(try LiftRoutineGenerator.parse(#"{"name": "X", "exercises": []}"#)) {
            XCTAssertEqual($0 as? LiftRoutineGenerator.ParseError, .noExercises)
        }
    }

    func testCapsExerciseCount() throws {
        let items = (0..<50).map { #"{"name": "E\#($0)"}"# }.joined(separator: ",")
        let program = try LiftRoutineGenerator.parse(#"{"name": "Big", "exercises": [\#(items)]}"#)
        XCTAssertEqual(program.lines.count, LiftRoutineGenerator.maxExercises)
    }

    func testUserPromptDefaultsAndClamps() {
        let prompt = LiftRoutineGenerator.userPrompt(for: .init(
            goal: "  ", equipment: "Dumbbells", minutes: 500, focus: "", language: "de"))
        XCTAssertTrue(prompt.contains("Goal: general strength"))
        XCTAssertTrue(prompt.contains("Equipment: Dumbbells"))
        XCTAssertTrue(prompt.contains("Session length: 180 minutes"))
        XCTAssertFalse(prompt.contains("Focus:"))
        XCTAssertTrue(prompt.contains("language: de"))
        XCTAssertTrue(LiftRoutineGenerator.systemPrompt.contains("upperBack"))
    }
}
