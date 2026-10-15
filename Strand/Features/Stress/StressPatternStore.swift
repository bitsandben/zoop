import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - StressPatternStore (one typical-day read, shared)
//
// The hourly stress of the last 14 full days, 07:00–23:00, scored the way the Stress screen scores a
// day. The Stress screen's "Patterns" curve, the Insights stress-timing card and the morning coach all
// read it from here, so they agree, and the stream walk runs at most once per local day however many
// of them ask (a refresh fires on every sync).

@MainActor
final class StressPatternStore {
    static let shared = StressPatternStore()

    static let days = 14
    static let firstHour = 7
    static let hoursPerDay = 16

    private var cache: (day: String, value: StressPatterns.TimeOfDay?)?
    private var inFlight: (day: String, task: Task<StressPatterns.TimeOfDay?, Never>)?

    /// The typical day, or nil when the last 14 days carry too little.
    func timeOfDay(repo: Repository) async -> StressPatterns.TimeOfDay? {
        let today = Repository.localDayKey(Date())
        if let cache, cache.day == today { return cache.value }
        if let inFlight, inFlight.day == today { return await inFlight.task.value }
        let task = Task { await Self.read(repo: repo) }
        inFlight = (today, task)
        let value = await task.value
        cache = (today, value)
        if inFlight?.day == today { inFlight = nil }
        return value
    }

    /// The peak and calmest hour, when the typical day has a clear one.
    func timing(repo: Repository) async -> BodyInsights.StressTiming? {
        await timeOfDay(repo: repo)?.timing
    }

    private static func read(repo: Repository) async -> StressPatterns.TimeOfDay? {
        var perDay: [[BodyInsights.HourLevel]] = []
        for date in pastDays(days) {
            let from = Int(date.timeIntervalSince1970) + firstHour * 3600
            let result = await analyze(repo: repo, from: from, to: from + hoursPerDay * 3600, date: date,
                                       minSamples: DaytimeStress.minHourHRSamples * 6)
            let levels = result?.hours.compactMap { h in h.level.map { BodyInsights.HourLevel(hour: h.hour, level: $0) } }
            if let levels, !levels.isEmpty { perDay.append(levels) }
        }
        return StressPatterns.timeOfDay(days: perDay)
    }

    /// One window of banked HR, R-R and motion scored day-relative, or nil under `minSamples` HR samples.
    static func analyze(repo: Repository, from: Int, to: Int, date: Date,
                        minSamples: Int) async -> DaytimeStress.Result? {
        let hr = await repo.hrSamples(from: from, to: to, limit: 80_000)
        guard hr.count >= minSamples else { return nil }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 120_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 120_000)
        let tz = TimeZone.current.secondsFromGMT(for: date)
        return await runUnescalated {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz,
                                  mode: .dayRelative, includeTimeline: false)
        }
    }

    /// Start of each of the last `n` full days, newest first.
    static func pastDays(_ n: Int) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (1...n).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }
}
