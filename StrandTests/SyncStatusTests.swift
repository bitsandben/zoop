import XCTest
@testable import Strand

/// One sync status, resolved once, for every surface that describes the strap sync.
final class SyncStatusTests: XCTestCase {

    private func resolve(connected: Bool = true, ready: Bool = true, backfilling: Bool = false,
                         chunks: Int = 0, lastSyncedAt: TimeInterval? = nil,
                         issue: SyncIssue? = nil) -> SyncStatus {
        SyncStatus.resolve(SyncStatusInput(connected: connected, historyReady: ready, backfilling: backfilling,
                                           chunks: chunks, lastSyncedAt: lastSyncedAt, issue: issue))
    }

    func testBluetoothIssueWinsOverEverything() {
        XCTAssertEqual(resolve(backfilling: true, issue: .bluetooth("off")),
                       .bluetoothUnavailable(message: "off"))
    }

    func testRunningOffloadIsSyncingEvenWithAStaleStall() {
        XCTAssertEqual(resolve(backfilling: true, chunks: 4, issue: .stalled("quiet")), .syncing(chunks: 4))
    }

    func testDisconnectedKeepsTheLastSync() {
        XCTAssertEqual(resolve(connected: false, lastSyncedAt: 100), .noStrap(lastSyncedAt: 100))
    }

    func testConnectedButNotReadyIsPairing() {
        XCTAssertEqual(resolve(ready: false, lastSyncedAt: 100), .pairing)
    }

    func testStallIsReportedAsStalled() {
        XCTAssertEqual(resolve(lastSyncedAt: 100, issue: .stalled("quiet")), .stalled(message: "quiet"))
    }

    func testCompletedSyncWithANoteIsNeverAStall() {
        let status = resolve(lastSyncedAt: 100, issue: .completedWithNote("archived"))
        XCTAssertEqual(status, .completeWithNote(at: 100, message: "archived"))
        XCTAssertFalse(status.isStalled)
    }

    func testCleanAndNeverSynced() {
        XCTAssertEqual(resolve(lastSyncedAt: 100), .complete(at: 100))
        XCTAssertEqual(resolve(), .neverSynced)
    }

    // MARK: Pull-to-sync

    func testPullClaimsUpToDateOnlyForACompletionAfterThePull() {
        XCTAssertEqual(PullSyncOutcome.resolve(status: .complete(at: 60), sawOffload: false, pullStartedAt: 50),
                       .upToDate)
        XCTAssertEqual(PullSyncOutcome.resolve(status: .complete(at: 10), sawOffload: false, pullStartedAt: 50),
                       .didNotStart)
    }

    func testPullStillRunningIsNeverUpToDate() {
        XCTAssertEqual(PullSyncOutcome.resolve(status: .syncing(chunks: 3), sawOffload: true, pullStartedAt: 50),
                       .stillSyncing)
    }

    func testPullThatRanAndStoppedReportsTheStop() {
        let stalled = SyncStatus.stalled(message: "quiet")
        XCTAssertEqual(PullSyncOutcome.resolve(status: stalled, sawOffload: true, pullStartedAt: 50),
                       .status(stalled))
    }

    func testPullThatRanToTheIdleTimeoutWithRowsIsUpToDate() {
        XCTAssertEqual(PullSyncOutcome.resolve(status: .complete(at: 10), sawOffload: true, pullStartedAt: 50),
                       .upToDate)
    }

    func testPullWithoutALinkSaysWhy() {
        XCTAssertEqual(PullSyncOutcome.resolve(status: .pairing, sawOffload: false, pullStartedAt: 50),
                       .status(.pairing))
    }
}
