import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Recovery calibration (Zoop)
//
// Morning check-ins ("how recovered do you feel?" 1–5 plus symptom toggles) and the personal Charge
// weighting learned from them (`RecoveryCalibration`, StrandAnalytics). Storage mirrors `MoodStore`: the
// answers live in the metric-series tall table under a DEDICATED source id, one row per key per local
// day, so imports can never clobber them and an edit is a plain overwrite. Fully offline; nothing exists
// until the wearer turns calibration on and answers.

/// How pass 2 of the re-score composes Charge: the personal sleep need, the (possibly calibrated)
/// weights and the reported check-ins. `.standard` is the uncalibrated recipe.
struct ChargeScoring: Codable, Sendable {
    var needHours: Double
    var weights: ChargeWeights
    var checkIns: [String: MorningCheckIn]

    static let standard = ChargeScoring(needHours: AnalyticsEngine.Rest.defaultNeedHours,
                                        weights: .standard, checkIns: [:])

    /// Charge's sleep term: asleep time ÷ personal need (see `AnalyticsEngine.Rest.sufficiency`).
    func sleepTerm(_ daily: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.sufficiency(daily: daily, needHours: needHours)
    }

    /// The day's reported symptom load, nil when there is no check-in.
    func symptomLoad(_ day: String) -> Double? {
        checkIns[day]?.symptomLoad
    }
}

enum RecoveryCalibrationStore {
    /// Dedicated source id for check-in rows (imports write under their own ids).
    static let deviceId = "zoop-checkin"

    static let feelingKey = "checkin_feeling"
    static let headacheKey = "checkin_headache"
    static let sorenessKey = "checkin_soreness"
    static let illKey = "checkin_ill"
    static let stressKey = "checkin_stress"
    static var allKeys: [String] { [feelingKey, headacheKey, sorenessKey, illKey, stressKey] }

    /// Whether the wearer turned calibration on (Settings or setup).
    static let enabledKey = "zoop.recoveryCalibration.enabled"
    /// The last fit, JSON-encoded `RecoveryCalibrationResult`, written by every re-score.
    static let resultKey = "zoop.recoveryCalibration.result"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The recipe the most recent re-score used, persisted so a screen that re-derives the Charge
    /// breakdown scores its rows with the same need, weights and symptoms as the stored headline, even
    /// when this launch has not re-scored yet. `.standard` before the first pass ever.
    @MainActor static var lastScoring: ChargeScoring = {
        guard let data = UserDefaults.standard.data(forKey: scoringKey),
              let s = try? JSONDecoder().decode(ChargeScoring.self, from: data) else { return .standard }
        return s
    }()
    static let scoringKey = "zoop.recoveryCalibration.lastScoring"

    /// The last fit, or `.empty` before the first re-score with calibration on.
    static var lastResult: RecoveryCalibrationResult {
        guard let data = UserDefaults.standard.data(forKey: resultKey),
              let r = try? JSONDecoder().decode(RecoveryCalibrationResult.self, from: data) else { return .empty }
        return r
    }

    /// Every stored check-in, keyed by local day.
    static func checkIns(store: WhoopStore, from: String = "0000-01-01",
                         to: String = "9999-12-31") async -> [String: MorningCheckIn] {
        func series(_ key: String) async -> [String: Double] {
            let pts = (try? await store.metricSeries(deviceId: deviceId, key: key, from: from, to: to)) ?? []
            return Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        }
        let feeling = await series(feelingKey)
        let headache = await series(headacheKey)
        let soreness = await series(sorenessKey)
        let ill = await series(illKey)
        let stress = await series(stressKey)
        var out: [String: MorningCheckIn] = [:]
        for (day, v) in feeling {
            out[day] = MorningCheckIn(feeling: Int(v.rounded()),
                                      headache: (headache[day] ?? 0) > 0.5,
                                      soreness: (soreness[day] ?? 0) > 0.5,
                                      ill: (ill[day] ?? 0) > 0.5,
                                      stress: (stress[day] ?? 0) > 0.5)
        }
        return out
    }

    /// The Charge recipe for one re-score pass. With calibration off this is the standard recipe on the
    /// personal sleep need. With it on, the check-ins are paired with the persisted nights, the personal
    /// weights are fitted and the fit is banked for the UI.
    static func scoring(store: WhoopStore, computedId: String,
                        baselines: AnalyticsEngine.ProfileBaselines,
                        needHours: Double) async -> ChargeScoring {
        var scoring = ChargeScoring.standard
        scoring.needHours = needHours
        defer {
            if let data = try? JSONEncoder().encode(scoring) { UserDefaults.standard.set(data, forKey: scoringKey) }
            Task { @MainActor [scoring] in lastScoring = scoring }
        }
        guard isEnabled else { return scoring }
        let checkIns = await checkIns(store: store)
        scoring.checkIns = checkIns
        guard let hrvBase = baselines.hrv, let first = checkIns.keys.min(), let last = checkIns.keys.max() else {
            save(.empty)
            return scoring
        }
        let nights = (try? await store.dailyMetrics(deviceId: computedId, from: first, to: last)) ?? []
        var samples: [CalibrationSample] = []
        for d in nights {
            guard let c = checkIns[d.day], let hrv = d.avgHrv, let rhr = d.restingHr else { continue }
            let z = RecoveryCalibration.termZScores(
                hrv: hrv, rhr: Double(rhr), resp: d.respRateBpm, hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR, respBaseline: baselines.resp,
                sleepPerf: scoring.sleepTerm(d), skinTempDev: d.skinTempDevC)
            guard !z.isEmpty else { continue }
            samples.append(CalibrationSample(day: d.day, feeling: Double(c.feeling), termZ: z))
        }
        let result = RecoveryCalibration.fit(samples)
        save(result)
        scoring.weights = result.weights
        return scoring
    }

    static func save(_ result: RecoveryCalibrationResult) {
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: resultKey)
        }
    }

    /// Forget every answer and the learned weights. Calibration stays on/off as it was.
    static func reset(store: WhoopStore) async {
        for key in allKeys { _ = try? await store.deleteMetricSeries(deviceId: deviceId, key: key) }
        UserDefaults.standard.removeObject(forKey: resultKey)
    }
}

// MARK: - Persistence (Repository extension)

extension Repository {

    /// The stored check-in for one local day, nil if not answered yet.
    func morningCheckIn(day: String) async -> MorningCheckIn? {
        guard let store = await storeHandle() else { return nil }
        return await RecoveryCalibrationStore.checkIns(store: store, from: day, to: day)[day]
    }

    /// Every stored check-in, keyed by local day.
    func morningCheckIns() async -> [String: MorningCheckIn] {
        guard let store = await storeHandle() else { return [:] }
        return await RecoveryCalibrationStore.checkIns(store: store)
    }

    /// Save (or overwrite) the day's check-in. One row per key per local day.
    func saveMorningCheckIn(day: String, _ c: MorningCheckIn) async {
        guard MorningCheckIn.scale.contains(c.feeling), let store = await storeHandle() else { return }
        let S = RecoveryCalibrationStore.self
        let rows = [
            MetricPoint(day: day, key: S.feelingKey, value: Double(c.feeling)),
            MetricPoint(day: day, key: S.headacheKey, value: c.headache ? 1 : 0),
            MetricPoint(day: day, key: S.sorenessKey, value: c.soreness ? 1 : 0),
            MetricPoint(day: day, key: S.illKey, value: c.ill ? 1 : 0),
            MetricPoint(day: day, key: S.stressKey, value: c.stress ? 1 : 0),
        ]
        _ = try? await store.upsertMetricSeries(rows, deviceId: S.deviceId)
    }

    /// Forget every check-in and the learned weights.
    func resetRecoveryCalibration() async {
        guard let store = await storeHandle() else { return }
        await RecoveryCalibrationStore.reset(store: store)
    }
}
