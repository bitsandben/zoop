import Foundation
import WhoopStore

// MARK: - Menstrual cycle tracker storage
//
// A logged period start is one value-1 metricSeries point under the dedicated local source `noop-cycle`,
// kept separate from strap/import/computed ids so an import or re-analysis cannot overwrite user-entered
// history.
// Source id, key, value, local ISO day, ordering and real-delete semantics must match the Android store
// byte for byte. No schema change; nothing leaves the device.

enum CycleTrackingStore {
    static let sourceId = "noop-cycle"
    static let periodStartKey = "period_start"
    static let loggedValue = 1.0
    static let earliestDay = "0000-01-01"
    static let latestDay = "9999-12-31"
}

extension Repository {

    /// Logged period-start days, oldest first.
    func periodStarts(from: String = CycleTrackingStore.earliestDay,
                      to: String = CycleTrackingStore.latestDay) async -> [String] {
        guard let store = await storeHandle() else { return [] }
        let rows = (try? await store.metricSeries(deviceId: CycleTrackingStore.sourceId,
                                                  key: CycleTrackingStore.periodStartKey,
                                                  from: from, to: to)) ?? []
        return rows.filter { $0.value >= CycleTrackingStore.loggedValue }.map(\.day)
    }

    /// Logs (idempotently) one local calendar day as cycle day 1.
    func logPeriodStart(day: String) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: day, key: CycleTrackingStore.periodStartKey,
                         value: CycleTrackingStore.loggedValue)],
            deviceId: CycleTrackingStore.sourceId)
        noteCycleTrackingChanged()
    }

    /// Physically deletes one logged start (not a sentinel marker).
    func deletePeriodStart(day: String) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteMetricSeriesPoint(deviceId: CycleTrackingStore.sourceId,
                                                      day: day,
                                                      key: CycleTrackingStore.periodStartKey)
        noteCycleTrackingChanged()
    }

    /// Deletes every logged start after explicit user confirmation.
    func deleteAllPeriodStarts() async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.deleteMetricSeries(deviceId: CycleTrackingStore.sourceId,
                                                 key: CycleTrackingStore.periodStartKey)
        noteCycleTrackingChanged()
    }
}
