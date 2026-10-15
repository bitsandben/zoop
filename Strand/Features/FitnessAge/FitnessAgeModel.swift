#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - FitnessAgeModel
//
// Everything the Fitness Age screen shows, resolved in one place: the stored weekly rows, one readout
// per factor, the VO₂max line and the lever. The views render these values and hold no logic.

/// The single change the model says would lower the fitness age most.
struct FitnessLeverAdvice: Equatable {
    let title: LocalizedStringResource
    let text: LocalizedStringResource
}

@MainActor
final class FitnessAgeModel: ObservableObject {
    @Published private(set) var snapshot = FitnessAgeSnapshot()
    @Published private(set) var factors: [FitnessFactorItem] = []
    @Published private(set) var vo2Line: FitnessSeries = []
    @Published private(set) var lever: FitnessLeverAdvice?
    @Published private(set) var loaded = false

    /// Days of VO₂max shown on its line. Long enough to see a training block move it.
    static let vo2LineDays = 180

    func reload(repo: Repository, age: Int, sex: String) async {
        let snap = await FitnessAgeSnapshot.load(repo: repo)
        let series = await Self.dailySeries(repo: repo, snapshot: snap)
        snapshot = snap
        factors = FitnessAgeFactorBuilder.items(.init(age: age, sex: sex, snapshot: snap, series: series, now: Date()))
        vo2Line = await Self.vo2Series(repo: repo, measured: snap.vo2IsMeasured)
        lever = Self.advice(snap.engineInputs(age: age, sex: sex))
        loaded = true
    }

    /// True when VO₂max is missing from the breakdown and a profile field or Apple Health could add it.
    var missingVO2: Bool { snapshot.contributions[.vo2max] == nil }

    // MARK: Series

    /// The last 60 days of each factor's underlying daily signal, 7-day averaged, for the sparklines and
    /// trend words. Averaging shows the drift the 30-day baselines follow rather than night-to-night
    /// noise, and keeps a part-day reading from spiking the end of the line.
    private static func dailySeries(repo: Repository, snapshot: FitnessAgeSnapshot) async
        -> [FitnessAgeFactor: FitnessSeries] {
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-60 * 86_400))
        let days = repo.days.filter { $0.day >= cutoff }.sorted { $0.day < $1.day }
        func daily(_ pick: (DailyMetric) -> Double?) -> FitnessSeries {
            days.compactMap { d in pick(d).map { (day: d.day, value: $0) } }
        }
        var out: [FitnessAgeFactor: FitnessSeries] = [:]
        out[.restingHR] = daily { $0.restingHr.map(Double.init) }
        out[.hrv] = daily { $0.avgHrv }
        out[.activity] = daily { $0.strain }
        out[.sleep] = daily { $0.totalSleepMin.map { $0 / 60 } }
        out[.vo2max] = await vo2Series(repo: repo, measured: snapshot.vo2IsMeasured, days: 60)
        let bodyKey = snapshot.inputs[FitnessAgeKeys.bodyFat] != nil ? "body_fat" : "weight"
        out[.body] = await repo.exploreSeries(key: bodyKey, source: "apple-health", days: 60)
        return out.mapValues(rollingMean)
    }

    /// Measured VO₂max comes from Apple Health, the waist-based estimate from the strap's own pass.
    static func vo2Series(repo: Repository, measured: Bool, days: Int = vo2LineDays) async -> FitnessSeries {
        await repo.exploreSeries(key: measured ? "vo2max" : "vo2max_est",
                                 source: measured ? "apple-health" : "my-whoop", days: days)
    }

    static func rollingMean(_ s: FitnessSeries) -> FitnessSeries {
        s.indices.map { i in
            let w = s[max(0, i - 6)...i]
            return (day: s[i].day, value: w.map(\.value).reduce(0, +) / Double(w.count))
        }
    }

    // MARK: Lever

    private static func advice(_ inputs: FitnessAgeInputs?) -> FitnessLeverAdvice? {
        guard let inputs, let top = FitnessAgeLevers.rank(inputs).first else { return nil }
        let years = fitnessOneDecimal(top.yearsSaved)
        let n = { (v: Double, digits: Int) in v.formatted(.number.precision(.fractionLength(digits))) }
        switch top.kind {
        case .aerobicFitness:
            return .init(title: FitnessAgeStrings.leverAerobic,
                         text: FitnessAgeStrings.leverAerobicText("\(n(top.step, 0)) ml/kg/min", years))
        case .restingHeartRate:
            return .init(title: FitnessAgeStrings.leverRHR,
                         text: FitnessAgeStrings.leverRHRText("\(n(top.step, 0)) bpm", years))
        case .activity:
            return .init(title: FitnessAgeStrings.leverActivity,
                         text: FitnessAgeStrings.leverActivityText(n(top.step, 0), years))
        case .sleepRegularity:
            return .init(title: FitnessAgeStrings.leverSleep,
                         text: FitnessAgeStrings.leverSleepText("\(n(top.step * 100, 0)) %", years))
        case .bodyComposition:
            let unit = inputs.bodyFatPct.map { $0 > 0 } == true ? " %" : " BMI"
            return .init(title: FitnessAgeStrings.leverBody,
                         text: FitnessAgeStrings.leverBodyText(n(top.step, 0) + unit, years))
        }
    }
}
#endif
