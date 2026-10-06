import XCTest
@testable import Strand

/// A detected workout is announced once after a sync, never repeated, and never with detection off.
final class WorkoutDetectedNotifierTests: XCTestCase {
    func testNewCandidateNotifies() {
        XCTAssertTrue(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 1_000, lastNotifiedStart: nil))
        XCTAssertTrue(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 2_000, lastNotifiedStart: 1_000))
    }

    func testSameCandidateDoesNotRepeat() {
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 1_000, lastNotifiedStart: 1_000))
    }

    func testNothingWithoutCandidateOrWhenOff() {
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: nil, lastNotifiedStart: nil))
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: false, candidateStart: 1_000, lastNotifiedStart: nil))
    }
}
