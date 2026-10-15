#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Home card
//
// The full-width card Today mounts as `HomeFitnessAgeCard()`. Its name and initializer are the
// contract with that mount, so they stay put while the feature behind them is rebuilt.

/// The fitness age, how far it sits from your real age, and a small dial.
struct HomeFitnessAgeCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    // The card needs only the weekly rows, not the screen's factor readouts, so it loads the snapshot
    // alone and Today does not pay for the rest.
    @State private var snapshot = FitnessAgeSnapshot()
    @State private var loaded = false

    var body: some View {
        ContentCard {
            HStack(alignment: .center, spacing: ZoopSpacing.l) {
                VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                    HStack(spacing: 6) {
                        Text(FitnessAgeStrings.title)
                            .font(StrandFont.ui(15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(ZoopType.icon(13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    if let latest = snapshot.latest {
                        Text(verbatim: fitnessOneDecimal(latest.value))
                            .font(StrandFont.display(34))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(fitnessAgeDeltaLine(fitnessAge: latest.value, chronoAge: profile.age))
                            .font(StrandFont.subhead)
                            .foregroundStyle(fitnessTint(delta: Double(profile.age) - latest.value))
                            .lineLimit(2)
                    } else if loaded {
                        // A dash is never a valid state: say what is still missing.
                        Text(fitnessReadyLeadCopy(
                            rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
                            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let latest = snapshot.latest, profile.age > 0 {
                    FitnessAgeDial(value: latest.value, chronoAge: Double(profile.age), compact: true)
                        .frame(width: 112, height: 64)
                        .accessibilityHidden(true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: repo.refreshSeq) {
            snapshot = await FitnessAgeSnapshot.load(repo: repo)
            loaded = true
        }
    }
}

// MARK: - Dial

/// A half-circle gauge with fine ticks over your age ±5 years (widened to fit the value): younger to the
/// left, older to the right, your age as a longer tick, the span between your age and the fitness age
/// tinted, and a dot on the value.
struct FitnessAgeDial: View {
    let value: Double
    let chronoAge: Double
    var compact = false

    private var range: ClosedRange<Double> {
        let lo = min(chronoAge - 5, value - 1), hi = max(chronoAge + 5, value + 1)
        return lo...hi
    }

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width / 2, size.height) - (compact ? 6 : 10)
            let center = CGPoint(x: size.width / 2, y: size.height - (compact ? 2 : 4))
            let span = range.upperBound - range.lowerBound
            func angle(_ v: Double) -> Double { .pi + (v - range.lowerBound) / span * .pi }
            func point(_ a: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            }
            let ticks = compact ? 36 : 60
            let tickLen: CGFloat = compact ? 7 : 14
            let lo = min(value, chronoAge), hi = max(value, chronoAge)
            let tint = fitnessTint(delta: chronoAge - value)
            for i in 0...ticks {
                let v = range.lowerBound + span * Double(i) / Double(ticks)
                let a = angle(v)
                var path = Path()
                path.move(to: point(a, r - tickLen))
                path.addLine(to: point(a, r))
                let inSpan = v >= lo && v <= hi
                ctx.stroke(path, with: .color(inSpan ? tint : StrandPalette.textTertiary.opacity(0.55)),
                           lineWidth: compact ? 1.5 : 2)
            }
            // Your age: a longer neutral tick.
            var age = Path()
            let aa = angle(chronoAge)
            age.move(to: point(aa, r - tickLen - (compact ? 4 : 8)))
            age.addLine(to: point(aa, r + (compact ? 2 : 4)))
            ctx.stroke(age, with: .color(StrandPalette.textSecondary), lineWidth: compact ? 1.5 : 2.5)
            // The value: a dot on the arc.
            let dot = point(angle(value), r - tickLen / 2)
            let d: CGFloat = compact ? 9 : 16
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - d / 2, y: dot.y - d / 2, width: d, height: d)),
                     with: .color(StrandPalette.textPrimary))
        }
    }
}
#endif
