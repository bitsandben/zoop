import Foundation
import GRDB

// MARK: - v39 store: persisted Coach conversation
// GRDB CRUD over `coachMessage` so the Coach chat survives relaunch. Holds only the user's questions and
// the coach's text replies (no raw biometrics). Not part of the `.zoopbak` settings whitelist.

/// One persisted turn in the Coach conversation.
public struct CoachMessageRow: Equatable, Codable, Sendable {
    public var id: String
    public var role: String          // "user" | "assistant"
    public var text: String
    public var provider: String
    public var createdAt: Int        // epoch seconds
    public var orderIndex: Int       // monotonic replay order (two streamed turns can share createdAt)

    public init(id: String, role: String, text: String, provider: String, createdAt: Int, orderIndex: Int) {
        self.id = id
        self.role = role
        self.text = text
        self.provider = provider
        self.createdAt = createdAt
        self.orderIndex = orderIndex
    }

    static func decode(_ row: Row) -> CoachMessageRow {
        CoachMessageRow(
            id: row["id"], role: row["role"], text: row["text"], provider: row["provider"],
            createdAt: row["createdAt"], orderIndex: row["orderIndex"]
        )
    }
}

extension WhoopStore {

    /// The full stored conversation, oldest first (by `orderIndex`).
    public func coachMessages() async throws -> [CoachMessageRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM coachMessage ORDER BY orderIndex ASC")
                .map(CoachMessageRow.decode)
        }
    }

    /// Replaces the entire stored conversation in one transaction. A full replace is simpler than
    /// incremental bookkeeping across streaming finalisation, and cheap because the table is capped.
    /// Called once per completed send, never per streamed chunk.
    public func replaceCoachMessages(_ rows: [CoachMessageRow]) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMessage")
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO coachMessage (id, role, text, provider, createdAt, orderIndex)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [row.id, row.role, row.text, row.provider, row.createdAt, row.orderIndex])
            }
        }
    }

    /// Wipes the entire stored conversation.
    public func clearCoachMessages() async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM coachMessage")
        }
    }
}
