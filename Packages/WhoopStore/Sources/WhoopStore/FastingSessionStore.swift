import Foundation
import GRDB

// MARK: - v48 store: user-logged fasting windows (Zoop 2.0 WP-10)
//
// Plain CRUD over `fastingSession`, in the CoachMessageStore idiom (Codable row, manual decode, all work
// through the actor's syncRead/syncWrite). Validation (overlaps, future times, end before start) lives in
// `FastingEngine.validate` so the rules are unit-tested without a database. Not in the `.zoopbak`
// settings whitelist.

public struct FastingSessionRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var startTs: Int          // unix seconds
    public var endTs: Int?           // nil while running
    public var goalSec: Int
    public var planId: String
    public var note: String?
    public var source: String        // "app" | "shortcut"

    public init(id: String, startTs: Int, endTs: Int?, goalSec: Int, planId: String,
                note: String? = nil, source: String) {
        self.id = id
        self.startTs = startTs
        self.endTs = endTs
        self.goalSec = goalSec
        self.planId = planId
        self.note = note
        self.source = source
    }

    static func decode(_ row: Row) -> FastingSessionRow {
        FastingSessionRow(id: row["id"], startTs: row["startTs"], endTs: row["endTs"], goalSec: row["goalSec"],
                          planId: row["planId"], note: row["note"], source: row["source"])
    }
}

extension WhoopStore {

    /// Fasts that started at or after `sinceTs`, plus a running one whatever its start, newest first.
    public func fastingSessions(sinceTs: Int) async throws -> [FastingSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM fastingSession WHERE startTs >= ? OR endTs IS NULL ORDER BY startTs DESC
                """, arguments: [sinceTs]).map(FastingSessionRow.decode)
        }
    }

    /// The running fast, if any (the newest when a bad write ever left two open).
    public func activeFastingSession() async throws -> FastingSessionRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM fastingSession WHERE endTs IS NULL ORDER BY startTs DESC LIMIT 1
                """).map(FastingSessionRow.decode)
        }
    }

    /// Insert or replace by id (start, stop and backdated edits all go through here).
    public func saveFastingSession(_ row: FastingSessionRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO fastingSession (id, startTs, endTs, goalSec, planId, note, source)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [row.id, row.startTs, row.endTs, row.goalSec, row.planId, row.note, row.source])
        }
    }

    public func deleteFastingSession(id: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM fastingSession WHERE id = ?", arguments: [id])
        }
    }
}
