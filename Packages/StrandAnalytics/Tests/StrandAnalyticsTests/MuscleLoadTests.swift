import XCTest
@testable import StrandAnalytics

final class MuscleLoadTests: XCTestCase {
    private let now = 1_800_000_000
    private let day = 86_400

    private func session(_ sport: String, daysAgo: Double, minutes: Double = 45, intensity: Double = 1)
        -> MuscleLoad.Session {
        let end = now - Int(daysAgo * Double(day))
        return .workout(sport: sport, startTs: end - Int(minutes * 60), endTs: end,
                        minutes: minutes, intensity: intensity)
    }

    private func states(_ r: MuscleLoad.Result) -> [MuscleLoad.Group: MuscleLoad.State] {
        Dictionary(uniqueKeysWithValues: r.entries.map { ($0.group, $0.state) })
    }

    func testNoDataIsNil() {
        XCTAssertNil(MuscleLoad.compute(sessions: [], now: now))
        // Only old sessions: nothing in the last 14 days.
        XCTAssertNil(MuscleLoad.compute(sessions: [session("Running", daysAgo: 20)], now: now))
    }

    func testSwimmingWeekLoadsShouldersAndLatsAndLeavesLegsLow() throws {
        let r = try XCTUnwrap(MuscleLoad.compute(
            sessions: [session("Pool swim", daysAgo: 1), session("Open-water swim", daysAgo: 3),
                       session("Pool swim", daysAgo: 5)], now: now))
        let s = states(r)
        XCTAssertEqual(s[.shoulders], .high)
        XCTAssertEqual(s[.lats], .high)
        for g in [MuscleLoad.Group.quads, .hamstrings, .calves, .glutes] { XCTAssertEqual(s[g], .under, "\(g)") }
        guard case let .focused(top, sport, low) = r.verdict else { return XCTFail("\(r.verdict)") }
        XCTAssertEqual(Set(top), [.shoulders, .lats])
        XCTAssertEqual(low, .legs)
        XCTAssertEqual(sport, "Pool swim")
    }

    func testRunningWeekIsTheReverse() throws {
        let r = try XCTUnwrap(MuscleLoad.compute(
            sessions: [session("Running", daysAgo: 1), session("Running", daysAgo: 4)], now: now))
        let s = states(r)
        XCTAssertEqual(s[.quads], .high)
        XCTAssertEqual(s[.calves], .high)
        for g in [MuscleLoad.Group.shoulders, .lats, .chest, .triceps] { XCTAssertEqual(s[g], .under, "\(g)") }
        guard case let .focused(top, sport, low) = r.verdict else { return XCTFail("\(r.verdict)") }
        XCTAssertTrue(Set(top).isSubset(of: [.quads, .calves]))
        XCTAssertEqual(sport, "Running")
        XCTAssertEqual(low, .upperBody)
    }

    func testMixedWeekIsBalanced() throws {
        let r = try XCTUnwrap(MuscleLoad.compute(
            sessions: [session("Pool swim", daysAgo: 1), session("Running", daysAgo: 2),
                       session("Climbing", daysAgo: 3), session("Cycling", daysAgo: 4),
                       session("Strength", daysAgo: 5)], now: now))
        XCTAssertFalse(r.entries.contains { $0.state == .high }, "\(r.entries.map { ($0.group, $0.share) })")
        XCTAssertEqual(r.verdict, .balanced)
    }

    func testPersonalRatioFlagsAnUnusualWeek() throws {
        // Three steady weeks of mixed training, then a week of the same mix at three times the dose.
        let mix = ["Pool swim", "Running", "Climbing", "Cycling", "Strength"]
        var sessions: [MuscleLoad.Session] = []
        for w in 1...3 {
            for (i, sport) in mix.enumerated() {
                sessions.append(session(sport, daysAgo: Double(w * 7 + i) + 0.5, minutes: 30))
            }
        }
        for (i, sport) in mix.enumerated() {
            sessions.append(session(sport, daysAgo: Double(i) + 0.5, minutes: 90))
        }
        let r = try XCTUnwrap(MuscleLoad.compute(sessions: sessions, now: now))
        let quads = try XCTUnwrap(r.entry(.quads))
        XCTAssertEqual(quads.weeklyLoads.count, 4)
        XCTAssertGreaterThan(quads.ratio ?? 0, 1.5)
        XCTAssertEqual(quads.state, .high)
    }

    func testRecoveryDropsRightAfterASessionAndReturns() throws {
        let fresh = try XCTUnwrap(MuscleLoad.compute(sessions: [session("Running", daysAgo: 0.05, minutes: 60)], now: now))
        let later = try XCTUnwrap(MuscleLoad.compute(sessions: [session("Running", daysAgo: 4, minutes: 60)], now: now))
        XCTAssertLessThan(try XCTUnwrap(fresh.entry(.quads)).percentRecovered, 20)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fresh.entry(.chest)).percentRecovered, 95)
        XCTAssertEqual(try XCTUnwrap(later.entry(.quads)).percentRecovered, 100)
    }

    func testContributionsAndSportTable() throws {
        let r = try XCTUnwrap(MuscleLoad.compute(
            sessions: [session("Running", daysAgo: 1, minutes: 60), session("Pool swim", daysAgo: 2)], now: now))
        let quads = try XCTUnwrap(r.entry(.quads))
        XCTAssertEqual(quads.contributions.first?.sport, "Running")
        XCTAssertEqual(quads.contributions.count, 2)
        XCTAssertEqual(MuscleLoad.involvement(sport: "HKWorkoutActivityTypeSwimming")[.lats], 1)
        XCTAssertEqual(MuscleLoad.involvement(sport: "TraditionalStrengthTraining"), MuscleLoad.strength)
        XCTAssertEqual(MuscleLoad.involvement(sport: "detected"), MuscleLoad.generic)
    }

    func testIntensity() {
        XCTAssertEqual(MuscleLoad.intensity(avgHr: 125, hrMax: 190, restingHr: 60, effort: nil), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MuscleLoad.intensity(avgHr: nil, hrMax: nil, restingHr: nil, effort: 40), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MuscleLoad.intensity(avgHr: nil, hrMax: nil, restingHr: nil, effort: nil), 1)
    }
}
