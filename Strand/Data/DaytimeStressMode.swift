import Foundation
import StrandAnalytics

/// Process-level memo of the resolved daytime-stress lens, keyed on the inputs that can change it.
/// The resolver folds the 30 days before today, so the answer is fixed for the local day unless a backfill
/// lands in that window; today's HR cannot move the key (#2535).
/// `inFlight` is shared because a MainActor method that awaits is reentrant, so a second caller would
/// otherwise start its own fold.
/// In memory only, never persisted or backed up; a miss is the full path. One slot: every caller resolves
/// for the same device and day.
@MainActor
final class StressLensCache {
    static let shared = StressLensCache()

    private var key: String?
    private var mode: DaytimeStress.ScoringMode?
    private var inFlight: (key: String, task: Task<DaytimeStress.ScoringMode, Never>)?

    /// The lens for `candidate`, folding via `fold` only if no stored or in-flight answer matches.
    func resolve(_ candidate: String,
                 fold: @escaping () async -> DaytimeStress.ScoringMode) async -> DaytimeStress.ScoringMode {
        if let mode, key == candidate { return mode }
        if let inFlight, inFlight.key == candidate { return await inFlight.task.value }
        let task = Task { @MainActor in await fold() }
        inFlight = (key: candidate, task: task)
        let resolved = await task.value
        if inFlight?.key == candidate { inFlight = nil }
        key = candidate
        mode = resolved
        return resolved
    }

    /// For tests, or to force a fold.
    func clear() {
        key = nil
        mode = nil
        inFlight = nil
    }
}

/// The foreground resolver for daytime-stress scoring, used by Stress detail and Today's Stress card. With
/// the personal lens off it returns immediately. Widget publishing deliberately does not opt in: a display
/// preference must not make a periodic publisher read 30 days of raw data.
enum DaytimeStressMode {
    private static let baselineHistoryDays = 30

    @MainActor
    static func selected(repo: Repository, startOfToday: Date,
                         calendar: Calendar = .current,
                         personalBaseline: Bool) async -> DaytimeStress.ScoringMode {
        guard personalBaseline else { return .dayRelative }

        // One fingerprint over the past-30-day span, then the memo. The span ends yesterday so today's HR
        // cannot invalidate it; anchored like each day window so a midnight clock shift cannot move it.
        let spanStart = calendar.date(byAdding: .day, value: -baselineHistoryDays, to: startOfToday)
            .map { calendar.startOfDay(for: $0) } ?? startOfToday
        let spanEnd = Int(calendar.startOfDay(for: startOfToday).timeIntervalSince1970) - 1
        let fingerprint = await repo.hrFingerprintUnion(from: Int(spanStart.timeIntervalSince1970), to: spanEnd)
        let cacheKey = "\(repo.deviceId)|\(Int(calendar.startOfDay(for: startOfToday).timeIntervalSince1970))"
            + "|\(TimeZone.current.identifier)|\(fingerprint)"
        return await StressLensCache.shared.resolve(cacheKey) {
            var aggregates: [(hr: Double?, rmssd: Double?)] = []
            aggregates.reserveCapacity(baselineHistoryDays)
            // Oldest to newest so the EWMA fold replays in order; reduce each day immediately rather than
            // retain 30 days of raw HR and R-R (#2107).
            for back in stride(from: baselineHistoryDays, through: 1, by: -1) {
                // Re-anchored: a day-add preserves time of day, so on a midnight DST-shift date every
                // window walked back runs 01:00 to 01:00. Keeps this equal to the Kotlin resolver, which
                // walks LocalDate.
                guard let rawStart = calendar.date(byAdding: .day, value: -back, to: startOfToday) else { continue }
                let dayStart = calendar.startOfDay(for: rawStart)
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                    .map({ calendar.startOfDay(for: $0) }) else { continue }
                let from = Int(dayStart.timeIntervalSince1970)
                let to = Int(dayEnd.timeIntervalSince1970) - 1
                let dayTz = TimeZone.current.secondsFromGMT(for: dayStart)
                let dayHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
                guard !dayHR.isEmpty else { continue }
                // The live baseline scores HR only while the RMSSD term is disabled, so skip historical R-R reads.
                let dayRR = DaytimeStress.daytimeRMSSDScoringEnabled
                    ? await repo.rrIntervals(from: from, to: to, limit: 200_000) : []
                aggregates.append(
                    DaytimeStress.dayDaytimeAggregate(hr: dayHR, rr: dayRR, tzOffsetSeconds: dayTz)
                )
            }
            return DaytimeStress.scoringModeFromAggregates(aggregates)
        }
    }
}
