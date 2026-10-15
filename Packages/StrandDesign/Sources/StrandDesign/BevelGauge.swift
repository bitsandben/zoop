import SwiftUI

// MARK: - BevelGauge: the layered ring gauge primitive
//
// Shared by RecoveryRing and StrainGauge: a 240° open gauge with a frosted inner disc, a faint track
// ring, a gradient progress arc, an end-cap dot and a centred rounded number with caption + state word.
// It owns no domain logic; callers pass the fraction, gradient, tip colour and read-out strings.

public struct BevelGauge: View {

    /// Fill fraction 0...1 of the 240° span.
    public var fraction: Double
    /// Angular gradient stops for the progress arc.
    public var stops: [Gradient.Stop]
    /// Colour of the end-cap + state word (usually the ramp sampled at `fraction`).
    public var tipColor: Color
    /// Big centred number, already formatted (e.g. "87" or "12.4").
    public var numberText: String
    /// Small caption under the number (e.g. "of 100" / "of 21"). nil hides it.
    public var captionText: String?
    /// State word above/below the number (e.g. "PRIMED"). nil hides it.
    public var stateText: String?
    /// Optional supporting line under the read-out.
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Animated draw-in fraction supplied by the caller (it owns the @State + animation).
    public var animatedFraction: Double
    /// Whether the bloom is at full intensity; caller drives the pulse.
    public var bloomActive: Bool

    public init(
        fraction: Double,
        stops: [Gradient.Stop],
        tipColor: Color,
        numberText: String,
        captionText: String? = nil,
        stateText: String? = nil,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        animatedFraction: Double,
        bloomActive: Bool = true
    ) {
        self.fraction = fraction
        self.stops = stops
        self.tipColor = tipColor
        self.numberText = numberText
        self.captionText = captionText
        self.stateText = stateText
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.animatedFraction = animatedFraction
        self.bloomActive = bloomActive
    }

    private let arcSpanDegrees: Double = 240
    private var startAngle: Angle { .degrees(150) }
    private var endAngle: Angle { .degrees(150 + arcSpanDegrees) }

    private var gradient: Gradient { Gradient(stops: stops) }

    public var body: some View {
        ZStack {
            // STATIC BACKDROP: independent of `animatedFraction`, so it is not re-rendered while the arc animates.
            // No .drawingGroup(): a per-instance offscreen flatten cost more than it saved.
            staticBackdrop
                .frame(width: diameter, height: diameter)

            // LIVE LAYER: kept OUTSIDE any drawingGroup so the shape's `animatableData` still animates.
            animatedArc

            if showsLabel { centerLabel }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The non-animating backdrop: frosted disc plus the faint full-span track.
    private var staticBackdrop: some View {
        ZStack {
            innerDisc
            // Faint full-span track.
            arcShape(to: 1.0)
                .stroke(StrandPalette.surfaceInset,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    /// The live layer: filled gradient arc plus end-cap dot.
    private var animatedArc: some View {
        ZStack {
            arcShape(to: animatedFraction)
                .stroke(
                    AngularGradient(gradient: gradient, center: .center,
                                    startAngle: startAngle, endAngle: endAngle),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )

            if animatedFraction > 0.001 { endCap }
        }
    }

    private var innerDisc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [StrandPalette.surfaceInset.opacity(0.0), StrandPalette.surfaceInset.opacity(0.55)],
                    center: .center, startRadius: diameter * 0.10, endRadius: diameter * 0.5
                )
            )
            .overlay(Circle().strokeBorder(StrandPalette.hairline.opacity(0.5), lineWidth: 1))
            .padding(lineWidth * 1.4)
    }

    // No outer bloom: fill contrast carries the arc edge. `bloomActive` stays in the signature but no longer renders.

    private var endCap: some View {
        GeometryReader { geo in
            let radius = (min(geo.size.width, geo.size.height) - lineWidth) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let tipAngle = startAngle.radians + (arcSpanDegrees * .pi / 180) * animatedFraction
            let pt = CGPoint(x: center.x + radius * cos(tipAngle),
                             y: center.y + radius * sin(tipAngle))
            // Single small solid dot at the arc end.
            Circle().fill(StrandPalette.tipCore)
                .frame(width: lineWidth * 0.7, height: lineWidth * 0.7)
                .overlay(Circle().fill(tipColor).opacity(0.35))
                .shadow(color: tipColor.opacity(0.35), radius: lineWidth * 0.18)
                .position(pt)
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(numberText)
                .font(StrandFont.rounded(diameter * 0.30, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            if let captionText {
                Text(captionText)
                    .font(StrandFont.rounded(diameter * 0.085, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let stateText {
                // Scale the state word with the gauge. `min(11, …)` keeps the 11pt overline on large rings and shrinks
                // it on small three-up rings where it collided with the number. Scaled overline (not rounded()) preserves Dynamic Type.
                let stateSize = min(11, diameter * 0.085)
                Text(stateText)
                    .font(StrandFont.overlineScaled(stateSize))
                    .tracking(StrandFont.overlineTracking * stateSize / 11)
                    .foregroundStyle(tipColor)
                    .padding(.top, 2)
            }
            if let supporting {
                Text(supporting)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: diameter * 0.78)
                    .padding(.top, 2)
            }
        }
    }

    private func arcShape(to fraction: Double) -> RecoveryArc {
        RecoveryArc(startAngle: startAngle, spanDegrees: arcSpanDegrees,
                    fraction: fraction, lineWidth: lineWidth)
    }
}

#if DEBUG
#Preview("BevelGauge") {
    HStack(spacing: 24) {
        BevelGauge(
            fraction: 0.78, stops: StrandPalette.recoveryStops,
            tipColor: StrandPalette.recoveryColor(78), numberText: "78",
            captionText: "of 100", stateText: "PRIMED",
            diameter: 200, animatedFraction: 0.78
        )
        BevelGauge(
            fraction: 0.55, stops: StrandPalette.strainStops,
            tipColor: StrandPalette.strainColor(55), numberText: "11.6",
            captionText: "of 21", stateText: "MODERATE",
            diameter: 200, animatedFraction: 0.55
        )
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
