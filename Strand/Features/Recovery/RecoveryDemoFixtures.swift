#if DEBUG
import SwiftUI
import StrandAnalytics
import WhoopStore

// DEBUG-only: renders `RecoveryContentView` from synthetic nights so every state can be screenshotted
// without a strap (`--demo-screen recovery` / `recoverycalibrating`).

@MainActor enum RecoveryDemoFixtures {

    static func content(nights: Int) -> RecoveryContent {
        let todayKey = Repository.logicalDayKey(Date())
        let cal = Calendar.current
        let days: [DailyMetric] = (0..<nights).map { offset in
            let date = cal.date(byAdding: .day, value: -(nights - 1 - offset), to: Date()) ?? Date()
            let key = Repository.localDayKey(date)
            let wave = sin(Double(offset) * 0.7)
            let last = offset == nights - 1
            return DailyMetric(
                day: key, totalSleepMin: last ? 441 : 420 + 30 * wave, efficiency: 0.9, deepMin: 80, remMin: 100,
                lightMin: 240, disturbances: 2, restingHr: last ? 51 : Int(55 + 3 * wave),
                avgHrv: last ? 74 : 60 + 8 * wave, recovery: nights >= 4 ? (last ? 78 : 62 + 14 * wave) : nil,
                strain: 30 + 10 * wave, exerciseCount: 1, skinTempDevC: last ? 0.1 : 0.1 * wave,
                respRateBpm: last ? 14.9 : 14.2 + 0.3 * wave)
        }
        func state(_ base: Double, _ spread: Double) -> BaselineState {
            BaselineState(baseline: base, spread: spread, nValid: nights, nightsSinceUpdate: 0,
                          status: nights >= Baselines.minNightsTrust ? .trusted
                              : (nights >= Baselines.minNightsSeed ? .provisional : .calibrating))
        }
        let empty = ChargeBaselines.History(dayKeys: [], values: [], seededByImport: false,
                                            ownValidNights: nights, importedNights: 0)
        let baselines = ChargeBaselines.Resolved(
            hrvHistory: empty, restingHRHistory: empty, respHistory: empty,
            hrv: state(60, 5), restingHR: state(55, 2), resp: state(14.2, 0.3))
        return RecoveryContentBuilder.build(RecoveryInput(
            days: days, anchor: days.last, baselines: baselines, scoring: .standard, checkIns: [:],
            calibrationEnabled: false, calibration: .empty, now: Date(), todayKey: todayKey))
    }
}

struct RecoveryDemoHost: View {
    let nights: Int
    /// Below 1 lays the screen out taller and shrinks it, so one screenshot shows the whole page.
    var scale: CGFloat = 1
    var body: some View {
        GeometryReader { proxy in
            NavigationStack { RecoveryContentView(content: RecoveryDemoFixtures.content(nights: nights)) }
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}
#endif
