import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SmartWakeTests: XCTestCase {
    let now = 100_000

    func stillGravity() -> [GravitySample] {
        stride(from: now - 600, through: now, by: 5).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
    }

    func flatHR(_ bpm: Int = 52) -> [HRSample] {
        stride(from: now - 1800, through: now, by: 5).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testStillAndCalmIsNotLightSleep() {
        XCTAssertNil(SmartWake.lightSleepSignal(hr: flatHR(), gravity: stillGravity(), now: now))
    }

    func testMovementInTwoMinutesCounts() {
        var g = stillGravity()
        g.append(GravitySample(ts: now - 200, x: 0.3, y: 0, z: 0.95))
        g.append(GravitySample(ts: now - 60, x: -0.3, y: 0.1, z: 0.95))
        g.sort { $0.ts < $1.ts }
        XCTAssertEqual(SmartWake.lightSleepSignal(hr: flatHR(), gravity: g, now: now), .moving)
    }

    func testOneTwitchIsNotEnough() {
        var g = stillGravity()
        g.append(GravitySample(ts: now - 61, x: 0.3, y: 0, z: 0.95))
        g.sort { $0.ts < $1.ts }
        XCTAssertFalse(SmartWake.isMoving(g, now: now))
    }

    func testHeartRateRiseCounts() {
        let hr = stride(from: now - 1800, through: now, by: 5).map { t in
            HRSample(ts: t, bpm: t > now - 180 ? 60 : 52)
        }
        XCTAssertEqual(SmartWake.lightSleepSignal(hr: hr, gravity: stillGravity(), now: now), .heartRateRising)
    }

    func testStaleDataSaysNothing() {
        let hr = stride(from: now - 1800, through: now - 900, by: 5).map { HRSample(ts: $0, bpm: $0 > now - 1080 ? 70 : 52) }
        XCTAssertNil(SmartWake.lightSleepSignal(hr: hr, gravity: [], now: now))
    }
}
