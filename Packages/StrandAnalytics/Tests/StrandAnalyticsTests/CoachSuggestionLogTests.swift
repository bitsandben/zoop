import Foundation
import XCTest
@testable import StrandAnalytics

/// The stored suggestion list: answers, snoozes, pruning, the dismissal feedback and the cloud reply
/// contract.
final class CoachSuggestionLogTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, kind: CoachSuggestion.Kind = .habit, reason: String = "hrvBelowRange",
                      daysAgo: Double = 0, status: CoachSuggestion.Status = .new) -> CoachSuggestion {
        let created = now.addingTimeInterval(-daysAgo * 86_400)
        return CoachSuggestion(id: id, createdAt: created, kind: kind, reason: reason, title: "t", body: "b",
                               rationale: "r", action: .none, status: status,
                               expiresAt: created.addingTimeInterval(86_400),
                               answeredAt: status == .new ? nil : created)
    }

    func testCodableRoundTripKeepsAction() throws {
        let s = CoachSuggestion(id: "a", createdAt: now, kind: .sleepTiming, reason: "sleepDebtBedtime",
                                title: "t", body: "b", rationale: "r", action: .bedtime(minuteOfDay: 1360),
                                expiresAt: now)
        let data = try JSONEncoder().encode([s])
        XCTAssertEqual(try JSONDecoder().decode([CoachSuggestion].self, from: data), [s])
    }

    func testActiveHonoursStatusExpiryAndSnooze() {
        var s = item("a")
        XCTAssertTrue(s.isActive(at: now))
        XCTAssertFalse(s.isActive(at: now.addingTimeInterval(86_400)))
        s.snoozedUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(s.isActive(at: now))
        XCTAssertTrue(s.isActive(at: now.addingTimeInterval(3601)))
        s.status = .dismissed
        XCTAssertFalse(s.isActive(at: now.addingTimeInterval(3601)))
    }

    func testAnsweringStampsAndSnoozingDoesNot() {
        let list = [item("a"), item("b")]
        let answered = CoachSuggestionLog.answering(list, id: "a", status: .dismissed, now: now)
        XCTAssertEqual(answered[0].status, .dismissed)
        XCTAssertEqual(answered[0].answeredAt, now)
        XCTAssertEqual(answered[1], list[1])
        let later = now.addingTimeInterval(3 * 3600)
        let snoozed = CoachSuggestionLog.answering(list, id: "b", status: .new, snoozeUntil: later, now: now)
        XCTAssertEqual(snoozed[1].status, .new)
        XCTAssertEqual(snoozed[1].snoozedUntil, later)
        XCTAssertNil(snoozed[1].answeredAt)
    }

    func testPrunedDropsOldAndSortsNewestFirst() {
        let list = [item("old", daysAgo: 50), item("mid", daysAgo: 2), item("new", daysAgo: 0)]
        XCTAssertEqual(CoachSuggestionLog.pruned(list, now: now).map(\.id), ["new", "mid"])
    }

    func testPrunedKeepsBriefOrderForEqualTimestamps() {
        let list = ["a", "b", "c"].map { item($0) }
        XCTAssertEqual(CoachSuggestionLog.pruned(list, now: now).map(\.id), ["a", "b", "c"])
    }

    func testRecordingReplacesTodaysUnansweredButKeepsAnswers() {
        let old = [item("open"), item("taken", status: .accepted), item("yesterday", daysAgo: 1)]
        let fresh = [item("n1"), item("n2")]
        let ids = CoachSuggestionLog.recording(fresh, into: old, now: now).map(\.id)
        XCTAssertEqual(ids, ["n1", "n2", "taken", "yesterday"])
    }

    func testRecentDismissalSuppressesReason() {
        let list = [item("a", reason: "highStress", daysAgo: 1, status: .dismissed),
                    item("b", reason: "hrvBelowRange", daysAgo: 6, status: .dismissed),
                    item("c", reason: "fastingNext", daysAgo: 2, status: .accepted),
                    item("d", reason: "sleepDebtBedtime", daysAgo: 0, status: .done)]
        let s = CoachSuggestionLog.suppressed(list, now: now)
        // Dismissed within the cooldown, plus anything answered today; older acceptances do not count.
        XCTAssertEqual(s.reasons, ["highStress", "sleepDebtBedtime"])
        XCTAssertTrue(s.kinds.isEmpty)
    }

    func testRepeatedDismissalsPauseTheKind() {
        let list = (0..<3).map { item("d\($0)", kind: .fasting, reason: "fastingNext", daysAgo: Double($0) * 2,
                                      status: .dismissed) }
        XCTAssertEqual(CoachSuggestionLog.suppressed(list, now: now).kinds, [.fasting])
    }

    func testReplyParsesPicksAndDropsInventions() {
        let reply = """
        Sure! {"brief": "Recovery 72 %. Good day to train.", "suggestions": [
          {"id": 1, "title": "Bed by 22:40", "body": "Pay back last week's sleep."},
          {"id": 7, "title": "Invented", "body": "Not a candidate."},
          {"id": 1, "title": "Duplicate", "body": "Again."},
          {"id": 0, "title": "Legs today", "body": "Your legs routine fits today."}]}
        """
        let parsed = CoachBriefReply.parse(reply, candidateCount: 2)
        XCTAssertEqual(parsed?.brief, "Recovery 72 %. Good day to train.")
        XCTAssertEqual(parsed?.picks.map(\.index), [1, 0])
    }

    func testReplyWithoutBriefIsRejected() {
        XCTAssertNil(CoachBriefReply.parse("no json here", candidateCount: 2))
        XCTAssertNil(CoachBriefReply.parse(#"{"brief": "  ", "suggestions": []}"#, candidateCount: 2))
    }
}
