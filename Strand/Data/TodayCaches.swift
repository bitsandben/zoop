import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// In-memory snapshot of everything `loadHistoryWide()` computes (~40 history-wide reads plus the
/// per-workout strap-HR derivation). Held on the long-lived `Repository`, keyed by the `refreshSeq` it
/// was built at, so a Today re-mount can restore it with in-memory assignments instead of re-running
/// the heavy query pass (#849). Consumed only while the seq still matches.
struct TodayHistoryWideCache {
    let sparks: [String: [Double]]
    let stepsEstByDay: [String: Int]
    let workouts: [WorkoutRow]
    let appleDays: [AppleDaily]
    let xiaomiDays: Int
    let xiaomiSleeps: Int
    let stressToday: Double?
    let fitnessAgeToday: Double?
    let vo2maxToday: Double?
    let vitalityToday: Double?
    // Hydration total/goal is intentionally absent (#989): mutations don't bump refreshSeq, so a cached
    // value could restore stale. TodayView re-reads hydration live on restore.
}

/// In-memory snapshot of everything `loadDayScoped()` computes for ONE viewed day (Rest score and spark,
/// provenance winners, 5-minute HR buckets, step class, live Effort, chart axis, sleep band). Held on
/// the long-lived `Repository`, keyed by (`refreshSeq`, viewed-day key), so a re-mount with unchanged
/// data skips the heavy `hrBuckets`/`hrSamples` reads (170k+ HR rows/day on a big library, #932).
/// Consumed only when BOTH the seq and the day key match, so another day's snapshot is never served.
struct TodayDayScopedCache {
    let restSpark: [Double]
    let restScore: Double?
    let provenanceByMetric: [String: String]
    let providerByMetric: [String: ScoreInputProvider]
    let hrPoints: [TrendPoint]
    let stepActivityClassToday: Int?
    let liveTodayStrain: Double?
    let hrAxis: ClosedRange<Date>
    let sleepToday: CachedSleepSession?
    /// When the snapshot was banked. Today hits are age-gated on this (`todayCacheMaxAge`): live banking
    /// does not bump `refreshSeq`, so an unbounded snapshot would drift behind the 1 Hz stream.
    let bankedAt: Date
}
