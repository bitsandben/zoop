import Foundation
import WhoopStore

// MARK: - Apple Watch as a first-class device
// Registers the Apple Watch in the shared `DeviceRegistry`, feeding the `apple-health` source.
// Capabilities are trimmed to metrics that have actually arrived from HealthKit, so older watches never
// claim a sensor (skin temp, SpO2) they have not produced.
// The live HealthKit authorization is supplied by the iOS bridge so this stays unit-testable without HealthKit.
enum AppleWatchDevice {

    /// Registry id and sample `deviceId`; matches `Repository.appleHealthSource`.
    static let deviceId = Repository.appleHealthSource   // "apple-health"

    /// Lookback for deciding the watch is genuinely in use (a months-old one-off export should not count).
    static let recentWindowDays = 14

    /// Capabilities the adapter may claim, before trimming to what the data shows.
    static let candidateCapabilities: Set<Metric> = [.hr, .hrv, .sleep, .steps, .spo2, .skinTemp]

    // MARK: - Pure capability derivation (testable, no HealthKit, no store)

    /// Metrics with any data across the supplied recent rows; a metric is claimed only when at least one
    /// row carries a value.
    /// .hr: restingHr or avgHr/maxHr; .hrv: avgHrv; .sleep: totalSleepMin; .steps: steps; .spo2: spo2Pct
    /// (absent on newest US units); .skinTemp: skinTempDevC (Series 8+).
    static func capabilities(daily: [DailyMetric], apple: [AppleDaily]) -> Set<Metric> {
        var caps: Set<Metric> = []
        if daily.contains(where: { $0.restingHr != nil })
            || apple.contains(where: { $0.avgHr != nil || $0.maxHr != nil }) { caps.insert(.hr) }
        if daily.contains(where: { $0.avgHrv != nil }) { caps.insert(.hrv) }
        if daily.contains(where: { ($0.totalSleepMin ?? 0) > 0 }) { caps.insert(.sleep) }
        if daily.contains(where: { ($0.steps ?? 0) > 0 })
            || apple.contains(where: { ($0.steps ?? 0) > 0 }) { caps.insert(.steps) }
        if daily.contains(where: { $0.spo2Pct != nil }) { caps.insert(.spo2) }
        if daily.contains(where: { $0.skinTempDevC != nil }) { caps.insert(.skinTemp) }
        return caps.intersection(candidateCapabilities)
    }

    /// Builds the Apple Watch `PairedDevice`, or nil when HealthKit is unauthorized or no recent row
    /// carries a usable metric.
    /// `now` and `addedAt` are injectable for tests.
    static func device(daily: [DailyMetric], apple: [AppleDaily], authorized: Bool,
                       existing: PairedDevice? = nil, now: Date = Date()) -> PairedDevice? {
        guard authorized else { return nil }
        let caps = capabilities(daily: daily, apple: apple)
        guard !caps.isEmpty else { return nil }

        let ts = Int(now.timeIntervalSince1970)
        return PairedDevice(
            id: deviceId,
            brand: "Apple",
            model: "Apple Watch",
            // Keeps a user-set nickname and existing pairing date; only capabilities, status and last-seen move.
            nickname: existing?.nickname,
            peripheralId: nil,                 // HealthKit source, not a BLE peripheral
            sourceKind: .liveAppleWatch,
            capabilities: caps,
            status: existing?.status ?? .paired,
            addedAt: existing?.addedAt ?? ts,
            lastSeenAt: ts)
    }

    /// Apple Health becomes the active source only when the active one is the migration-seeded WHOOP row
    /// with no strap and no recent data, so a real strap, Oura or user-chosen source is never displaced.
    static func shouldAutoActivate(current: PairedDevice?, currentHasRecentData: Bool) -> Bool {
        guard let current else { return true }
        return current.id == Repository.whoopSource
            && current.status == .active
            && current.sourceKind == .liveBLE
            && current.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            && current.model.caseInsensitiveCompare("WHOOP") == .orderedSame
            && current.peripheralId == nil
            && !currentHasRecentData
    }

    /// Calendar window shared by the registry and the active-source recency check.
    static func recentDayRange(now: Date = Date()) -> (from: String, to: String) {
        let fromDate = Calendar.current.date(byAdding: .day, value: -recentWindowDays, to: now) ?? now
        return (dayString(fromDate), dayString(now))
    }

    // MARK: - Registration (live; iOS supplies `authorized` from HealthKitBridge)

    /// Upserts the Apple Watch into the registry when HealthKit is authorized and recent apple-health data
    /// exists; otherwise a no-op.
    /// `authorized` comes from the iOS `HealthKitBridge`; macOS callers never pass `true`.
    @MainActor
    static func registerIfAuthorized(registry: DeviceRegistry, store: WhoopStore,
                                     authorized: Bool, now: Date = Date()) async {
        guard authorized else { return }
        let range = recentDayRange(now: now)

        let daily = (try? await store.dailyMetrics(deviceId: deviceId, from: range.from, to: range.to)) ?? []
        let apple = (try? await store.appleDaily(deviceId: deviceId, from: range.from, to: range.to)) ?? []

        let existing = registry.devices.first(where: { $0.id == deviceId })
        guard let device = device(daily: daily, apple: apple, authorized: authorized,
                                  existing: existing, now: now) else { return }
        registry.add(device)
    }

    // MARK: - Day helpers

    /// Local civil day, matching `HealthKitBridge.dayString` so the window lines up with stored keys.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
