import XCTest
@testable import Strand

/// The follow-up pass owed to callers that arrived while another re-score held the engine.
final class QueuedRescoreTests: XCTestCase {

    func testGatedCallersKeepTheGateAndTheFirstName() {
        var q = QueuedRescore.merge(nil, unconditional: false, label: "post-offload")
        q = QueuedRescore.merge(q, unconditional: false, label: "resume-gated")
        XCTAssertEqual(q, QueuedRescore(unconditional: false, label: "post-offload"))
    }

    func testUnconditionalCallerUpgradesAndNamesThePass() {
        var q = QueuedRescore.merge(nil, unconditional: false, label: "post-offload")
        q = QueuedRescore.merge(q, unconditional: true, label: "forced")
        XCTAssertEqual(q, QueuedRescore(unconditional: true, label: "forced"))
    }

    func testLaterGatedCallerCannotDowngradeAnUnconditionalPass() {
        var q = QueuedRescore.merge(nil, unconditional: true, label: "dedup-heal")
        q = QueuedRescore.merge(q, unconditional: false, label: "post-offload")
        XCTAssertEqual(q, QueuedRescore(unconditional: true, label: "dedup-heal"))
    }

    func testTriggerNamePrefersTheCallersOwnLabel() {
        XCTAssertEqual(QueuedRescore.triggerName(force: true, skipIfUnchanged: true, label: "resume-gated"),
                       "resume-gated")
        XCTAssertEqual(QueuedRescore.triggerName(force: true, skipIfUnchanged: true, label: nil), "post-offload")
        XCTAssertEqual(QueuedRescore.triggerName(force: true, skipIfUnchanged: false, label: nil), "forced")
        XCTAssertEqual(QueuedRescore.triggerName(force: false, skipIfUnchanged: false, label: nil), "idle")
    }
}
