import Foundation
import GRDB

public struct SourcedMetricPoint: Sendable {
    public let deviceId: String
    public let point: MetricPoint
    public init(deviceId: String, point: MetricPoint) { self.deviceId = deviceId; self.point = point }
}

/// Provenance for one persisted Zoop-computed score. `sourceId` normally names the input provider;
/// `vo2max_est` uses the estimator id because the method is the provenance for that series.
/// Natural key: (computed device namespace, day, metric key).
public struct ScoreInputProvenanceRow: Equatable, Codable, Sendable {
    public let day: String
    public let key: String
    public let sourceId: String

    public init(day: String, key: String, sourceId: String) {
        self.day = day
        self.key = key
        self.sourceId = sourceId
    }
}

/// Estimator identity persisted beside a `vo2max_est` point in `ScoreInputProvenanceRow.sourceId`.
/// Points without a row stay explicitly unknown: the method must not be inferred from the current
/// profile, since a waist measurement may have changed since scoring.
public enum Vo2MaxEstimator: String, Codable, Sendable {
    case nes
    case uth

    public static func forWaistCm(_ waistCm: Double) -> Self { waistCm > 0 ? .nes : .uth }
}

extension WhoopStore {
    /// Persists computed daily/series scores and their input provenance in one SQLite transaction.
    /// Daily provenance in the scoring window is replaced so attribution never goes stale; independently
    /// owned weekly VO₂max method tags survive. A write failure rolls back both scores and metadata.
    public func persistComputedScores(
        dailyMetrics: [DailyMetric],
        metricPoints: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
        deviceId: String,
        from: String,
        to: String,
        replaceMetricKeys: [String] = [],
        additionalMetricPoints: [SourcedMetricPoint] = [],
        replaceMetricSourceIds: [String] = []
    ) async throws {
        // An empty scoring pass must not rewrite the window: with no daily rows the provenance wide-delete
        // below would blank attribution after a degenerate pass (e.g. a transient read during an offload
        // storm). A real pass always carries the days it scored. Mirrors the Android empty guard.
        guard !dailyMetrics.isEmpty else { return }
        try syncWrite { db in
            _ = try Self.upsertDailyMetrics(dailyMetrics, deviceId: deviceId, in: db)
            for source in Set(replaceMetricSourceIds + [deviceId]) {
                for key in replaceMetricKeys {
                    try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?",
                                   arguments: [source, key, from, to])
                }
            }
            _ = try Self.upsertMetricSeries(metricPoints, deviceId: deviceId, in: db)
            for group in Dictionary(grouping: additionalMetricPoints, by: \.deviceId) {
                _ = try Self.upsertMetricSeries(group.value.map(\.point), deviceId: group.key, in: db)
            }

            // Weekly VO₂max provenance is owned by `persistMetricSeriesWithProvenance`; preserve it or every
            // 21-day re-score erases the prior two Saturdays' method tags while their metricSeries values stay.
            try db.execute(sql: """
                DELETE FROM scoreInputProvenance
                WHERE deviceId = ? AND day >= ? AND day <= ? AND key != 'vo2max_est'
                """, arguments: [deviceId, from, to])
            for row in provenance {
                try db.execute(sql: """
                    INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day,key) DO UPDATE SET sourceId = excluded.sourceId
                    """, arguments: [deviceId, row.day, row.key, row.sourceId])
            }
        }
    }

    /// Persists a metric-series batch and its specialized provenance in one SQLite transaction, so a
    /// weekly VO₂max method label never describes an older or newer value after a partial write.
    public func persistMetricSeriesWithProvenance(
        points: [MetricPoint],
        provenance: [ScoreInputProvenanceRow],
        deviceId: String
    ) async throws {
        try syncWrite { db in
            _ = try Self.upsertMetricSeries(points, deviceId: deviceId, in: db)
            for row in provenance {
                try db.execute(sql: """
                    INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day,key) DO UPDATE SET sourceId = excluded.sourceId
                    """, arguments: [deviceId, row.day, row.key, row.sourceId])
            }
        }
    }

    /// Input source for one computed score. Missing means the score predates provenance storage or its
    /// attribution could not be persisted; callers omit the badge rather than guess.
    public func scoreInputSource(deviceId: String, day: String, key: String) async throws -> String? {
        try syncRead { db in
            try String.fetchOne(db, sql: """
                SELECT sourceId FROM scoreInputProvenance
                WHERE deviceId = ? AND day = ? AND key = ?
                """, arguments: [deviceId, day, key])
        }
    }
}
