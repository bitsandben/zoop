import XCTest
import StrandAnalytics
import StrandDesign
import WhoopStore
@testable import Strand

/// The pure parts of the Training page: the seven-day window, the one Effort scale, and the readouts the
/// workout detail builds. None of it needs a store, a strap or a view.
final class TrainingTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func row(_ startTs: Int, strain: Double? = nil, avgHr: Int? = nil, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: startTs + 1800, sport: sport, source: "manual", durationS: 1800,
                   energyKcal: nil, avgHr: avgHr, maxHr: nil, strain: strain, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: Week

    func testWeekIsTheSevenDaysEndingToday() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let week = TrainingWeek.make(rows: [], effortByDay: [:], planned: { _ in [] }, now: now, calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertTrue(week.days.last?.isToday == true)
        XCTAssertEqual(week.days.filter(\.isToday).count, 1)
        XCTAssertTrue(week.isEmpty)
    }

    func testSessionsAreCountedFromTheClockNotFromTheNewestSession() {
        // A session eight days ago is the newest the user has, yet "the last 7 days" holds none of it.
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = row(Int(now.timeIntervalSince1970) - 8 * 86_400)
        let week = TrainingWeek.make(rows: [old], effortByDay: [:], planned: { _ in [] }, now: now, calendar: calendar)
        XCTAssertTrue(week.sessions.isEmpty)
    }

    func testSessionLandsOnItsDayWithTheDaysEffort() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let yesterdayTs = Int(now.timeIntervalSince1970) - 86_400
        let key = TrainingWeek.dayKey(Date(timeIntervalSince1970: TimeInterval(yesterdayTs)), calendar: calendar)
        let week = TrainingWeek.make(rows: [row(yesterdayTs)], effortByDay: [key: 41], planned: { _ in [] },
                                     now: now, calendar: calendar)
        let day = week.days[5]
        XCTAssertEqual(day.sessions.count, 1)
        XCTAssertEqual(day.effort, 41)
        XCTAssertEqual(week.sessions.count, 1)
    }

    // MARK: Effort scale

    func testEffortBandsFollowTheStoredAxisNotTheDisplayScale() {
        XCTAssertEqual(TrainingEffort.band(forStored: 20), .restorative)
        XCTAssertEqual(TrainingEffort.band(forStored: 50), .building)   // WHOOP 10.5: Moderate
        XCTAssertEqual(TrainingEffort.band(forStored: 70), .demanding)  // WHOOP 14.7: High
        XCTAssertEqual(TrainingEffort.band(forStored: 90), .overreaching)
    }

    func testScaleMaxFollowsTheChosenScale() {
        XCTAssertEqual(TrainingEffort.scaleMax(.hundred), 100, accuracy: 1e-9)
        XCTAssertEqual(TrainingEffort.scaleMax(.whoop), 21, accuracy: 1e-9)
    }

    func testGaugeStateMapsToLoadVocabulary() {
        XCTAssertNil(TrainingEffort.band(for: .calibrating))
        XCTAssertEqual(TrainingEffort.band(for: .low), .restorative)
        XCTAssertEqual(TrainingEffort.band(for: .optimal), .building)
        XCTAssertEqual(TrainingEffort.band(for: .high), .demanding)
    }

    // MARK: Readouts

    func testTypicalRangeNeedsFourSessions() {
        XCTAssertNil(WorkoutReadouts.typicalRange(of: [40, 50, 60]))
        XCTAssertNotNil(WorkoutReadouts.typicalRange(of: [40, 50, 60, 50]))
    }

    func testEffortReadoutWithoutStrainStatesWhyInsteadOfANumber() {
        let readout = WorkoutReadouts.effort(strain: nil, others: [], scale: .hundred)
        XCTAssertNil(readout.displayValue)
        XCTAssertEqual(readout.verdict, .unavailable(.noData(since: nil)))
    }

    func testEffortReadoutIsOnTheUsersScaleAndBandedOnTheStoredAxis() {
        let readout = WorkoutReadouts.effort(strain: 60, others: [], scale: .whoop)
        XCTAssertEqual(readout.value ?? 0, 12.6, accuracy: 1e-9)
        XCTAssertEqual(readout.verdict, .load(.building))
        XCTAssertNil(readout.typicalRange, "no baseline below four comparable sessions")
    }

    func testHeartRateReadoutPlacesTheValueAgainstOwnHistory() {
        let others = [140, 142, 144, 146, 148]
        XCTAssertEqual(WorkoutReadouts.heartRate(id: "hr", label: "HR", value: 175, others: others)?.verdict, .above)
        XCTAssertEqual(WorkoutReadouts.heartRate(id: "hr", label: "HR", value: 144, others: others)?.verdict, .typical)
        XCTAssertNil(WorkoutReadouts.heartRate(id: "hr", label: "HR", value: 144, others: [140, 142]))
    }
}
