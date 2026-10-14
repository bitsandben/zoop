import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Workouts fitness cards (Zoop, iOS Workouts tab)
//
// The pieces the iOS Workouts tab borrows from the Bevel-style fitness overview:
//
//  • `TrainingLoadGaugeRow`: Cardio and Muscular load as two semicircle gauges with the optimal band
//    (`TrainingLoadGauge`). On iOS it replaces the CTL/ATL `TrainingLoadCard` that sat on Trends.
//  • `CumulativeTotalCard`: a total with a cumulative step line ending in a dot.
//  • `StrengthSection`: this week's working sets and volume, plus the muscle-recovery grid (moved
//    here from the Lift Log so it is shown once).
//
// Kept out of `WorkoutsView.swift` so that screen's body stays inside the type-check budget.

/// Everything the Workouts tab shows about lifting, loaded once per refresh.
struct LiftFitnessSnapshot: Equatable {
    /// Nil when there is no lift session in the last 180 days: the muscular gauge then hides.
    var muscular: TrainingLoadGauge.Reading?
    var week: TrainingLoadGauge.StrengthWeek
    var recovery: [MuscleRecovery.Entry]
    /// (session end, working sets, volume kg) for the last 7 days, oldest first.
    var weekSessions: [WeekSession]
    /// A lift session ended within the last 14 days: gates the Strength section.
    var hasRecentLifts: Bool

    struct WeekSession: Equatable {
        let endTs: Int
        let sets: Int
        let volumeKg: Double
    }

    static let empty = LiftFitnessSnapshot(muscular: nil, week: .init(workingSets: 0, volumeKg: 0),
                                           recovery: [], weekSessions: [], hasRecentLifts: false)

    /// Read finished lift sessions (180 days) and the sets of the last 28 days.
    static func load(repo: Repository, now: Date = Date()) async -> LiftFitnessSnapshot {
        guard let store = await repo.storeHandle() else { return .empty }
        let nowTs = Int(now.timeIntervalSince1970)
        let sessions = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                       fromTs: nowTs - 180 * 86_400,
                                                       toTs: nowTs)) ?? [])
            .filter { $0.endTs != nil }
        guard let first = sessions.map(\.startTs).min() else { return .empty }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func daysAgo(_ ts: Int) -> Int {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            return cal.dateComponents([.day], from: d, to: today).day ?? 0
        }

        var liftDays: [TrainingLoadGauge.LiftDay] = []
        var recent: [MuscleRecovery.Session] = []
        var week: [WeekSession] = []
        let recoveryCutoff = nowTs - Int(MuscleRecovery.lookbackHours * 3600)
        for row in sessions {
            let end = row.endTs ?? row.startTs
            let ago = daysAgo(end)
            guard ago < TrainingLoadGauge.chronicWindowDays || end >= recoveryCutoff else { continue }
            let sets = (try? await store.liftSets(sessionId: row.id)) ?? []
            let day = TrainingLoadGauge.LiftDay(daysAgo: ago, sets: sets)
            liftDays.append(day)
            if end >= recoveryCutoff { recent.append(MuscleRecovery.Session(endTs: end, sets: sets)) }
            if ago >= 0 && ago < TrainingLoadGauge.acuteWindowDays {
                let w = TrainingLoadGauge.strengthWeek(sessions: [day])
                week.append(WeekSession(endTs: end, sets: w.workingSets, volumeKg: w.volumeKg))
            }
        }
        let latestEnd = sessions.compactMap(\.endTs).max() ?? 0
        return LiftFitnessSnapshot(
            muscular: TrainingLoadGauge.muscular(sessions: liftDays, historyDays: daysAgo(first) + 1),
            week: TrainingLoadGauge.strengthWeek(sessions: liftDays),
            recovery: MuscleRecovery.entries(sessions: recent, now: nowTs),
            weekSessions: week.sorted { $0.endTs < $1.endTs },
            hasRecentLifts: latestEnd >= nowTs - 14 * 86_400)
    }
}

// MARK: - Training load gauges

struct TrainingLoadGaugeRow: View {
    let cardio: TrainingLoadGauge.Reading
    let muscular: TrainingLoadGauge.Reading?
    let effortScale: EffortScale

    /// Cardio is modelled on the stored 0–100 Effort axis; the gauge shows the user's scale.
    private var cardioScaled: TrainingLoadGauge.Reading {
        let f = UnitFormatter.effortValue(1, scale: effortScale)
        let c = cardio
        return .init(state: c.state, acute: c.acute.map { $0 * f }, chronic: c.chronic.map { $0 * f },
                     optimalLow: c.optimalLow.map { $0 * f }, optimalHigh: c.optimalHigh.map { $0 * f },
                     scaleMax: TrainingLoadGauge.niceCeiling(c.scaleMax * f))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            SectionHeader("Training load")
            HStack(alignment: .top, spacing: ZoopMetrics.gap) {
                LoadGaugeCard(title: "Cardio", unit: "Effort", reading: cardioScaled, decimals: 1)
                if let muscular {
                    LoadGaugeCard(title: "Muscular", unit: "Sets", reading: muscular, decimals: 0)
                }
            }
            Text("This week compared with your own norm.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoadGaugeCard: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    let reading: TrainingLoadGauge.Reading
    let decimals: Int

    private func fmt(_ v: Double) -> String { String(format: decimals == 0 ? "%.0f" : "%.1f", v) }

    private var stateLabel: LocalizedStringKey {
        switch reading.state {
        case .calibrating: return "Calibrating"
        case .low: return "Low"
        case .optimal: return "Optimal"
        case .high: return "High"
        }
    }

    private var stateColor: Color {
        reading.state == .optimal ? StrandPalette.statusPositive : StrandPalette.textSecondary
    }

    var body: some View {
        ZoopCard {
            VStack(spacing: ZoopMetrics.space2) {
                HStack {
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                }
                Text(stateLabel)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(stateColor)
                ZStack(alignment: .bottom) {
                    SemicircleGauge(value: reading.acute, low: reading.optimalLow,
                                    high: reading.optimalHigh, maxValue: reading.scaleMax)
                        .aspectRatio(2, contentMode: .fit)
                    VStack(spacing: 0) {
                        Text(reading.acute.map(fmt) ?? "—")
                            .font(StrandFont.number(24))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                HStack {
                    Text(verbatim: "0")
                    Spacer(minLength: 0)
                    Text(verbatim: fmt(reading.scaleMax))
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                Text(reading.optimalLow.flatMap { lo in reading.optimalHigh.map { hi in
                    String(localized: "Optimal: \(fmt(lo)) – \(fmt(hi))") } } ?? " ")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Upper semicircle with fine ticks, the optimal band in green and a knob at the value.
private struct SemicircleGauge: View {
    let value: Double?
    let low: Double?
    let high: Double?
    let maxValue: Double

    private static let ticks = 41

    var body: some View {
        Canvas { ctx, size in
            let lineW: CGFloat = 2
            let radius = min(size.width / 2, size.height) - 8
            let center = CGPoint(x: size.width / 2, y: size.height - 2)
            func frac(_ v: Double) -> Double { max(0, min(1, v / max(maxValue, 1e-9))) }
            func point(_ f: Double, _ r: CGFloat) -> CGPoint {
                let a = Double.pi * (1 - f)          // 180° (left) → 0° (right)
                return CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y - r * CGFloat(sin(a)))
            }
            let lo = low.map(frac), hi = high.map(frac)
            for i in 0..<Self.ticks {
                let f = Double(i) / Double(Self.ticks - 1)
                let inBand = lo.map { f >= $0 - 1e-9 } == true && hi.map { f <= $0 + 1e-9 } == true
                var p = Path()
                p.move(to: point(f, radius - 10))
                p.addLine(to: point(f, radius))
                ctx.stroke(p, with: .color(inBand ? StrandPalette.statusPositive : StrandPalette.textTertiary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            }
            if let lo, let hi, hi > lo {
                var arc = Path()
                arc.addArc(center: center, radius: radius + 6,
                           startAngle: .radians(-Double.pi * (1 - lo)),
                           endAngle: .radians(-Double.pi * (1 - hi)), clockwise: false)
                ctx.stroke(arc, with: .color(StrandPalette.statusPositive),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if let value {
                let c = point(frac(value), radius - 5)
                let knob = Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
                ctx.fill(knob, with: .color(StrandPalette.textPrimary))
                ctx.stroke(knob, with: .color(StrandPalette.surfaceInset), lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cumulative total card

/// A total with a step line that climbs through the window and ends in a glowing dot.
struct CumulativeTotalCard: View {
    let title: LocalizedStringKey
    let value: String
    let unit: String
    /// (time, amount) increments; summed into the step line.
    let increments: [(Date, Double)]
    let tint: Color

    private struct Step: Identifiable {
        let date: Date
        let total: Double
        var id: Date { date }
    }

    private var steps: [Step] {
        let sorted = increments.sorted { $0.0 < $1.0 }
        guard let first = sorted.first else { return [] }
        var out = [Step(date: first.0.addingTimeInterval(-1), total: 0)]
        var sum = 0.0
        for (d, v) in sorted {
            sum += v
            out.append(Step(date: d, total: sum))
        }
        return out
    }

    var body: some View {
        let s = steps
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(StrandFont.number(24)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Chart {
                    ForEach(s) { p in
                        LineMark(x: .value("t", p.date), y: .value("v", p.total))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if let last = s.last {
                        PointMark(x: .value("t", last.date), y: .value("v", last.total))
                            .symbolSize(160).foregroundStyle(tint.opacity(0.25))
                        PointMark(x: .value("t", last.date), y: .value("v", last.total))
                            .symbolSize(40).foregroundStyle(tint)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 56)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Strength

struct StrengthSection: View {
    let snapshot: LiftFitnessSnapshot
    let unitSystem: UnitSystem

    private var volumeDisplay: String {
        let v = LiftFormat.display(fromKilograms: snapshot.week.volumeKg, system: unitSystem)
        return v.rounded().formatted(.number.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            SectionHeader("Strength", overline: "This week")
            HStack(spacing: ZoopMetrics.gap) {
                CumulativeTotalCard(
                    title: "Working sets", value: "\(snapshot.week.workingSets)", unit: "",
                    increments: snapshot.weekSessions.map { (Date(timeIntervalSince1970: TimeInterval($0.endTs)), Double($0.sets)) },
                    tint: StrandPalette.effortColor)
                CumulativeTotalCard(
                    title: "Volume", value: volumeDisplay, unit: LiftFormat.weightUnit(unitSystem),
                    increments: snapshot.weekSessions.map {
                        (Date(timeIntervalSince1970: TimeInterval($0.endTs)),
                         LiftFormat.display(fromKilograms: $0.volumeKg, system: unitSystem)) },
                    tint: StrandPalette.effortColor)
            }
            if !snapshot.recovery.isEmpty {
                MuscleRecoveryCard(entries: snapshot.recovery)
            }
        }
    }
}

/// Per-muscle recovery estimate (`MuscleRecovery`) as a two-column grid of 10-segment bars.
struct MuscleRecoveryCard: View {
    let entries: [MuscleRecovery.Entry]

    var body: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                Text("Muscle recovery").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space3),
                                    GridItem(.flexible(), spacing: ZoopMetrics.space3)],
                          alignment: .leading, spacing: ZoopMetrics.space3) {
                    ForEach(entries, id: \.muscle) { cell($0) }
                }
                Text("Estimated from sets per muscle: 36 to 72 hours, longer after hard sessions.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cell(_ e: MuscleRecovery.Entry) -> some View {
        let color: Color = e.percentRecovered >= 90 ? StrandPalette.statusPositive
            : (e.percentRecovered >= 50 ? StrandPalette.statusWarning : StrandPalette.statusCritical)
        let filled = MuscleRecovery.filledSegments(percent: e.percentRecovered)
        return VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            Text(e.muscle.displayName)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(e.percentRecovered)%")
                    .font(StrandFont.number(22))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("recovered")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < filled ? color : StrandPalette.surfaceRaised)
                        .frame(height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(e.muscle.displayName): \(e.percentRecovered) percent recovered"))
    }
}
