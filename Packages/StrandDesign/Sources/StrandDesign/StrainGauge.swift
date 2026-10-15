#if !os(watchOS)
// Uses .onContinuousHover + ChartHover tooltips (unavailable on watchOS; the watch uses GlowRing), so the view is excluded there.
import SwiftUI

// MARK: - Strain Gauge
// Blue Effort gauge in the same open-gauge language as the Recovery Ring, filled to strain/outOf of a 240° arc; flat, with a clean leading bead.
// `outOf` is the max of the scale `strain` is ON (default 21, WHOOP Day Strain). The Effort hero passes the value already converted to the user's display scale
// plus its max (100 or 21) so arc, numeral and "of N" caption agree (#268); the caller owns the conversion (EffortScale lives in the app layer).

public struct StrainGauge: View {

    /// Strain value on the displayed scale (its maximum is `outOf`).
    public var strain: Double
    /// The maximum of the scale `strain` is on: the arc fills `strain/outOf` and the caption reads "of N". Defaults to 21.
    public var outOf: Double
    /// Optional supporting line, e.g. "moderate cardiovascular load".
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Whether hovering the gauge shows a subtle tooltip (strain + state word).
    public var showsHover: Bool
    /// Formats the strain value for the hover tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        strain: Double,
        outOf: Double = 21,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 14,
        showsLabel: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { String(format: "Strain %.1f", $0) }
    ) {
        self.strain = strain
        self.outOf = outOf
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    /// Cursor location while hovering, in gauge-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A short load word for the strain value, mirroring the recovery state idea. Computed off the
    /// fraction (not the raw value) so the bands read the same on the 0–100 and 0–21 display scales.
    public static func stateLabel(forFraction fraction: Double) -> String {
        switch min(max(fraction, 0), 1) {
        case ..<(6.0 / 21):   return String(localized: "LIGHT", bundle: .module)
        case ..<(10.0 / 21):  return String(localized: "MODERATE", bundle: .module)
        case ..<(14.0 / 21):  return String(localized: "STRENUOUS", bundle: .module)
        case ..<(18.0 / 21):  return String(localized: "HIGH", bundle: .module)
        default:              return String(localized: "ALL-OUT", bundle: .module)
        }
    }
    private var strainWord: String { Self.stateLabel(forFraction: fraction) }

    @State private var animatedFraction: Double = 0
    @State private var bloomPulse = false

    private var fraction: Double { min(max(strain / outOf, 0), 1) }
    /// Tip tint sampled by the fill FRACTION so it spans the full ember→amber ramp identically on the
    /// 0–100 and 0–21 display scales (a maxed gauge reaches the bright-amber peak, not a stuck ember).
    private var tipColor: Color { StrandPalette.effortTint(fraction: fraction) }

    public var body: some View {
        ZStack {
            BevelGauge(
                fraction: fraction,
                stops: StrandPalette.strainStops,
                tipColor: tipColor,
                numberText: strainString,
                captionText: showsLabel ? "of \(Int(outOf.rounded()))" : nil,
                stateText: showsLabel ? strainWord : nil,
                supporting: supporting,
                diameter: diameter,
                lineWidth: lineWidth,
                showsLabel: showsLabel,
                animatedFraction: animatedFraction,
                bloomActive: bloomPulse
            )
            if showsHover, let pt = hoverPoint {
                PositionedTooltip(
                    anchor: pt,
                    container: CGSize(width: diameter, height: diameter),
                    tooltip: ChartTooltip(
                        value: valueFormat(strain),
                        label: strainWord,
                        accent: tipColor
                    )
                )
                .animation(StrandMotion.fade, value: hoverPoint == nil)
            }
        }
        .frame(width: diameter, height: diameter)
        // Collapse the centre Text fragments into one VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueFormat(strain)))
        .accessibilityValue(Text(strainWord))
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
        .onChangeCompat(of: strain) { _ in
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
    }

    private var strainString: String {
        String(format: "%.1f", strain)
    }
}

#if DEBUG
#Preview("StrainGauge") {
    VStack(spacing: 16) {
        HStack(spacing: 28) {
            StrainGauge(strain: 4.2, supporting: "light day", diameter: 190)
            StrainGauge(strain: 11.5, supporting: "moderate load", diameter: 190)
            StrainGauge(strain: 18.7, supporting: "all-out effort", diameter: 190)
        }
        Text("Hover a gauge for a strain + load-word tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
