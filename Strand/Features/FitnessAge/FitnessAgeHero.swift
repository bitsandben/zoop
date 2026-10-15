#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Hero

/// The top of the Fitness Age screen, edge to edge under the status bar: a soft gradient with a slow star
/// field, the title and week, the age counting in, the wide dial and how far it sits from your age.
struct FitnessAgeHero: View {
    let day: String
    let value: Double
    let chronoAge: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double?

    var body: some View {
        let chrono = Double(chronoAge)
        VStack(spacing: ZoopMetrics.space1) {
            if let d = fitnessDayDate(day) {
                Text(FitnessAgeStrings.week(d.formatted(.dateTime.day().month(.wide))))
                    .font(ZoopType.caption.weight(.medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ZStack(alignment: .bottom) {
                FitnessAgeHeroDial(value: value, shown: shown ?? chrono, chronoAge: chrono)
                    .aspectRatio(1.9, contentMode: .fit)
                VStack(spacing: ZoopMetrics.space1) {
                    FitnessCountingText(value: shown ?? chrono)
                        .font(StrandFont.display(76).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(fitnessAgeDeltaLine(fitnessAge: value, chronoAge: chronoAge))
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(fitnessTint(delta: chrono - value))
                    // The number is an estimate; say how far off it can be, right where it is read.
                    Text(FitnessAgeStrings.band(fitnessOneDecimal(FitnessAgeEngine.displayBandYears)))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 10)
            .padding(.top, ZoopMetrics.space4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, ZoopMetrics.space2)
        .padding(.bottom, 36)
        .background(alignment: .bottom) {
            FitnessHeroBackdrop()
                .padding(.top, -600)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FitnessAgeStrings.hero(fitnessOneDecimal(value),
                                                         fitnessAgeDeltaLine(fitnessAge: value, chronoAge: chronoAge))))
        .task(id: value) {
            guard !reduceMotion else { shown = value; return }
            shown = chrono
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.spring(duration: 1.4, bounce: 0.12)) { shown = value }
        }
    }
}

/// The age as it counts toward its value, one decimal.
private struct FitnessCountingText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: fitnessOneDecimal(value))
    }
}

/// The hero's background: a deep tint fading into the canvas, with a star field over it.
private struct FitnessHeroBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: StrandPalette.sleepDeep.opacity(0.42), location: 0),
                .init(color: StrandPalette.sleepDeep.opacity(0.32), location: 0.55),
                .init(color: StrandPalette.surfaceBase, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            FitnessStarField()
        }
        .background(StrandPalette.surfaceBase)
    }
}

/// Faint points drifting slowly sideways and twinkling, fading toward the bottom. Drawn at 20 fps in
/// one Canvas; still when Reduce Motion is on.
private struct FitnessStarField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Star { let x, y, size, phase, speed: Double }

    private static let stars: [Star] = {
        var seed: UInt64 = 0x5EED_F17A
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        return (0..<90).map { _ in
            Star(x: next(), y: next(), size: 0.6 + next() * 1.4, phase: next() * 2 * .pi, speed: 1 + next() * 3)
        }
    }()

    @ObservedObject private var motion = ZoopMotionState.shared

    var body: some View {
        // Motion unwanted (Reduce Motion, Low Power, background): one still frame and no timeline at all,
        // as in `LiquidSky`; a paused TimelineView still keeps the render server busy.
        Group {
            if motion.poseStill(reduceMotion) {
                Canvas { ctx, size in Self.draw(ctx, size, t: 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                    Canvas { ctx, size in
                        Self.draw(ctx, size, t: timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 100_000))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        for s in Self.stars {
            var x = (s.x * size.width + t * s.speed).truncatingRemainder(dividingBy: size.width)
            if x < 0 { x += size.width }
            let y = s.y * size.height
            let fade = max(0, 1 - y / size.height * 1.15)
            let twinkle = 0.5 + 0.5 * sin(t * 0.7 + s.phase)
            let alpha = (0.15 + 0.45 * twinkle) * fade
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s.size, height: s.size)),
                     with: .color(StrandPalette.textPrimary.opacity(alpha)))
        }
    }
}

/// The wide hero dial: fine ticks over your age ±5 years (widened to fit the value), the two ends
/// labelled along the arc, your age as a longer tick, the span to the fitness age tinted and a knob on
/// `shown`, which animates toward `value` while the range stays fixed on `value`.
private struct FitnessAgeHeroDial: View, Animatable {
    let value: Double
    var shown: Double
    let chronoAge: Double

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    private var range: ClosedRange<Double> {
        let lo = min(chronoAge - 5, value - 1), hi = max(chronoAge + 5, value + 1)
        return lo...hi
    }

    var body: some View {
        Canvas { ctx, size in
            let knob: CGFloat = 22
            let r = min(size.width / 2, size.height) - knob / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height - 2)
            let span = range.upperBound - range.lowerBound
            // The ticks leave room at each end for the range labels.
            let endGap = 0.2
            let a0 = Double.pi + endGap, a1 = 2 * Double.pi - endGap
            func angle(_ v: Double) -> Double { a0 + (v - range.lowerBound) / span * (a1 - a0) }
            func point(_ a: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            }
            let tickLen: CGFloat = 18
            let ticks = 110
            let lo = min(shown, chronoAge), hi = max(shown, chronoAge)
            let tint = fitnessTint(delta: chronoAge - value)
            for i in 0...ticks {
                let v = range.lowerBound + span * Double(i) / Double(ticks)
                let a = angle(v)
                var path = Path()
                path.move(to: point(a, r - tickLen / 2))
                path.addLine(to: point(a, r + tickLen / 2))
                let inSpan = v >= lo && v <= hi
                ctx.stroke(path, with: .color(inSpan ? tint : StrandPalette.textTertiary.opacity(0.45)), lineWidth: 1.2)
            }
            // Your age: a longer neutral tick.
            var age = Path()
            let aa = angle(chronoAge)
            age.move(to: point(aa, r - tickLen / 2 - 7))
            age.addLine(to: point(aa, r + tickLen / 2 + 3))
            ctx.stroke(age, with: .color(StrandPalette.textSecondary), lineWidth: 2)
            // The range ends, written along the arc.
            for (v, a) in [(range.lowerBound, Double.pi + endGap / 2), (range.upperBound, 2 * Double.pi - endGap / 2)] {
                let label = ctx.resolve(Text(verbatim: fitnessOneDecimal(v))
                    .font(StrandFont.footnote.monospacedDigit().weight(.medium))
                    .foregroundColor(StrandPalette.textTertiary))
                var c = ctx
                let p = point(a, r)
                c.translateBy(x: p.x, y: p.y)
                c.rotate(by: .radians(a + .pi / 2))
                c.draw(label, at: .zero, anchor: .center)
            }
            // The knob on the value.
            let k = point(angle(shown), r)
            let rect = CGRect(x: k.x - knob / 2, y: k.y - knob / 2, width: knob, height: knob)
            var shadow = ctx
            shadow.addFilter(.shadow(color: StrandPalette.surfaceBase.opacity(0.6), radius: 6))
            shadow.fill(Path(ellipseIn: rect), with: .color(StrandPalette.textPrimary))
        }
    }
}
#endif
