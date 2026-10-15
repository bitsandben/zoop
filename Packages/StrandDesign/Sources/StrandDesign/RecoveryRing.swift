import SwiftUI

// MARK: - Recovery Ring — THE signature component
// Excluded on watchOS (the view uses .onContinuousHover, BevelGauge and ChartHover tooltips; the watch uses GlowRing). The pure `RecoveryArc` Shape at the bottom
// stays on ALL platforms because the watch-safe BevelGauge / BrandMark depend on it.
// 240° open gauge arc filled to score/100 with an AngularGradient from `recoveryStops` over a faint `surfaceInset` track; flat (no bloom), crisp bead at the tip, draw-in on change.
// Centre: big number, state word tinted to the sampled colour, optional supporting line.
// Also the brand glyph: open ring + solid accent core dot; the recovery ring adds a micro "Zoop" wordmark above the number. Arc, track and number live in the shared `BevelGauge`.

#if !os(watchOS)
public struct RecoveryRing: View {

    /// Recovery score 0...100.
    public var score: Double
    /// Optional supporting line, e.g. "HRV 62ms · RHR 51 · ready for moderate strain".
    public var supporting: String?
    /// Diameter of the ring.
    public var diameter: CGFloat
    /// Stroke thickness; hero is 13–14pt.
    public var lineWidth: CGFloat
    /// Whether to show the center read-out (number + state + supporting).
    public var showsLabel: Bool
    /// Whether to draw the micro "Zoop" wordmark above the number. Turn off for compact rings where it would crowd the number.
    public var showsWordmark: Bool
    /// Whether hovering the ring shows a subtle tooltip (score + state word).
    public var showsHover: Bool
    /// Formats the score for the hover tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        score: Double,
        supporting: String? = nil,
        diameter: CGFloat = 240,
        lineWidth: CGFloat = 14,
        showsLabel: Bool = true,
        showsWordmark: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        self.score = score
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsWordmark = showsWordmark
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    /// Cursor location while hovering, in ring-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animated fill fraction so changing `score` draws the arc in.
    @State private var animatedFraction: Double = 0
    @State private var bloomPulse: Bool = false

    private var fraction: Double { min(max(score / 100.0, 0), 1) }
    private var tipColor: Color { StrandPalette.recoveryColor(score) }
    private var stateWord: String { StrandPalette.recoveryState(score) }

    public var body: some View {
        ZStack {
            BevelGauge(
                fraction: fraction,
                stops: StrandPalette.recoveryStops,
                tipColor: tipColor,
                numberText: numberString,
                captionText: showsLabel ? "of 100" : nil,
                stateText: showsLabel ? stateWord : nil,
                supporting: supporting,
                diameter: diameter,
                lineWidth: lineWidth,
                showsLabel: showsLabel,
                animatedFraction: animatedFraction,
                bloomActive: bloomPulse
            )
            // Brand layers over the shared gauge: the core dot, then the micro "Zoop" wordmark just above the centre number.
            coreDot
            if showsLabel && showsWordmark { wordmark }
            if showsHover, let pt = hoverPoint {
                PositionedTooltip(
                    anchor: pt,
                    container: CGSize(width: diameter, height: diameter),
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: stateWord,
                        accent: tipColor
                    )
                )
                .animation(StrandMotion.fade, value: hoverPoint == nil)
            }
        }
        .frame(width: diameter, height: diameter)
        // Collapse the centre Text fragments into one VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueFormat(score)))
        .accessibilityValue(Text(stateWord))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location): hoverPoint = location
            case .ended: hoverPoint = nil
            }
        }
        .onAppear {
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
            // Reduce Motion: leave the bloom at its resting opacity instead of breathing.
            if !reduceMotion { bloomPulse = true }
        }
        .onChangeCompat(of: score) { _ in
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
    }

    private var numberString: String {
        String(Int(score.rounded()))
    }

    // MARK: Brand layers

    /// Micro "Zoop" wordmark above the number: ALL-CAPS, tertiary, letter-spacing ≈ .34em, nudged clear of BevelGauge's centred number.
    private var wordmark: some View {
        let size = diameter * 0.052
        return Text("Zoop")
            .font(StrandFont.rounded(size, weight: .bold))
            .tracking(size * 0.34)                 // ≈ .34em
            .foregroundStyle(StrandPalette.textTertiary)
            .offset(y: -diameter * 0.205)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The brand "on-device core": a small solid accent dot at the centre, for the glyph-only lock-up (logo / nav / onboarding).
    /// Hidden whenever a number is shown, since a dot behind the digits muddies them.
    private var coreDot: some View {
        Circle()
            .fill(StrandPalette.accent)
            .frame(width: diameter * 0.026, height: diameter * 0.026)
            .opacity(showsLabel ? 0.0 : 1.0)       // hidden under the number; full when glyph-only
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif

// MARK: - Arc Shape

/// An open 240° gauge arc that fills clockwise from the start angle.
public struct RecoveryArc: Shape {
    public var startAngle: Angle
    public var spanDegrees: Double
    public var fraction: Double
    public var lineWidth: CGFloat

    public var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let end = Angle.degrees(startAngle.degrees + spanDegrees * min(max(fraction, 0), 1))
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

#if DEBUG && !os(watchOS)
#Preview("RecoveryRing — scores") {
    VStack(spacing: 16) {
        HStack(spacing: 28) {
            RecoveryRing(score: 22, supporting: "HRV 38ms · RHR 58 · take it easy", diameter: 220)
            RecoveryRing(score: 55, supporting: "HRV 49ms · RHR 54 · moderate ok", diameter: 220)
        }
        Text("Hover a ring for a recovery + state-word tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("RecoveryRing — primed/peak") {
    HStack(spacing: 28) {
        RecoveryRing(score: 78, supporting: "HRV 62ms · RHR 51 · ready for moderate strain", diameter: 220)
        RecoveryRing(score: 91, supporting: "HRV 74ms · RHR 47 · primed to push", diameter: 220)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

private struct RecoveryRingLive: View {
    @State private var score: Double = 64
    var body: some View {
        VStack(spacing: 24) {
            RecoveryRing(score: score, supporting: "drag to feel the draw-in", diameter: 260)
            Slider(value: $score, in: 0...100)
                .frame(width: 280)
        }
        .padding(40)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("RecoveryRing — interactive") { RecoveryRingLive() }
#endif
