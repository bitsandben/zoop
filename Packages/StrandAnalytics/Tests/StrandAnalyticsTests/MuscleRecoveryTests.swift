import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The Lift Log's muscle-recovery estimate: window length, linear decay and stacking.
final class MuscleRecoveryTests: XCTestCase {

    private var ord = 0
    private let hour = 3600

    private func set(_ primary: LiftMuscle?, secondary: [LiftMuscle] = [], rpe: Double? = nil,
                     reps: Int? = 8, warmup: Bool = false) -> LiftSetRow {
        ord += 1
        return LiftSetRow(id: UUID().uuidString, deviceId: "dev", sessionId: "s", ord: ord, exercise: "x",
                          primaryMuscle: primary, secondaryMuscles: secondary, setIndex: ord,
                          weightKg: 50, reps: reps, rpe: rpe, isWarmup: warmup,
                          startTs: nil, endTs: nil, restSec: nil, note: nil)
    }

    private func sets(_ n: Int, _ m: LiftMuscle, secondary: [LiftMuscle] = [], rpe: Double? = nil) -> [LiftSetRow] {
        (0..<n).map { _ in set(m, secondary: secondary, rpe: rpe) }
    }

    func testWindowGrowsWithSetsAndIsClamped() {
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 0), 36)
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 1), 36)
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 3), 48)
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 7), 72)
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 20), 72)
        XCTAssertEqual(MuscleRecovery.windowHours(sets: 3, hard: true), 48 * 1.15, accuracy: 1e-9)
    }

    func testLinearRecoveryWithinWindow() {
        let now = 1_000_000
        let s = MuscleRecovery.Session(endTs: now - 24 * hour, sets: sets(3, .chest))   // 48 h window
        let e = MuscleRecovery.entries(sessions: [s], now: now)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].muscle, .chest)
        XCTAssertEqual(e[0].percentRecovered, 50)
        XCTAssertEqual(e[0].hoursToFull, 24, accuracy: 1e-9)
        XCTAssertEqual(e[0].recentSets, 3)
    }

    func testFullyRecoveredAfterWindowButStillListed() {
        let now = 1_000_000
        let s = MuscleRecovery.Session(endTs: now - 80 * hour, sets: sets(10, .quads))
        let e = MuscleRecovery.entries(sessions: [s], now: now)
        XCTAssertEqual(e.first?.percentRecovered, 100)
        XCTAssertEqual(e.first?.hoursToFull, 0)
        XCTAssertEqual(e.first?.recentSets, 0)
    }

    func testIndirectSetsCountHalfAndRecoverFaster() {
        let now = 1_000_000
        // 6 direct chest sets (66 h window), triceps get 3 fractional sets (48 h window).
        let s = MuscleRecovery.Session(endTs: now - 24 * hour, sets: sets(6, .chest, secondary: [.triceps]))
        let all = MuscleRecovery.entries(sessions: [s], now: now)
        let e = Dictionary(uniqueKeysWithValues: all.map { ($0.muscle, $0) })
        XCTAssertEqual(e[.triceps]?.percentRecovered, 50)
        XCTAssertEqual(e[.chest]?.percentRecovered, 36)   // 24 / 66 = 0.3636
        XCTAssertEqual(all.first?.muscle, .chest, "least recovered first")
    }

    func testOverlappingSessionsStackAndCap() {
        let now = 1_000_000
        let a = MuscleRecovery.Session(endTs: now - 36 * hour, sets: sets(3, .lats))   // fatigue 0.25
        let b = MuscleRecovery.Session(endTs: now - 12 * hour, sets: sets(3, .lats))   // fatigue 0.75
        XCTAssertEqual(MuscleRecovery.entries(sessions: [a, b], now: now).first?.percentRecovered, 0)
        let c = MuscleRecovery.Session(endTs: now - 24 * hour, sets: sets(3, .lats))   // fatigue 0.5
        XCTAssertEqual(MuscleRecovery.entries(sessions: [a, c], now: now).first?.percentRecovered, 25)
    }

    func testHardSessionStretchesWindow() {
        let now = 1_000_000
        let easy = MuscleRecovery.Session(endTs: now - 24 * hour, sets: sets(3, .biceps, rpe: 7))
        let hard = MuscleRecovery.Session(endTs: now - 24 * hour, sets: sets(3, .biceps, rpe: 9.5))
        XCTAssertEqual(MuscleRecovery.entries(sessions: [easy], now: now)[0].percentRecovered, 50)
        XCTAssertEqual(MuscleRecovery.entries(sessions: [hard], now: now)[0].percentRecovered, 43)   // 24 / 55.2
    }

    func testWarmupsUnclassifiedAndFutureSessionsIgnored() {
        let now = 1_000_000
        let s = MuscleRecovery.Session(endTs: now - hour,
                                       sets: [set(.glutes, warmup: true), set(nil), set(.glutes, reps: 0)])
        XCTAssertTrue(MuscleRecovery.entries(sessions: [s], now: now).isEmpty)
        let future = MuscleRecovery.Session(endTs: now + hour, sets: sets(3, .glutes))
        XCTAssertTrue(MuscleRecovery.entries(sessions: [future], now: now).isEmpty)
    }

    func testSegments() {
        XCTAssertEqual(MuscleRecovery.filledSegments(percent: 0), 0)
        XCTAssertEqual(MuscleRecovery.filledSegments(percent: 49), 4)
        XCTAssertEqual(MuscleRecovery.filledSegments(percent: 99), 9)
        XCTAssertEqual(MuscleRecovery.filledSegments(percent: 100), 10)
        XCTAssertEqual(MuscleRecovery.filledSegments(percent: 140), 10)
    }
}
