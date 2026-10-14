import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - StressModel (the daily level)
//
// The morning's once-a-day level from `DaytimeStress.daily`, the package's one stress resolver. Today's
// tile and the Stress screen both read it, so the number cannot differ between them. Everything the
// screen draws beyond this comes from `StressScreenModel`.

struct StressModel {
    let daily: DaytimeStress.Daily
    var score: Double { daily.level }
    var band: StressBand { StressBand(score: daily.level) }

    /// Nil only when no day carries a usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        guard let daily = DaytimeStress.daily(days: days, stored: stored) else { return nil }
        self.daily = daily
    }
}
