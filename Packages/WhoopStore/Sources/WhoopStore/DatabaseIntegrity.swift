import Foundation
import GRDB

/// SQLite-level integrity verification for the backup/restore pipeline. The `.zoopbak` import checks the
/// SQLite magic and the migrator table, but both sit in the first pages, so a truncated or torn backup
/// still passes and then restores into a store that shows no data. `PRAGMA quick_check` catches
/// structural damage; it skips index-content verification so it stays proportionate on 100 MB+ libraries.
/// Pure SQLite + string logic, kept in the package so it is unit-testable against real damaged files.
public enum DatabaseIntegrity {

    /// Runs `PRAGMA quick_check(1)` on a read-only connection to the database at `path`. Returns nil when
    /// healthy, otherwise SQLite's first complaint (or the open/query error) as a short string. The probed
    /// file is never mutated.
    public static func quickCheckFailure(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return "no database file at that path"
        }
        func quickCheckRows(readonly: Bool) throws -> [String] {
            var config = Configuration()
            config.readonly = readonly
            let dbQueue = try DatabaseQueue(path: path, configuration: config)
            return try dbQueue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check(1)") }
        }
        do {
            // Read-only first: never mutates the probed file and coexists with the app's open pool.
            return verdict(fromRows: try quickCheckRows(readonly: true))
        } catch {
            // A checkpointed WAL backup keeps journal_mode=WAL but ships without -wal/-shm, so a read-only open
            // fails SQLITE_CANTOPEN. Retry read-write; the probed file is always ours (staged temp or just-swapped).
            do { return verdict(fromRows: try quickCheckRows(readonly: false)) }
            catch { return error.localizedDescription }
        }
    }

    /// Classifies the rows `PRAGMA quick_check` returned: nil = healthy (the single "ok" row), otherwise the
    /// first complaint verbatim. An empty result is a failure too: quick_check always answers.
    public static func verdict(fromRows rows: [String]) -> String? {
        if rows.count == 1, rows[0].lowercased() == "ok" { return nil }
        return rows.first { $0.lowercased() != "ok" } ?? "quick_check returned no verdict"
    }

    /// SQLite's banner line (names the database, says nothing about the fault), joined into the same row
    /// as the real diagnosis.
    private static func isBanner(_ line: String) -> Bool {
        line.hasPrefix("*** in database") && line.hasSuffix("***")
    }

    /// The part of a `verdict` worth showing a person, as one line: drops the "*** in database main ***"
    /// banner, joins the rest, and caps the length. `verdict` itself stays verbatim for forensics. Falls back
    /// to the raw verdict with newlines flattened when stripping would leave nothing.
    public static func readableComplaint(_ verdict: String, limit: Int = 140) -> String {
        let kept = verdict.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isBanner($0) }
        let joined = kept.isEmpty
            ? verdict.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            : kept.joined(separator: "; ")
        let cap = max(1, limit)
        guard joined.count > cap else { return joined }
        return String(joined.prefix(cap - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
