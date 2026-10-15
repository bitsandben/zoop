import Foundation
import WhoopStore
import StrandImport

/// Maps a parsed Apple Health export into the store under source id "apple-health", beside Whoop, for
/// per-source pages and cross-source consensus.
enum AppleHealthImport {

    /// Rounds fractional step totals (the aggregator sums per source) to match the other rounded counts on
    /// these rows.
    /// Non-negative inputs only: Swift's half-away-from-zero and Kotlin's half-up rounding differ solely
    /// for negatives.
    static func stepsInt(_ v: Double) -> Int { Int(v.rounded()) }


    /// Apple Health mapping revision, stamped into the Import test-mode parser line. Bump when the
    /// aggregate-to-store mapping changes.
    static let importerVersion = 1

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore, deviceId: String,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> ImportSummary {
        // retainRawSamples:false: a multi-year export is millions of samples (up to >1 GB) and iOS
        // jetsam-kills the app if all are held (#355). Per-day aggregates are folded incrementally.
        let result = try ImportCoordinator().importAppleHealth(from: url, retainRawSamples: false)
        let daily = AppleHealthAggregator.aggregate(result)

        let appleRows = daily.map { d in
            AppleDaily(day: d.day,
                       steps: d.steps.map(stepsInt),
                       activeKcal: d.activeKcal, basalKcal: d.basalKcal, vo2max: d.vo2max,
                       avgHr: d.avgHr.map { Int($0.rounded()) },
                       maxHr: d.maxHr.map { Int($0.rounded()) },
                       walkingHr: d.walkingHr.map { Int($0.rounded()) },
                       weightKg: d.weightKg)
        }
        let appleWritten = try await store.upsertAppleDaily(appleRows, deviceId: deviceId)

        let dm = daily.map { d in
            DailyMetric(day: d.day,
                        totalSleepMin: d.asleepMin, efficiency: nil,
                        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.coreMin,
                        disturbances: nil,
                        restingHr: d.restingHr.map { Int($0.rounded()) },
                        avgHrv: d.hrvSDNN, recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: d.spo2Pct, skinTempDevC: nil, respRateBpm: d.respRate,
                        // Steps must land in DailyMetric.steps too: sourced-daily arbitration reads d.steps (#89).
                        steps: d.steps.map(stepsInt),
                        avgSdnn: d.hrvSDNN)   // Apple HRV is SDNN — mirror into the SDNN field
        }
        let dmWritten = try await store.upsertDailyMetrics(dm, deviceId: deviceId)

        let points = AppleHealthAggregator.metricPoints(daily)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        let workouts = result.workouts.map { w in
            WorkoutRow(startTs: Int(w.start.timeIntervalSince1970),
                       endTs: Int(w.end.timeIntervalSince1970),
                       sport: w.activityType, source: WorkoutSource.appleHealthSource,
                       durationS: w.durationS, energyKcal: w.energyKcal,
                       avgHr: w.avgHr.map { Int($0.rounded()) },
                       maxHr: w.maxHr.map { Int($0.rounded()) }, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil, steps: nil)
        }
        let workoutsWritten = try await store.upsertWorkouts(workouts, deviceId: deviceId)

        // Import test mode: emit the stage/reject/day-delta trace only when a non-nil `trace` is passed.
        if let trace {
            let daysMapped = Set(daily.map { $0.day }).count
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: .appleHealth, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "appleDaily", rowsIn: appleRows.count, rowsOut: appleWritten),
                ImportTrace.stageLine(category: "dailyMetric", rowsIn: dm.count, rowsOut: dmWritten),
                ImportTrace.stageLine(category: "workouts", rowsIn: workouts.count, rowsOut: workoutsWritten),
                // Tolerant import: skippedSpans counts sanitizer-scrubbed XML spans; the aggregator drops
                // nothing further.
                ImportTrace.rejectLine(droppedRows: 0, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "appleDaily", daysMapped: daysMapped, daysPersisted: appleWritten),
            ]
            trace(lines)
        }

        return result.summary
    }
}
