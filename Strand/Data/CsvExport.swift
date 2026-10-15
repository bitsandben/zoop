import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WhoopStore
import StrandImport

/// Settings export to WHOOP's 4-CSV zip via StrandImport.WhoopCsvExporter: merged WHOOP history, imported
/// wins per day. Apple Health rows are excluded so a re-import cannot mis-attribute them.
/// On-device computed rows are marked "noop (APPROXIMATE)" in the Source column both importers ignore; the
/// .sqlite backup remains the lossless restore.
/// Reads use the repository's active+canonical union ids (#458, #814), active first, so a strap remove and
/// re-add does not drop canonical "my-whoop" rows. Merge precedence is reconstructed inline to stay
/// decoupled from the dashboard read path.
enum CsvExport {
    enum ExportResult {
        case exported(URL)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func run(repo: Repository) async -> ExportResult {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        // Active-first union ids (#458), so per-row dedup keeps the live copy.
        let importedIds = repo.importedReadIds
        let computedIds = repo.computedReadIds
        let fromDay = "0000-01-01", toDay = "9999-12-31"
        let hi = Int(Date().timeIntervalSince1970) + 86_400

        do {
            // Dailies: per side, the first union id with a day wins.
            var importedByDay: [String: DailyMetric] = [:]
            for id in importedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where importedByDay[d.day] == nil { importedByDay[d.day] = d }
            }
            var computedByDay: [String: DailyMetric] = [:]
            for id in computedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where computedByDay[d.day] == nil { computedByDay[d.day] = d }
            }
            let imported = importedByDay.values.sorted { $0.day < $1.day }
            let computed = computedByDay.values.sorted { $0.day < $1.day }
            // Cycles series: per (key, day) the first union id with a value wins.
            var seriesRaw: [String: [MetricPoint]] = [:]
            for key in ["sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min",
                        "in_bed_min", "awake_min", "energy_kcal", "avg_hr", "max_hr"] {
                var byDay: [String: MetricPoint] = [:]
                for id in importedIds {
                    for p in try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                    where byDay[p.day] == nil { byDay[p.day] = p }
                }
                seriesRaw[key] = byDay.values.sorted { $0.day < $1.day }
            }
            // Sleeps/workouts: exact duplicates dropped on the natural key, active first.
            var seenSleep = Set<String>(), seenComp = Set<String>()
            var impSleep: [CachedSleepSession] = [], compSleep: [CachedSleepSession] = []
            for id in importedIds {
                for s in try await store.sleepSessions(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenSleep.insert("\(s.startTs)|\(s.endTs)").inserted { impSleep.append(s) }
            }
            for id in computedIds {
                for s in try await store.sleepSessions(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenComp.insert("\(s.startTs)|\(s.endTs)").inserted { compSleep.append(s) }
            }
            var seenImpW = Set<String>(), seenCompW = Set<String>()
            var impWorkouts: [WorkoutRow] = [], compWorkouts: [WorkoutRow] = []
            for id in importedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenImpW.insert("\(w.startTs)|\(w.sport)").inserted { impWorkouts.append(w) }
            }
            for id in computedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenCompW.insert("\(w.startTs)|\(w.sport)").inserted { compWorkouts.append(w) }
            }
            // Journal: natural key (day, question), active first.
            var seenJournal = Set<String>()
            var journal: [JournalEntry] = []
            for id in importedIds {
                for j in try await store.journalEntries(deviceId: id, from: fromDay, to: toDay)
                where seenJournal.insert("\(j.day)|\(j.question)").inserted { journal.append(j) }
            }
            // Sidecar: every metricSeries row under every Zoop source id, full fidelity.
            var sidecar: [String: [MetricPoint]] = [:]
            for id in importedIds + computedIds {
                var points: [MetricPoint] = []
                for key in (try await store.metricKeys(deviceId: id)) {
                    points += try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                }
                if !points.isEmpty { sidecar[id] = points }
            }

            // Repository.localDayKey is main-actor-isolated: precompute each session's local end-day (and
            // the file name) on main into a Sendable [startTs: dayKey] map for the detached merge.
            var endDayByStartTs: [Int: String] = [:]
            for s in impSleep + compSleep {
                endDayByStartTs[s.startTs] = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            }
            let name = defaultName()

            // Assembly, serialization and zip deflate run off the main actor; only Sendable values cross in.
            let tmp = try await Task.detached(priority: .utility) {
                // Merged like Repository.mergeDaily: computed first, imported overwrites.
                var byDay: [String: DailyMetric] = [:]
                var sourceByDay: [String: String] = [:]
                for d in computed { byDay[d.day] = d; sourceByDay[d.day] = "noop (APPROXIMATE)" }
                for d in imported { byDay[d.day] = d; sourceByDay[d.day] = "import" }
                let days = byDay.values.sorted { $0.day < $1.day }

                // Cycles columns DailyMetric lacks, recovered from imported metricSeries.
                var series: [String: [String: Double]] = [:]
                for (key, points) in seriesRaw {
                    for p in points { series[p.day, default: [:]][key] = p.value }
                }

                // Sleep merged per end-day, imported wins (Repository.mergeSleep).
                let endDay: (CachedSleepSession) -> String = { endDayByStartTs[$0.startTs] ?? "" }
                var sleepSource: [Int: String] = [:]   // keyed by startTs (the session's natural key)
                // Keeps every session (#715), so naps and main nights each get a sleeps.csv row.
                for s in compSleep { sleepSource[s.startTs] = "noop (APPROXIMATE)" }
                for s in impSleep { sleepSource[s.startTs] = "import" }
                let sleeps = SleepMerge.merge(imported: impSleep, computed: compSleep, endDay: endDay)

                // Workouts: imported WHOOP plus on-device detected; Apple Health omitted. Dedup by
                // (startTs, sport), imported first, since one session can exist under both ids.
                var seenWorkouts = Set<String>()
                let workouts = (impWorkouts + compWorkouts)
                    .filter { seenWorkouts.insert("\($0.startTs)|\($0.sport)").inserted }

                let entries: [(name: String, data: Data)] = [
                    ("physiological_cycles.csv",
                     Data(WhoopCsvExporter.cyclesCSV(days: days, series: series, sourceByDay: sourceByDay).utf8)),
                    ("sleeps.csv",
                     Data(WhoopCsvExporter.sleepsCSV(
                        sleeps,
                        // Cycle start is the session's local end-day, so the CSVs reconcile by cycle for
                        // non-UTC users (#715).
                        cycleStart: { endDay($0) + " 00:00:00" },
                        sourceBySession: { sleepSource[$0.startTs] ?? "" }).utf8)),
                    ("workouts.csv",
                     Data(WhoopCsvExporter.workoutsCSV(workouts, sourceLabel: { workoutSource($0, computedIds: computedIds) }).utf8)),
                    ("journal_entries.csv", Data(WhoopCsvExporter.journalCSV(journal).utf8)),
                    ("noop_metric_series.json", WhoopCsvExporter.metricSeriesJSON(sidecar)),
                ]
                // Deflate to a temp path off main, inside ZoopScratch so interrupted exports get swept; the
                // atomic swap into the destination stays on main.
                let out = ZoopScratch.file(UUID().uuidString + ".zip")
                try WhoopCsvExporter.writeArchive(entries: entries, to: out)
                return out
            }.value

            #if os(macOS)
            let panel = NSSavePanel()
            panel.title = String(localized: "Export Zoop data as CSV")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else {
                try? FileManager.default.removeItem(at: tmp)
                return .cancelled
            }

            // replaceItemAt is atomic on APFS, so a failed write keeps the user's previous export.
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            return .exported(dest)
            #else
            // iOS: move the staged zip to its user-facing name and hand it to the document picker.
            let staged = ZoopScratch.file(name)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: tmp, to: staged)
            guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
            return .exported(dest)
            #endif
        } catch {
            return .failure("CSV export failed: \(error.localizedDescription)")
        }
    }

    /// Classifies a workout row for the parser-ignored Source column: WhoopImporter writes "whoop", manual
    /// logging "manual", detected workouts the computed source id with sport "detected" (either computed
    /// union id, #458).
    private static func workoutSource(_ w: WorkoutRow, computedIds: [String]) -> String {
        if w.source == "manual" { return "manual" }
        if computedIds.contains(w.source) || w.sport == "detected" { return "noop (APPROXIMATE)" }
        return "import"
    }

    // Repository.localDayKey is MainActor-isolated; only called from `run`.
    @MainActor
    private static func defaultName() -> String {
        "noop-export-\(Repository.localDayKey(Date())).zip"
    }
}
