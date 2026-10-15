import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Sleep factor grid (Zoop)
//
// Six cells, one per contributor to the night: an icon, a one-word verdict, the factor name and a thin
// bar. Verdicts come from `SleepFactors` (StrandAnalytics), fed only by numbers the shared `SleepModel`
// already holds, so the grid can never disagree with the rest of the Sleep screen.

struct SleepFactorGrid: View {
    let model: SleepModel

    private var results: [SleepFactors.Result] {
        let s = model.night.stages
        let hasStages = !model.isStubNight && s.asleep > 0
        return SleepFactors.evaluate(.init(
            hoursVsNeededPct: model.hoursVsNeeded.latest,
            asleepMin: hasStages ? s.asleep : nil,
            deepMin: hasStages ? s.deep : nil,
            remMin: hasStages ? s.rem : nil,
            typicalDeepMin: model.typicalDeepMin,
            typicalRemMin: model.typicalRemMin,
            efficiencyPct: model.efficiency.latest,
            consistencyPct: model.consistency.latest,
            wakeUps: model.wakeUps.latest,
            typicalWakeUps: model.wakeUps.typical))
    }

    var body: some View {
        let items = results
        if !items.isEmpty {
            ZoopCard {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space3),
                                    GridItem(.flexible(), spacing: ZoopMetrics.space3)],
                          alignment: .leading, spacing: ZoopMetrics.space3) {
                    ForEach(items, id: \.factor) { cell($0) }
                }
            }
        }
    }

    private func cell(_ r: SleepFactors.Result) -> some View {
        let color = Self.color(r.verdict)
        return VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            Image(systemName: Self.icon(r.factor))
                .font(ZoopType.icon(14, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            Text(Self.verdictText(r.verdict))
                .font(StrandFont.headline)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(Self.label(r.factor))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceRaised)
                    Capsule().fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(r.progress)))
                }
            }
            .frame(height: 4)
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        .accessibilityElement(children: .combine)
    }

    static func color(_ v: SleepFactors.Verdict) -> Color {
        switch v {
        case .good: return StrandPalette.statusPositive
        case .fair: return StrandPalette.statusWarning
        case .poor: return StrandPalette.statusCritical
        }
    }

    static func verdictText(_ v: SleepFactors.Verdict) -> String {
        switch v {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Poor")
        }
    }

    static func label(_ f: SleepFactors.Factor) -> String {
        switch f {
        case .duration:    return String(localized: "Sleep duration")
        case .deep:        return String(localized: "Deep sleep")
        case .rem:         return String(localized: "REM sleep")
        case .efficiency:  return String(localized: "Efficiency")
        case .consistency: return String(localized: "Consistency")
        case .wakeUps:     return String(localized: "Wake-ups")
        }
    }

    static func icon(_ f: SleepFactors.Factor) -> String {
        switch f {
        case .duration:    return "clock"
        case .deep:        return "moon.zzz"
        case .rem:         return "eye"
        case .efficiency:  return "bed.double"
        case .consistency: return "calendar"
        case .wakeUps:     return "sunrise"
        }
    }
}
