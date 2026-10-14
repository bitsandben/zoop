import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - After the workout
//
// How the body behaved after the session: the first minutes (heart-rate recovery against recent
// sessions), the next hours (time back near resting, afterburn, the 3 h curve) and the next morning
// (HRV, resting HR, Charge against the 30-day average), then the sport's recovery-cost pattern when the
// engine has one. Rows without data are hidden.

extension WorkoutDetailView {

    @ViewBuilder var afterWorkoutCard: some View {
        if let after = model.afterWorkout {
            ContentCard("After the workout") {
                if after.hasAnything {
                    afterWorkoutContent(after)
                } else {
                    Text("Fills in over the hours after your workout.")
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cost = model.recoveryCost {
                    Text(cost)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func afterWorkoutContent(_ a: PostWorkoutRecovery.Result) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if let verdict = a.verdict {
                Text(verdictLabel(verdict))
                    .font(ZoopType.headline)
                    .foregroundStyle(verdictTint(verdict))
            }
            if let h1 = a.hrr1 {
                afterRow(String(localized: "Drop after 1 min"), String(localized: "\(h1) bpm"),
                         tint: h1 >= 0 ? StrandPalette.textPrimary : StrandPalette.statusWarning)
            }
            if let h2 = a.hrr2 {
                afterRow(String(localized: "Drop after 2 min"), String(localized: "\(h2) bpm"),
                         tint: h2 >= 0 ? StrandPalette.textPrimary : StrandPalette.statusWarning)
            }
            if let trend = model.afterWorkoutTrend {
                Text(trendLabel(trend))
                    .font(ZoopType.caption)
                    .foregroundStyle(trendTint(trend))
            }
            if let minutes = a.minutesToNearResting {
                afterRow(String(localized: "Back near resting"), format.duration(seconds: Double(max(minutes, 1)) * 60),
                         tint: StrandPalette.textPrimary)
            } else if a.verdict == .slow, a.hrr1 == nil {
                afterRow(String(localized: "Back near resting"), String(localized: "Not within 3 h"),
                         tint: StrandPalette.statusWarning)
            }
            if let delta = a.afterburnDelta {
                afterRow(String(localized: "Afterburn (1–3 h)"),
                         String(localized: "\(signed(delta)) bpm over resting"),
                         tint: delta > 10 ? StrandPalette.statusWarning : StrandPalette.textPrimary)
            }
            if a.curve.count >= PostWorkoutRecovery.minimumCurvePoints {
                afterCurve(a).padding(.top, ZoopSpacing.xs)
            }
            if let morning = a.morning {
                Divider().overlay(StrandPalette.hairline)
                Text("Next morning").font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                if let hrv = morning.hrv {
                    afterRow(String(localized: "HRV"),
                             String(localized: "\(Int(hrv.value.rounded())) ms (\(signed(hrv.delta)))"),
                             tint: deltaTint(hrv.delta, goodWhenHigher: true, neutralBand: 3))
                }
                if let rhr = morning.restingHr {
                    afterRow(String(localized: "Resting HR"),
                             String(localized: "\(Int(rhr.value.rounded())) bpm (\(signed(rhr.delta)))"),
                             tint: deltaTint(rhr.delta, goodWhenHigher: false, neutralBand: 2))
                }
                if let charge = morning.recovery {
                    afterRow(String(localized: "Charge"),
                             String(localized: "\(Int(charge.value.rounded()))% (\(signed(charge.delta)))"),
                             tint: deltaTint(charge.delta, goodWhenHigher: true, neutralBand: 5))
                }
                Text("Compared with your 30-day average.")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// HR over the three hours after the end, with the resting baseline as a dashed reference line.
    private func afterCurve(_ a: PostWorkoutRecovery.Result) -> some View {
        let values = a.curve.map(\.bpm) + (a.restingBaseline.map { [$0] } ?? [])
        let low = max(0, (values.min() ?? 50) - 5)
        let high = (values.max() ?? 150) + 5
        let endTs = row.endTs
        func date(_ minute: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(endTs + minute * 60)) }
        return Chart {
            ForEach(a.curve, id: \.minute) { p in
                LineMark(x: .value("Time", date(p.minute)), y: .value("Heart rate", p.bpm))
                    .foregroundStyle(StrandPalette.metricRose)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let rest = a.restingBaseline {
                RuleMark(y: .value("Resting HR", rest)).zoopReferenceRule()
            }
        }
        .chartXScale(domain: date(0)...date(PostWorkoutRecovery.windowMinutes))
        .chartYScale(domain: low...high)
        .zoopYAxis { ZoopNumber.decimal($0, digits: 0) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Heart rate over the 3 hours after the workout"))
    }

    private func afterRow(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.s)
            Text(value)
                .font(ZoopType.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private func verdictLabel(_ v: PostWorkoutRecovery.Verdict) -> String {
        switch v {
        case .fast: return String(localized: "Fast recovery")
        case .normal: return String(localized: "Normal recovery")
        case .slow: return String(localized: "Slow recovery")
        }
    }

    private func verdictTint(_ v: PostWorkoutRecovery.Verdict) -> Color {
        switch v {
        case .fast: return StrandPalette.statusPositive
        case .normal: return StrandPalette.textPrimary
        case .slow: return StrandPalette.statusWarning
        }
    }

    private func trendLabel(_ t: PostWorkoutRecovery.Trend) -> String {
        let delta = signed(Double(t.delta))
        switch t.kind {
        case .faster: return String(localized: "Faster than your usual (\(delta) bpm)")
        case .slower: return String(localized: "Slower than your usual (\(delta) bpm)")
        case .usual: return String(localized: "In line with your usual")
        }
    }

    private func trendTint(_ t: PostWorkoutRecovery.Trend) -> Color {
        switch t.kind {
        case .faster: return StrandPalette.statusPositive
        case .usual: return StrandPalette.textSecondary
        case .slower: return StrandPalette.statusWarning
        }
    }

    /// Positive tint when the morning moved the good way by more than `neutralBand`, warning the other way.
    private func deltaTint(_ delta: Double, goodWhenHigher: Bool, neutralBand: Double) -> Color {
        guard abs(delta) > neutralBand else { return StrandPalette.textPrimary }
        return (delta > 0) == goodWhenHigher ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    /// A rounded whole number with an explicit sign ("+4", "-3", "0").
    private func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : (n < 0 ? "\u{2212}\(-n)" : "0")
    }
}
