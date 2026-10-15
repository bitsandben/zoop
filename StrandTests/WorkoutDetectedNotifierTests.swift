import XCTest
@testable import Strand

/// A detected workout is announced once after a sync, never repeated, and never with detection off.
final class WorkoutDetectedNotifierTests: XCTestCase {
    func testNewCandidateNotifies() {
        XCTAssertTrue(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 1_000, lastNotifiedStart: nil))
        XCTAssertTrue(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 10_000, lastNotifiedStart: 1_000))
    }

    func testSameCandidateDoesNotRepeat() {
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 1_000, lastNotifiedStart: 1_000))
    }

    func testNothingWithoutCandidateOrWhenOff() {
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: nil, lastNotifiedStart: nil))
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: false, candidateStart: 1_000, lastNotifiedStart: nil))
    }

    /// The detector's start edge drifts between syncs; a few minutes' drift is the same workout.
    func testDriftedStartIsTheSameWorkout() {
        XCTAssertFalse(WorkoutDetectedNotifier.shouldNotify(enabled: true, candidateStart: 1_000 + 7 * 60,
                                                            lastNotifiedStart: 1_000))
    }

    /// A candidate whose heart rate ends at the edge of the synced data may still be running.
    func testRecentlyEndedCandidateWaitsForALaterSync() {
        let end = 100_000
        XCTAssertFalse(WorkoutDetectedNotifier.isSettled(endSec: end, now: end + 60))
        XCTAssertTrue(WorkoutDetectedNotifier.isSettled(endSec: end, now: end + WorkoutDetectedNotifier.settleSec))
    }
}
