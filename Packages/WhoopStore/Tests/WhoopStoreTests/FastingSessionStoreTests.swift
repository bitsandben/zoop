import XCTest
import GRDB
@testable import WhoopStore

final class FastingSessionStoreTests: XCTestCase {

    // MARK: - v48 migration (additive: one table + one index)

    func testV48CreatesFastingSessionTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("fastingSession"))
        let pk = try await store.primaryKeyColumns("fastingSession")
        XCTAssertEqual(pk, ["id"])
        let columns = try await store.columnNamesForTest(table: "fastingSession")
        XCTAssertEqual(columns, ["id", "startTs", "endTs", "goalSec", "planId", "note", "source"])
        let indexes = try await store.indexNamesForTest(table: "fastingSession")
        XCTAssertTrue(indexes.contains("idx_fastingSession_startTs"))
    }

    /// A database already at v47 with data in it migrates to v48 without touching existing rows.
    func testV48MigratesFromV47WithoutLosingRows() throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v47-rr-whoop5-fill")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO coachMessage (id, role, text, provider, createdAt, orderIndex)
                VALUES ('m1', 'user', 'hi', 'none', 1, 0)
                """)
            XCTAssertFalse(try db.tableExists("fastingSession"))
        }
        try WhoopStore.makeMigrator().migrate(dbQueue)
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("fastingSession"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coachMessage"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fastingSession"), 0)
        }
    }

    // MARK: - CRUD

    func testStartStopEditAndDeleteRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let running = FastingSessionRow(id: "a", startTs: 1_000, endTs: nil, goalSec: 57_600,
                                        planId: "16:8", source: "app")
        try await store.saveFastingSession(running)
        let active = try await store.activeFastingSession()
        XCTAssertEqual(active, running)

        // Stop, then backdate the start: same id replaces the row.
        var stopped = running
        stopped.endTs = 60_000
        stopped.startTs = 500
        stopped.note = "late dinner"
        try await store.saveFastingSession(stopped)
        let afterStop = try await store.activeFastingSession()
        XCTAssertNil(afterStop)
        let all = try await store.fastingSessions(sinceTs: 0)
        XCTAssertEqual(all, [stopped])

        try await store.deleteFastingSession(id: "a")
        let afterDelete = try await store.fastingSessions(sinceTs: 0)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testSinceFilterKeepsRunningFastAndOrdersNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        let old = FastingSessionRow(id: "old", startTs: 100, endTs: 200, goalSec: 10, planId: "12:12", source: "app")
        let mid = FastingSessionRow(id: "mid", startTs: 5_000, endTs: 6_000, goalSec: 10, planId: "12:12", source: "app")
        let run = FastingSessionRow(id: "run", startTs: 50, endTs: nil, goalSec: 10, planId: "omad", source: "shortcut")
        for r in [old, mid, run] { try await store.saveFastingSession(r) }
        let recent = try await store.fastingSessions(sinceTs: 1_000)
        XCTAssertEqual(recent.map(\.id), ["mid", "run"])
    }
}
