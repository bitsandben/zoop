import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Recovery screen content
//
// Plain values the screen renders. `RecoveryContentBuilder` makes them from stored data; nothing here
// touches the repository, so each state (calibrating, provisional, solid, stale, empty) is unit-testable.

/// Everything the builder reads, gathered once by the view model so the builder stays pure.
struct RecoveryInput {
    var days: [DailyMetric]
    /// The row Home shows (`Repository.widgetAnchor`): today's scored night or the latest earlier one.
    var anchor: DailyMetric?
    var baselines: ChargeBaselines.Resolved?
    var scoring: ChargeScoring
    var checkIns: [String: MorningCheckIn]
    var calibrationEnabled: Bool
    var calibration: RecoveryCalibrationResult
    var now: Date
    /// Today's logical day key, from the app's one day-rollover rule.
    var todayKey: String
}

struct RecoveryContributor: Identifiable {
    enum Kind: String { case hrv, restingHR, sleep, respiration, skinTemperature }
    let kind: Kind
    let readout: MetricReadout
    let effect: MetricExplanation.Contributor.Effect
    let explanation: MetricExplanation
    var id: String { kind.rawValue }
}

struct RecoveryTrendDay: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct RecoveryForecastContent: Equatable {
    let low: Double
    let high: Double
    /// Sleep the estimate assumes: the user's own need.
    let sleepSeconds: Double
}

struct RecoveryTimelineStep: Identifiable {
    enum Status { case done, current, upcoming }
    let id: Int
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let status: Status
}

enum RecoveryPersonalisation: Equatable {
    case off
    case collecting(mornings: Int, needed: Int)
    /// `shift` is the term the check-ins moved furthest, nil when none moved by a visible amount.
    case learned(shift: Shift?)

    struct Shift: Equatable {
        let term: ChargeTerm
        /// Signed whole percent relative to the standard weight.
        let percent: Int
    }
}

struct RecoveryContent {
    enum State { case scored, calibrating, missingInputs }

    let state: State
    let hero: MetricReadout
    let heroExplanation: MetricExplanation
    let contributors: [RecoveryContributor]
    /// Up to 90 days, oldest first. Days without a score are absent, never zero.
    let trend: [RecoveryTrendDay]
    /// The personal range over the last 30 scored days, drawn as the band behind the bars.
    let typicalRange: ClosedRange<Double>?
    let forecast: RecoveryForecastContent?
    let timeline: [RecoveryTimelineStep]
    let personalisation: RecoveryPersonalisation
    /// Today's check-in answer (1...5) when calibration is on and one exists.
    let todayFeeling: Int?
}
