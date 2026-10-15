import XCTest
@testable import StrandAnalytics

/// Pins `RecoveryScorer`'s exact output bits on a spread of representative inputs.
///
/// Recovery is the single resolver for the readiness fact, and users compare it day to day, so any
/// consolidation around it must leave every score bit-identical. The expected values were captured
/// from the scorer before the one-resolver refactor; a change here is a change to users' numbers and
/// needs its own validation, not a test update.
final class RecoveryIdentityPinTests: XCTestCase {

    /// Deterministic LCG so the synthetic history is identical on every platform and run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// One synthetic night: HRV, resting HR, respiration, Rest quality and skin-temp deviation that
    /// move together the way a fatigue/recovery cycle does, with a few missing values mixed in.
    private struct Night { let hrv: Double?; let rhr: Double; let resp: Double?; let sleep: Double?; let skin: Double? }

    private func history(nights: Int = 40, seed: UInt64 = 0x5EED) -> [Night] {
        var rng = LCG(state: seed)
        return (0..<nights).map { i in
            let load = sin(Double(i) / 4.0)                       // multi-day fatigue cycle
            let hrv = 55 - 9 * load + (rng.next() - 0.5) * 12
            let rhr = 54 + 3 * load + (rng.next() - 0.5) * 4
            let resp = 14.5 + 0.6 * load + (rng.next() - 0.5) * 0.8
            let sleep = 0.78 + (rng.next() - 0.5) * 0.25
            let skin = (rng.next() - 0.5) * 0.9
            return Night(hrv: i % 11 == 7 ? nil : hrv, rhr: rhr,
                         resp: i % 5 == 3 ? nil : resp,
                         sleep: i % 6 == 2 ? nil : sleep,
                         skin: i % 4 == 1 ? nil : skin)
        }
    }

    /// Scores every night against baselines folded from the nights before it — the shape the
    /// analytics pass uses — and returns the raw bit patterns (nil where the scorer declines).
    private func scoredHistoryBits() -> [UInt64?] {
        let nights = history()
        let hrvCfg = Baselines.metricCfg["hrv"]!
        let rhrCfg = Baselines.metricCfg["resting_hr"]!
        let respCfg = Baselines.metricCfg["resp"]!
        return nights.indices.map { i in
            let prior = nights[..<i]
            guard let hrv = nights[i].hrv else { return nil }
            let hrvB = Baselines.foldHistory(prior.map(\.hrv), cfg: hrvCfg)
            let rhrB = Baselines.foldHistory(prior.map { Optional($0.rhr) }, cfg: rhrCfg)
            let respB = Baselines.foldHistory(prior.map(\.resp), cfg: respCfg)
            return RecoveryScorer.recovery(hrv: hrv, rhr: nights[i].rhr, resp: nights[i].resp,
                                           hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
                                           sleepPerf: nights[i].sleep, skinTempDev: nights[i].skin)?
                .bitPattern
        }
    }

    /// The optional terms (recovery index, activity balance, symptoms, personal weights) on one
    /// fixed night, so each branch of the composite is pinned on its own.
    private func optionalTermBits() -> [UInt64?] {
        func b(_ mean: Double, _ sigma: Double, _ n: Int = 20) -> BaselineState {
            BaselineState(baseline: mean, spread: sigma / 1.253, nValid: n, nightsSinceUpdate: 0,
                          status: n >= 14 ? .trusted : (n >= Baselines.minNightsSeed ? .provisional : .calibrating))
        }
        let hrvB = b(52, 7), rhrB = b(55, 2.5), respB = b(14.8, 0.6), effortB = b(48, 12)
        let personal = ChargeWeights(hrv: 0.62, rhr: 0.15, sleep: 0.13, resp: 0.05, skinTemp: 0.05)
        let cases: [Double?] = [
            RecoveryScorer.recovery(hrv: 44, rhr: 58, resp: 15.4, hrvBaseline: hrvB, rhrBaseline: rhrB,
                                    respBaseline: respB, sleepPerf: 0.7),
            RecoveryScorer.recovery(hrv: 61, rhr: 52, resp: 14.2, hrvBaseline: hrvB, rhrBaseline: rhrB,
                                    respBaseline: respB, sleepPerf: 0.92, skinTempDev: -0.3,
                                    recoveryIndexSlope: -1.4),
            RecoveryScorer.recovery(hrv: 50, rhr: 56, resp: nil, hrvBaseline: hrvB, rhrBaseline: rhrB,
                                    respBaseline: respB, sleepPerf: 0.81, effortBaseline: effortB,
                                    priorDayEffort: 77),
            RecoveryScorer.recovery(hrv: 47, rhr: 57, resp: 15.0, hrvBaseline: hrvB, rhrBaseline: rhrB,
                                    respBaseline: respB, sleepPerf: 0.75, symptomLoad: 1.8),
            RecoveryScorer.recovery(hrv: 58, rhr: 53, resp: 14.6, hrvBaseline: hrvB, rhrBaseline: rhrB,
                                    respBaseline: respB, sleepPerf: 0.88, skinTempDev: 0.6,
                                    weights: personal),
            // Cold start: an unusable HRV baseline never scores.
            RecoveryScorer.recovery(hrv: 58, rhr: 53, resp: nil, hrvBaseline: b(52, 7, 2),
                                    rhrBaseline: rhrB, respBaseline: nil, sleepPerf: 0.88),
        ]
        return cases.map { $0?.bitPattern }
    }

    func testScoredHistoryIsBitIdentical() {
        XCTAssertEqual(scoredHistoryBits(), Self.expectedHistoryBits)
    }

    func testOptionalTermsAreBitIdentical() {
        XCTAssertEqual(optionalTermBits(), Self.expectedOptionalBits)
    }

    // Captured from RecoveryScorer before the WP-04 consolidation.
    static let expectedHistoryBits: [UInt64?] = [
        nil, nil, nil, nil,
        0x4036ab300c2e3e48, 0x403144c87c57c6fb, 0x40472fad6d60c615, nil,
        0x403d1707a7c0cb20, 0x404270c2a8e428ce, 0x405020487221b694, 0x404b86952c83d34e,
        0x4050b021f102edf3, 0x4056caf488fb4b75, 0x4053f41b88d541f7, 0x40533b4678737fa6,
        0x40573594f668c3e9, 0x405750c66fdaeff7, nil, 0x405781ed76d99b92,
        0x405841c2455516d6, 0x4054a749260ac25c, 0x40559fd9b337ff3a, 0x40519a7a394e2a51,
        0x404a230594d36f32, 0x4051c786e8dd8dbb, 0x403f2002aa9dce39, 0x4038285000ba4e86,
        0x403832f65e3abc40, nil, 0x402d025a0d718cb0, 0x4040ec1dc4470e52,
        0x4036c90f834e5b5a, 0x40454fee1cde9c77, 0x40498f7a5c9c022c, 0x404b8623c9aae180,
        0x4048ecb929b0a56a, 0x4050f1dba30a24b3, 0x4054183fbf0efff8, 0x405468250c44ac60,
    ]
    static let expectedOptionalBits: [UInt64?] = [
        0x40319cae171dee7b, 0x4056074aeff4568a, 0x4044763dec1b273f,
        0x403aa5a0aa216e40, 0x405406cddfd1393b, nil,
    ]
}
