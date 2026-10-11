import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class EnergyBankTests: XCTestCase {

    private func hr(from start: Int, to end: Int, bpm: Int, every: Int = 60) -> [HRSample] {
        stride(from: start, to: end, by: every).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testMorningLevelFromRecoveryAndSleep() {
        XCTAssertEqual(EnergyBank.morningLevel(recovery: 100, sleepSufficiency: nil), 95, accuracy: 1e-9)
        XCTAssertEqual(EnergyBank.morningLevel(recovery: 0, sleepSufficiency: nil), 20, accuracy: 1e-9)
        XCTAssertEqual(EnergyBank.morningLevel(recovery: nil, sleepSufficiency: nil), 60, accuracy: 1e-9)
        // Half the sleep need missed costs half the shortfall penalty; oversleeping adds nothing.
        XCTAssertEqual(EnergyBank.morningLevel(recovery: 100, sleepSufficiency: 0.5), 85, accuracy: 1e-9)
        XCTAssertEqual(EnergyBank.morningLevel(recovery: 100, sleepSufficiency: 1.3), 95, accuracy: 1e-9)
    }

    func testSustainedHighHeartRateDrainsMonotonically() {
        let start = 1_700_000_000, end = start + 2 * 3600
        let r = EnergyBank.compute(.init(start: start, end: end, heartRate: hr(from: start, to: end, bpm: 165),
                                         morningRecovery: 80, restingHR: 55, maxHR: 185))
        XCTAssertEqual(r.timeline.count, 2 * 12 + 1)
        for (a, b) in zip(r.timeline, r.timeline.dropFirst()) { XCTAssertLessThan(b.level, a.level) }
        XCTAssertLessThan(r.current, r.morning - 40)
        XCTAssertEqual(r.charged, 0)
        XCTAssertEqual(r.drained, r.morning - r.current, accuracy: 1e-9)
    }

    func testHigherHeartRateDrainsFaster() {
        let start = 1_700_000_000, end = start + 3600
        func after(_ bpm: Int) -> Double {
            EnergyBank.compute(.init(start: start, end: end, heartRate: hr(from: start, to: end, bpm: bpm),
                                     morningRecovery: 70, restingHR: 55, maxHR: 185)).current
        }
        XCTAssertGreaterThan(after(90), after(130))
        XCTAssertGreaterThan(after(130), after(170))
    }

    func testSleepRecharges() {
        let start = 1_700_000_000, end = start + 3 * 3600
        let r = EnergyBank.compute(.init(start: start, end: end,
                                         sleeps: [.init(start: start, end: end, quality: 1)],
                                         morningRecovery: 20))
        XCTAssertEqual(r.current, r.morning + 30, accuracy: 1e-6)
        XCTAssertEqual(r.drained, 0)
        // Poorer sleep charges less.
        let poor = EnergyBank.compute(.init(start: start, end: end,
                                            sleeps: [.init(start: start, end: end, quality: 0.5)],
                                            morningRecovery: 20))
        XCTAssertEqual(poor.current, poor.morning + 15, accuracy: 1e-6)
    }

    func testCalmRestRechargesAndStressBlocksIt() {
        let start = 1_700_000_000, end = start + 3600
        let calm = EnergyBank.compute(.init(start: start, end: end, heartRate: hr(from: start, to: end, bpm: 58),
                                            morningRecovery: 50, restingHR: 55, maxHR: 185))
        XCTAssertEqual(calm.current, calm.morning + EnergyBank.calmChargePerHour, accuracy: 1e-6)
        let stressed = EnergyBank.compute(.init(start: start, end: end, heartRate: hr(from: start, to: end, bpm: 58),
                                                stress: [.init(ts: start, level: 3)],
                                                morningRecovery: 50, restingHR: 55, maxHR: 185))
        XCTAssertEqual(stressed.current,
                       stressed.morning - EnergyBank.passiveDrainPerHour - EnergyBank.stressDrainPerHour,
                       accuracy: 1e-6)
    }

    func testNoHeartRateIsPassiveDrainOnly() {
        let start = 1_700_000_000, end = start + 4 * 3600
        let r = EnergyBank.compute(.init(start: start, end: end, morningRecovery: 60))
        XCTAssertEqual(r.current, r.morning - 4 * EnergyBank.passiveDrainPerHour, accuracy: 1e-6)
    }

    func testClampsToBounds() {
        let start = 1_700_000_000
        let full = EnergyBank.compute(.init(start: start, end: start + 12 * 3600,
                                            sleeps: [.init(start: start, end: start + 12 * 3600, quality: 1)],
                                            morningRecovery: 90))
        XCTAssertEqual(full.current, 100)
        XCTAssertTrue(full.timeline.allSatisfy { $0.level <= 100 })
        XCTAssertEqual(full.charged, 100 - full.morning, accuracy: 1e-9)

        let end = start + 10 * 3600
        let empty = EnergyBank.compute(.init(start: start, end: end, heartRate: hr(from: start, to: end, bpm: 180),
                                             morningRecovery: 10, restingHR: 55, maxHR: 185))
        XCTAssertEqual(empty.current, 0)
        XCTAssertTrue(empty.timeline.allSatisfy { $0.level >= 0 })
        XCTAssertEqual(empty.drained, empty.morning, accuracy: 1e-9)
    }

    func testDeterministicAndOrderIndependent() {
        let start = 1_700_000_000, end = start + 6 * 3600
        var samples = hr(from: start, to: start + 3600, bpm: 150) + hr(from: start + 3600, to: end, bpm: 70)
        let input = EnergyBank.Inputs(start: start, end: end, heartRate: samples,
                                      sleeps: [.init(start: start + 4 * 3600, end: start + 5 * 3600)],
                                      stress: [.init(ts: start + 2 * 3600, level: 2.4)],
                                      morningRecovery: 66, sleepSufficiency: 0.9, restingHR: 52, maxHR: 188)
        let a = EnergyBank.compute(input)
        samples.reverse()
        var shuffled = input
        shuffled.heartRate = samples
        XCTAssertEqual(a, EnergyBank.compute(input))
        XCTAssertEqual(a, EnergyBank.compute(shuffled))
    }

    func testEmptyWindowReturnsMorning() {
        let r = EnergyBank.compute(.init(start: 100, end: 100, morningRecovery: 50))
        XCTAssertEqual(r.current, r.morning)
        XCTAssertEqual(r.timeline.count, 1)
    }
}
