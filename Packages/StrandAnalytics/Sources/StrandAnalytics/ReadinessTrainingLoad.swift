import WhoopStore

public extension ReadinessEngine {
    /// Readiness plus descriptive long-horizon training-load state. CTL/ATL/TSB are deliberately outside the
    /// Readiness synthesis: they never change `readiness.level`, signals, confidence or any headline score.
    struct TrainingLoadAnalysis: Sendable, Equatable {
        public let readiness: Readiness
        public let trainingLoad: TrainingLoadEngine.Result

        public init(readiness: Readiness, trainingLoad: TrainingLoadEngine.Result) {
            self.readiness = readiness
            self.trainingLoad = trainingLoad
        }
    }

    /// Evaluates Readiness and CTL/ATL/TSB over the same history. `today` has `ReadinessEngine.evaluate` semantics:
    /// a missing target day yields insufficient Readiness and `trainingLoad.unavailableReason == .missingTargetDay`
    /// rather than an older row.
    static func evaluateWithTrainingLoad(
        days: [DailyMetric],
        today: String? = nil,
        trainingLoadConfiguration: TrainingLoadEngine.Configuration = .standard
    ) -> TrainingLoadAnalysis {
        let readiness = evaluate(days: days, today: today)
        let trainingDays = days.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        let trainingLoad = TrainingLoadEngine.evaluate(
            days: trainingDays,
            through: today,
            configuration: trainingLoadConfiguration
        )
        return TrainingLoadAnalysis(readiness: readiness, trainingLoad: trainingLoad)
    }
}
