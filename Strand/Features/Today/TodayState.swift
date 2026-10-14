#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - What the Today screen shows for one day
//
// Written once per load by `TodayModel`; the views only read it. Every number is a `MetricReadout`.

struct TodayContent: Equatable {
    var dayKey: String
    var isToday: Bool

    // Rings, in the screen's order.
    var sleep: MetricReadout
    var recovery: MetricReadout
    var strain: MetricReadout
    /// Full scale of the strain ring (21 or 100, the user's Effort scale).
    var strainRingMax: Double
    /// Today's strain target on the ring, as fractions of the full scale.
    var strainTarget: ClosedRange<Double>?
    var strainTargetCaption: LocalizedStringResource?
    var synthesis: LocalizedStringResource?
    var greeting: LocalizedStringResource?

    var stress: MetricReadout
    var health: TodayHealthSummary
    /// Today only.
    var energy: MetricReadout?
    var checkIn: TodayCheckIn

    var moment: TodayMoment?
    var activities: [TodayActivity]
    var showsCycle: Bool

    var dashboard: [MetricReadout]
    var fitnessAge: MetricReadout
}

/// The vitals the Health monitor tile summarises, banded against the user's own ranges.
struct TodayHealthSummary: Equatable {
    struct Vital: Equatable, Identifiable {
        let id: String
        let name: String
        let inRange: Bool
    }
    let vitals: [Vital]
    var outsideCount: Int { vitals.filter { !$0.inRange }.count }
}

/// The morning check-in: an invite before calibration is on, then the daily question until answered.
enum TodayCheckIn: Equatable {
    case hidden, invite, ask
}

/// One card at the top of My Day that says what matters right now.
enum TodayMoment: Equatable {
    case breathe
    /// The night ahead: recommended bedtime (minute of day) and the armed alarm.
    case evening(bedtimeMinute: Int?, alarm: Date?)

    /// Stress level (0–3) from which an hour counts as high.
    static let highStress = DaytimeStress.highBandFloor
    /// The night ahead shows from this hour until the 04:00 rollover.
    static let eveningFromHour = 17

    enum Kind: Equatable { case breathe, evening }

    /// High stress right now (08:00–23:00) wins, else the evening. "Right now" means the current hour
    /// scores high AND the last ten minutes of heart rate still sit at or above that hour's mean, so one
    /// tense moment earlier in the hour does not keep the card up once the body has settled.
    static func pick(now: Date, hours: [DaytimeStress.HourPoint], recentHR: Double?,
                     calendar: Calendar = .current) -> Kind? {
        let h = calendar.component(.hour, from: now)
        let nowTs = Int(now.timeIntervalSince1970)
        if (8..<23).contains(h),
           let current = hours.last(where: { $0.startTs <= nowTs && nowTs - $0.startTs < 3600 }),
           let level = current.level, level >= highStress,
           let recent = recentHR, let hourMean = current.meanHR, recent >= hourMean {
            return .breathe
        }
        return (h >= eveningFromHour || h < 4) ? .evening : nil
    }
}

/// One entry in My Day's activity list.
struct TodayActivity: Identifiable, Equatable {
    enum Kind: Equatable { case sleep, nap, workout, detected }
    let kind: Kind
    let title: String
    let start: Int
    let end: Int
    var workout: WorkoutRow?
    var nap: CachedSleepSession?
    var detected: DetectedWorkout?
    var id: String { "\(kind)-\(start)" }
}
#endif
