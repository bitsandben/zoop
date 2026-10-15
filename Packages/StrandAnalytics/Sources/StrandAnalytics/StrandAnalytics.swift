import Foundation

/// On-device analytics for Zoop (HRV, recovery, strain, sleep, workouts). All entry points are pure,
/// deterministic functions with no DB access:
///   - `HRZones`: HR-max + 5 zones from age; time-in-zone.
///   - `HRVAnalyzer`: RMSSD / SDNN with range + Malik ectopic filtering.
///   - `Baselines`: Winsorized-EWMA + trailing-window personal baselines.
///   - `RecoveryScorer`: resting HR + transparent 0-100 recovery composite.
///   - `StrainScorer`: Edwards/Banister TRIMP to logarithmic strain.
///   - `SleepStager`: sleep/wake detection + APPROXIMATE 4-class staging.
///   - `WorkoutDetector`: elevated-HR workout detection + calories.
///   - `AnalyticsEngine`: orchestrator producing `DailyMetric` + sleep-session results.
public enum StrandAnalytics {
    public static let version = "0.1.0"
}
