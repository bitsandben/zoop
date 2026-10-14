import XCTest
@testable import StrandAnalytics

final class AnalyticsEngineRestTraceContractTests: XCTestCase {
    private let day = "2025-06-10"

    private func analyze(stage: String, efficiency: Double) -> (AnalyticsEngine.DayResult, [String]) {
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3_600
        let end = start + 1_800
        let provided = SleepSession(
            start: start,
            end: end,
            efficiency: efficiency,
            stages: [StageSegment(start: start, end: end, stage: stage)],
            restingHR: nil,
            avgHRV: nil
        )
        var lines: [String] = []
        let result = AnalyticsEngine.analyzeDay(
            day: day,
            profile: UserProfile(),
            providedSleep: [provided],
            traceSink: { lines.append($0) }
        )
        return (result, lines)
    }

    func testWakeOnlySessionOmitsRestScoreAndRestTrace() {
        let result = analyze(stage: "wake", efficiency: 0.0)
        XCTAssertNil(result.0.restScore)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [])
        XCTAssertTrue(result.1.contains(
            "sleep-motion day=2025-06-10 grav=0 hr=0 sparse=false stager=V1 family=whoop5"
        ), "non-Rest diagnostics must remain available when Rest is absent")
    }

    func testPositiveSleepKeepsExactRestTrace() {
        let result = analyze(stage: "light", efficiency: 1.0)
        // Rest recipe (Zoop 2026-10): duration (0.5 h / 8 h)^1.5, mapped efficiency, and no
        // consistency signal → the term is omitted (consist=-1) and the weights renormalised.
        // (0.45·0.015625 + 0.2·1 + 0.2·0) / 0.85 = 24.36.
        XCTAssertEqual(result.0.restScore, 24.36)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [
            "rest composite=24.36 dur=0.02*wDur=0.45 eff=1.0*wEff=0.2 "
                + "restor=0.0*wRestor=0.2 deepFactor=0.5 consist=-1.0*wConsist=0.15 "
                + "group=1 groupInBedMin=30",
        ])
    }
}
