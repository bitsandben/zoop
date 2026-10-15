import Foundation
import GRDB

// MARK: - v17 store: Lab Book markers
// GRDB CRUD over `labMarker` (one row per user-entered dated reading). Every write also upserts the daily
// `metricSeries` projection under source id `lab-book`, which is how Compare / Explore / Coach see the book.
//
// NON-CLINICAL: stores only user-entered values plus an optional user-entered `referenceText` (verbatim).
// No reference-range tables, no normality judgement, ever.

/// One stored Lab Book reading. Natural key (deviceId, markerKey, takenAt, source) is a UNIQUE index so
/// re-import is idempotent; `id` is a stable client-generated identifier for edit/delete and backups.
public struct LabMarkerRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var markerKey: String
    public var category: String
    /// Pre-derived yyyy-MM-dd day key (the projection key for this reading).
    public var day: String
    /// Precise instant the reading was taken (epoch seconds).
    public var takenAt: Int
    /// Numeric reading. Nil for a qualitative entry whose meaning is in `valueText`.
    public var value: Double?
    public var valueText: String?
    public var unit: String
    public var source: String
    public var note: String?
    /// User-entered reference range, shown back verbatim. Zoop ships none.
    public var referenceText: String?

    public init(
        id: String,
        deviceId: String,
        markerKey: String,
        category: String,
        day: String,
        takenAt: Int,
        value: Double?,
        valueText: String?,
        unit: String,
        source: String,
        note: String?,
        referenceText: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.markerKey = markerKey
        self.category = category
        self.day = day
        self.takenAt = takenAt
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.source = source
        self.note = note
        self.referenceText = referenceText
    }

    static func decode(_ row: Row) -> LabMarkerRow {
        LabMarkerRow(
            id: row["id"],
            deviceId: row["deviceId"],
            markerKey: row["markerKey"],
            category: row["category"],
            day: row["day"],
            takenAt: row["takenAt"],
            value: row["value"],
            valueText: row["valueText"],
            unit: row["unit"],
            source: row["source"],
            note: row["note"],
            referenceText: row["referenceText"]
        )
    }
}

extension WhoopStore {

    /// The constant device-id the daily marker projection is written under.
    public static let labBookSourceId = "lab-book"

    // MARK: - Upsert (idempotent by natural key) + project to metricSeries

    /// Upserts lab-marker rows, then re-projects the affected (markerKey, day) cells into `metricSeries` under
    /// `lab-book`. Idempotent on (deviceId, markerKey, takenAt, source). The projection is latest-per-day (greatest
    /// `takenAt`) and numeric-only, since a REAL-only cell cannot carry `valueText`. Returns rows written.
    @discardableResult
    public func upsertLabMarkers(_ rows: [LabMarkerRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var written = 0
            var touched: Set<DayCell> = []
            for r in rows {
                // Keyed on the natural index, not the `id` PK: a re-import with a freshly minted id must update, not duplicate.
                try db.execute(sql: """
                    INSERT INTO labMarker
                        (id, deviceId, markerKey, category, day, takenAt,
                         value, valueText, unit, source, note, referenceText)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE SET
                        category = excluded.category,
                        day = excluded.day,
                        value = excluded.value,
                        valueText = excluded.valueText,
                        unit = excluded.unit,
                        note = excluded.note,
                        referenceText = excluded.referenceText
                    """, arguments: [
                        r.id, r.deviceId, r.markerKey, r.category, r.day, r.takenAt,
                        r.value, r.valueText, r.unit, r.source, r.note, r.referenceText,
                    ])
                written += db.changesCount
                touched.insert(DayCell(deviceId: r.deviceId, markerKey: r.markerKey, day: r.day))
            }
            try reprojectCells(db, cells: touched)
            return written
        }
    }

    // MARK: - Reads

    /// All readings in a category, oldest first (by takenAt).
    public func labMarkers(deviceId: String, category: String) async throws -> [LabMarkerRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM labMarker
                WHERE deviceId = ? AND category = ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId, category]).map(LabMarkerRow.decode)
        }
    }

    /// Full reading history for one marker, oldest first (by takenAt).
    public func labMarkers(deviceId: String, markerKey: String) async throws -> [LabMarkerRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM labMarker
                WHERE deviceId = ? AND markerKey = ?
                ORDER BY takenAt ASC
                """, arguments: [deviceId, markerKey]).map(LabMarkerRow.decode)
        }
    }

    /// Distinct marker keys present for a device, sorted ascending.
    public func markerKeysPresent(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT markerKey FROM labMarker
                WHERE deviceId = ?
                ORDER BY markerKey ASC
                """, arguments: [deviceId])
        }
    }

    // MARK: - Delete (removes the row AND its now-orphaned projected day)

    /// Deletes one reading by `id`, then recomputes (or removes) the projected `metricSeries` day for its cell.
    /// Returns true if a row was deleted.
    @discardableResult
    public func deleteLabMarker(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT * FROM labMarker WHERE id = ?", arguments: [id]).map(LabMarkerRow.decode) else {
                return false
            }
            try db.execute(sql: "DELETE FROM labMarker WHERE id = ?", arguments: [id])
            try reprojectCells(db, cells: [DayCell(deviceId: row.deviceId, markerKey: row.markerKey, day: row.day)])
            return true
        }
    }

    // MARK: - Projection helpers (private)

    /// Identifies one daily projection cell.
    private struct DayCell: Hashable {
        let deviceId: String
        let markerKey: String
        let day: String
    }

    /// Recomputes the `lab-book` projection for each touched cell from the current `labMarker` rows; a cell with
    /// no numeric reading left has its projected day deleted.
    private func reprojectCells(_ db: Database, cells: Set<DayCell>) throws {
        for cell in cells {
            // Latest numeric reading for this (markerKey, day): greatest takenAt with a non-null value.
            let latest = try Double.fetchOne(db, sql: """
                SELECT value FROM labMarker
                WHERE deviceId = ? AND markerKey = ? AND day = ? AND value IS NOT NULL
                ORDER BY takenAt DESC
                LIMIT 1
                """, arguments: [cell.deviceId, cell.markerKey, cell.day])

            if let v = latest {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [WhoopStore.labBookSourceId, cell.day, cell.markerKey, v])
            } else {
                try db.execute(sql: """
                    DELETE FROM metricSeries
                    WHERE deviceId = ? AND day = ? AND key = ?
                    """, arguments: [WhoopStore.labBookSourceId, cell.day, cell.markerKey])
            }
        }
    }
}
