import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Public `analyzeDay` contract for degenerate sleep-need inputs. The mirrored Android test uses the
/// same provided 30-second light-sleep session and asserts the same rounded Rest projection.
final class AnalyticsEngineSleepNeedFloorTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2025-06-10"
    private let sessionStart = 1_749_517_200

    private func rest(sleepNeedHours: Double) throws -> Double {
        let provided = SleepSession(
            start: sessionStart,
            end: sessionStart + 30,
            efficiency: 1,
            stages: [StageSegment(start: sessionStart, end: sessionStart + 30, stage: "light")],
            restingHR: nil,
            avgHRV: nil)

        return try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: day,
            profile: profile,
            sleepNeedHours: sleepNeedHours,
            providedSleep: [provided]
        ).restScore)
    }

    func testSleepNeedUsesPointOneHourFloorAtAndAcrossBoundary() throws {
        // Values re-pinned for the Zoop 2026-10 Rest recipe (convex duration, mapped efficiency,
        // consistency omitted when unknown); the floor behaviour under test is unchanged: every need
        // at/below 0.1 h scores identically and 0.101 h is the first to differ.
        let cases: [(need: Double, expectedRest: Double)] = [
            (-1.0, 24.8),
            (0.0, 24.8),
            (0.099, 24.8),
            (0.1, 24.8),
            (0.101, 24.78),
        ]

        let actual = try cases.map { try rest(sleepNeedHours: $0.need) }
        XCTAssertEqual(actual, cases.map(\.expectedRest))
    }
}
