import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class PatternInsightsTests: XCTestCase {

    func testBedtimeWindowFindsTheBestHalfHour() {
        // 22:30–23:00 nights recover at 80, the rest at 50–60.
        var nights: [(onsetMinute: Int, recovery: Double)] = []
        for i in 0..<5 { nights.append((22 * 60 + 35 + i, 80)) }
        for i in 0..<5 { nights.append((23 * 60 + 10 + i, 60)) }
        for i in 0..<5 { nights.append((24 * 60 + 20 + i, 50)) }
        let w = PatternInsights.bedtimeWindow(nights: nights)!
        XCTAssertEqual(w.startMinute, 22 * 60 + 30)
        XCTAssertEqual(w.endMinute, 23 * 60)
        XCTAssertEqual(w.windowMean, 80)
        XCTAssertEqual(w.overallMean, 190.0 / 3, accuracy: 0.01)
        XCTAssertNil(PatternInsights.bedtimeWindow(nights: Array(nights.prefix(10))))
    }

    func testWeekdayPatternNeedsFiveWeekdays() {
        var values: [(weekday: Int, value: Double)] = []
        for w in 1...7 { for _ in 0..<3 { values.append((w, Double(w * 10))) } }
        let p = PatternInsights.weekdayPattern(values)!
        XCTAssertEqual(p.best, 7)
        XCTAssertEqual(p.worst, 1)
        XCTAssertEqual(p.means[3], 30)
        XCTAssertNil(PatternInsights.weekdayPattern(values.filter { $0.weekday <= 4 }))
    }

    func testSleepNeedAddsStrainAndPartOfTheDebt() {
        let n = PatternInsights.sleepNeedTonight(baseNeedMin: 480, strain: 15, debtMin: 120)
        XCTAssertEqual(n.strainMin, 20)
        XCTAssertEqual(n.debtMin, 30)
        XCTAssertEqual(n.totalMin, 530)
        XCTAssertEqual(PatternInsights.sleepNeedTonight(baseNeedMin: 480, strain: 8, debtMin: 600).totalMin, 540)
    }

    func testSplitEffectComparesTheOuterThirds() {
        let pairs = (0..<12).map { (driver: Double($0), outcome: $0 < 4 ? 90.0 : ($0 >= 8 ? 70.0 : 80.0)) }
        let e = PatternInsights.splitEffect(pairs)!
        XCTAssertEqual(e.lowMean, 90)
        XCTAssertEqual(e.highMean, 70)
        XCTAssertEqual(e.delta, -20)
        XCTAssertNil(PatternInsights.splitEffect(Array(pairs.prefix(6))))
    }

    func testWindDownMeasuresTheSettle() {
        let onset = 10_000
        var hr: [HRSample] = []
        for t in stride(from: onset - 900, to: onset, by: 10) { hr.append(HRSample(ts: t, bpm: 70)) }
        // Falls linearly from 68 to 52 over 40 minutes, then holds.
        for t in stride(from: onset, to: onset + 3 * 3600, by: 10) {
            let m = Double(t - onset) / 60
            hr.append(HRSample(ts: t, bpm: Int((max(52, 68 - m * 0.4)).rounded())))
        }
        let w = PatternInsights.windDown(hr: hr, onset: onset)!
        XCTAssertEqual(w.dropBpm, 18, accuracy: 0.5)
        XCTAssertTrue((30...40).contains(w.minutesToSettle), "\(w.minutesToSettle)")
        XCTAssertNil(PatternInsights.windDown(hr: Array(hr.suffix(100)), onset: onset))
    }

    func testInBedMinutesScalesByGoalAndEfficiency() {
        XCTAssertEqual(PatternInsights.inBedMinutes(needMin: 450, goal: 1, efficiency: 0.9), 500, accuracy: 0.01)
        XCTAssertEqual(PatternInsights.inBedMinutes(needMin: 450, goal: 0.85, efficiency: 90), 425, accuracy: 0.01)
        XCTAssertEqual(PatternInsights.inBedMinutes(needMin: 450, goal: 1, efficiency: nil), 500, accuracy: 0.01)
        XCTAssertEqual(PatternInsights.inBedMinutes(needMin: 490, goal: 1, efficiency: 0.99), 500, accuracy: 0.01)
    }
}
