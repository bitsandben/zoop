import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The Workouts tab's Cardio / Muscular load gauges and the weekly strength totals.
final class TrainingLoadGaugeTests: XCTestCase {

    private var ord = 0

    private func set(weight: Double? = 50, reps: Int? = 10, warmup: Bool = false) -> LiftSetRow {
        ord += 1
        return LiftSetRow(id: UUID().uuidString, deviceId: "dev", sessionId: "s", ord: ord, exercise: "x",
                          primaryMuscle: .chest, secondaryMuscles: [], setIndex: ord,
                          weightKg: weight, reps: reps, rpe: nil, isWarmup: warmup,
                          startTs: nil, endTs: nil, restSec: nil, note: nil)
    }

    private func day(_ daysAgo: Int, sets n: Int) -> TrainingLoadGauge.LiftDay {
        .init(daysAgo: daysAgo, sets: (0..<n).map { _ in set() })
    }

    // MARK: classification

    func testCalibratingBeforeThreeWeeks() {
        let r = TrainingLoadGauge.reading(acute: 10, chronic: 10, historyDays: 20)
        XCTAssertEqual(r.state, .calibrating)
        XCTAssertEqual(r.acute, 10)
        XCTAssertNil(r.chronic)
        XCTAssertNil(r.optimalLow)
        XCTAssertNil(r.optimalHigh)
    }

    func testBandAndStates() {
        let opt = TrainingLoadGauge.reading(acute: 10, chronic: 10, historyDays: 21)
        XCTAssertEqual(opt.state, .optimal)
        XCTAssertEqual(opt.optimalLow!, 8, accuracy: 1e-9)
        XCTAssertEqual(opt.optimalHigh!, 13, accuracy: 1e-9)
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 7.9, chronic: 10, historyDays: 30).state, .low)
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 13.1, chronic: 10, historyDays: 30).state, .high)
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 8, chronic: 10, historyDays: 30).state, .optimal)
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 13, chronic: 10, historyDays: 30).state, .optimal)
    }

    func testZeroNorm() {
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 0, chronic: 0, historyDays: 30).state, .low)
        XCTAssertEqual(TrainingLoadGauge.reading(acute: 3, chronic: 0, historyDays: 30).state, .high)
    }

    func testScaleCoversValueAndBand() {
        for (a, c) in [(10.0, 10.0), (40.0, 10.0), (1.0, 60.0), (0.0, 0.0)] {
            let r = TrainingLoadGauge.reading(acute: a, chronic: c, historyDays: 30)
            XCTAssertGreaterThanOrEqual(r.scaleMax, a)
            XCTAssertGreaterThanOrEqual(r.scaleMax, r.optimalHigh ?? 0)
            XCTAssertGreaterThan(r.scaleMax, 0)
        }
    }

    func testNiceCeiling() {
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(0), 1)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(1), 1)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(1.2), 2)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(2.2), 2.5)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(3), 5)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(19.5), 20)
        XCTAssertEqual(TrainingLoadGauge.niceCeiling(51), 100)
    }

    // MARK: cardio reuses TrainingLoadEngine

    func testCardioMatchesEngine() {
        let loads = Array(repeating: 40.0, count: 30) + Array(repeating: 80.0, count: 7)
        let result = TrainingLoadEngine.evaluateDense(loads)
        let r = TrainingLoadGauge.cardio(result)
        XCTAssertEqual(r.acute!, result.acuteLoad!, accuracy: 1e-9)
        XCTAssertEqual(r.chronic!, result.chronicLoad!, accuracy: 1e-9)
        XCTAssertEqual(r.state, .high)   // a doubled week sits above 1.3 × CTL
    }

    func testCardioCalibratingOnShortHistory() {
        XCTAssertEqual(TrainingLoadGauge.cardio(TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 10))).state,
                       .calibrating)
        XCTAssertEqual(TrainingLoadGauge.cardio(TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 18))).state,
                       .calibrating)
        XCTAssertEqual(TrainingLoadGauge.cardio(TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 25))).state,
                       .optimal)
    }

    // MARK: muscular

    func testMuscularSteadyWeeksIsOptimal() {
        // 12 working sets every week for four weeks.
        let sessions = [day(1, sets: 12), day(8, sets: 12), day(15, sets: 12), day(22, sets: 12)]
        let r = TrainingLoadGauge.muscular(sessions: sessions, historyDays: 60)
        XCTAssertEqual(r.acute, 12)
        XCTAssertEqual(r.chronic!, 12, accuracy: 1e-9)
        XCTAssertEqual(r.state, .optimal)
    }

    func testMuscularTracksAVaryingWeek() {
        let base = [day(8, sets: 10), day(15, sets: 10), day(22, sets: 10)]
        let light = TrainingLoadGauge.muscular(sessions: base + [day(2, sets: 2)], historyDays: 60)
        XCTAssertEqual(light.acute, 2)
        XCTAssertEqual(light.chronic!, 8, accuracy: 1e-9)
        XCTAssertEqual(light.state, .low)
        let heavy = TrainingLoadGauge.muscular(sessions: base + [day(0, sets: 30)], historyDays: 60)
        XCTAssertEqual(heavy.acute, 30)
        XCTAssertEqual(heavy.chronic!, 15, accuracy: 1e-9)
        XCTAssertEqual(heavy.state, .high)
    }

    func testMuscularIgnoresWarmupsSkippedFutureAndOldSessions() {
        let s = TrainingLoadGauge.LiftDay(daysAgo: 0, sets: [set(), set(warmup: true), set(reps: 0), set(reps: nil)])
        XCTAssertEqual(TrainingLoadGauge.workingSets(s.sets), 2)
        let r = TrainingLoadGauge.muscular(sessions: [s, day(-1, sets: 9), day(28, sets: 9)], historyDays: 60)
        XCTAssertEqual(r.acute, 2)
        XCTAssertEqual(r.chronic!, 0.5, accuracy: 1e-9)
    }

    func testMuscularCalibrating() {
        XCTAssertEqual(TrainingLoadGauge.muscular(sessions: [day(0, sets: 10)], historyDays: 5).state, .calibrating)
    }

    // MARK: strength week

    func testStrengthWeek() {
        let sessions = [
            TrainingLoadGauge.LiftDay(daysAgo: 0, sets: [set(weight: 100, reps: 5), set(weight: 20, reps: 10, warmup: true)]),
            TrainingLoadGauge.LiftDay(daysAgo: 6, sets: [set(weight: 50, reps: 10), set(weight: nil, reps: 10)]),
            TrainingLoadGauge.LiftDay(daysAgo: 7, sets: [set(weight: 100, reps: 10)]),
        ]
        let w = TrainingLoadGauge.strengthWeek(sessions: sessions)
        XCTAssertEqual(w.workingSets, 3)
        XCTAssertEqual(w.volumeKg, 1000, accuracy: 1e-9)
        XCTAssertEqual(TrainingLoadGauge.strengthWeek(sessions: []), .init(workingSets: 0, volumeKg: 0))
    }
}
