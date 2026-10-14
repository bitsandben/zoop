import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Load gauges
//
// Cardio and muscular load as two semicircle gauges, each placing this week against the user's OWN norm
// with the optimal band marked (`TrainingLoadGauge`). The needle's range is relative to that norm, so the
// gauge prints the value and the optimal band but no absolute scale: a second "out of N" figure next to
// the Effort scale was exactly the contradiction the old page had.

struct TrainingLoadGauges: View {
    let cardio: TrainingLoadGauge.Reading
    let muscular: TrainingLoadGauge.Reading?
    let effortScale: EffortScale

    /// Cardio is modelled on the stored 0–100 Effort axis; the gauge shows the user's scale.
    private var cardioScaled: TrainingLoadGauge.Reading {
        let f = TrainingEffort.value(1, scale: effortScale)
        return .init(state: cardio.state, acute: cardio.acute.map { $0 * f },
                     chronic: cardio.chronic.map { $0 * f },
                     optimalLow: cardio.optimalLow.map { $0 * f }, optimalHigh: cardio.optimalHigh.map { $0 * f },
                     scaleMax: TrainingLoadGauge.niceCeiling(cardio.scaleMax * f))
    }

    var body: some View {
        ContentCard {
            Text(TrainingStrings.gaugesTitle)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .top, spacing: ZoopSpacing.l) {
                LoadGauge(title: "Cardio", unit: "Effort", reading: cardioScaled, decimals: 1)
                // Alone, the cardio gauge stays at half width; at full width it reads oversized.
                if let muscular {
                    LoadGauge(title: "Muscular", unit: "Sets", reading: muscular, decimals: 0)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
            Text("This week compared with your own norm.")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoadGauge: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    let reading: TrainingLoadGauge.Reading
    let decimals: Int

    private func format(_ v: Double) -> String { ZoopNumber.decimal(v, digits: decimals) }

    private var stateLabel: LocalizedStringKey {
        switch reading.state {
        case .calibrating: return "Calibrating"
        case .low: return "Low"
        case .optimal: return "Optimal"
        case .high: return "High"
        }
    }

    var body: some View {
        VStack(spacing: ZoopSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(stateLabel)
                    .font(ZoopType.caption)
                    .foregroundStyle(reading.state == .optimal ? StrandPalette.statusPositive : StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .bottom) {
                SemicircleGauge(value: reading.acute, low: reading.optimalLow,
                                high: reading.optimalHigh, maxValue: reading.scaleMax)
                    .aspectRatio(2, contentMode: .fit)
                VStack(spacing: 0) {
                    Text(reading.acute.map(format) ?? "\u{2013}")
                        .font(ZoopType.metric)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(unit).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if let low = reading.optimalLow, let high = reading.optimalHigh {
                Text("Optimal: \(format(low)) – \(format(high))")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
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
