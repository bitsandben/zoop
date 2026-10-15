import SwiftUI

// MARK: - PipBar (the Zoop segmented count-up bar)
// N equal rounded segments with small gaps; segments up to the value's fraction are filled with the tint, the last filled one a touch brighter (lead edge).
// Count-up on first appear and every value change: ONE animated fraction on a spring drives all segments, each deriving its fill over a short ramp,
// so they light in sequence with no per-segment timers. Quiet motion sets it instantly. Flat fills only (no glow), tokens only.
// `PipBar` is the bare bar; `PipBarRow` is the card-ready metric row (label, big value/unit, bar beneath).

// MARK: - PipBar

public struct PipBar: View {

    /// The value to display, in `range`.
    public var value: Double
    /// The value's domain (mapped to 0…1 across the bar). Defaults to a percentage scale.
    public var range: ClosedRange<Double>
    /// Number of segments ("pips"). Higher = finer resolution. Default 24.
    public var segments: Int
    /// The fill colour for lit segments (a domain / status / score token).
    public var tint: Color
    /// Bar height in points.
    public var height: CGFloat

    public init(
        value: Double,
        range: ClosedRange<Double> = 0...100,
        segments: Int = 24,
        tint: Color,
        height: CGFloat = 10
    ) {
        self.value = value
        self.range = range
        self.segments = segments
        self.tint = tint
        self.height = height
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Same gate as count-up text: in-app Reduce Motion or Low Power Mode suppress the sweep even when the OS flag is off.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// The single animated driver: a 0…1 fraction that the whole bar derives from. One eased sweep moves
    /// it 0 → target so segments light in sequence; quiet motion snaps it to the target.
    @State private var animatedFraction: Double = 0

    /// The count-up curve: a quick eased cascade (~0.6s) so pips light left→right; `nil` under the quiet-motion gate so the bar renders static.
    private var countUp: Animation? {
        poseStill ? nil : .easeOut(duration: 0.6)
    }

    /// The target fill fraction (value mapped into 0…1, clamped).
    private var targetFraction: Double {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    /// Effective segment count (always ≥ 1 so we never divide by zero or draw nothing).
    private var pipCount: Int { max(1, segments) }

    public var body: some View {
        // Gap scales with height so the bar reads consistently at any size; pips stay rounded (rx ~2.5).
        let gap: CGFloat = max(2, height * 0.28)
        let corner: CGFloat = 2.5

        // Precompute the three constant colours (inset track, tint, brightened lead tint) once per body eval, not inside each of the (default 24) segment closures.
        let track = StrandPalette.surfaceInset
        let leadBase = brighten(tint)

        HStack(spacing: gap) {
            ForEach(0..<pipCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fillStyle(for: index, track: track, leadBase: leadBase))
            }
        }
        .frame(height: height)
        .onAppear {
            // Count-up on first appear (or snap when quiet motion is on).
            withAnimation(countUp) { animatedFraction = targetFraction }
        }
        .onChangeCompat(of: value) { _ in
            withAnimation(countUp) { animatedFraction = targetFraction }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(axValue))
    }

    /// The fill for one segment, derived from the single animated fraction. Each pip owns `[index/N, (index+1)/N]` and ramps over its own span so the leading pip fades in;
    /// the pip holding the lead edge gets a small brightness lift.
    private func fillStyle(for index: Int, track: Color, leadBase: Color) -> Color {
        let n = Double(pipCount)
        let segStart = Double(index) / n
        let segEnd = Double(index + 1) / n
        let f = animatedFraction

        let local: Double
        if f >= segEnd {
            local = 1
        } else if f <= segStart {
            local = 0
        } else {
            local = (f - segStart) / (segEnd - segStart) // span is 1/n, always > 0
        }

        // Track colour for unlit pips; partially-lit pips mix toward it so the cascade edge reads cleanly.
        if local <= 0 { return track }

        // Lit pips use the tint; the lead-edge pip uses `leadBase` (brightened tint, precomputed in `body`). Flat, no glow.
        let isLeadEdge = targetFraction > segStart && targetFraction <= segEnd
        let base = isLeadEdge ? leadBase : tint

        // Partially covered pip (the moving front): blend track → fill by coverage so the sweep edge is smooth.
        return local >= 1 ? base : StrandPalette.interpolate(track, base, local)
    }

    /// Pure white, built once (not a fresh `Color(hex:)` per `brighten` call).
    private static let white = Color(hex: "#FFFFFF")

    /// A small, glow-free brightness lift for the lead-edge segment — blend the tint toward white.
    private func brighten(_ color: Color) -> Color {
        StrandPalette.interpolate(color, Self.white, 0.22)
    }

    private var axValue: String {
        let v = (value * 10).rounded() / 10
        let shown = v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
        return shown
    }
}

// MARK: - PipBarRow (card-ready WHOOP metric row)

/// A card-ready row: UPPERCASE overline label + big white value with a smaller unit suffix on top, the `PipBar` beneath. Drop into a `StrandCard`.
public struct PipBarRow: View {

    /// UPPERCASE-style label (rendered with overline tracking + textCase upper).
    public var label: LocalizedStringKey
    /// The value for the bar, in `range`.
    public var value: Double
    /// The value's domain.
    public var range: ClosedRange<Double>
    /// Lit-segment fill colour.
    public var tint: Color
    /// The big value string shown on top (already formatted, e.g. "87" or "9.0").
    public var valueText: String
    /// Optional smaller-weight unit suffix (e.g. "%", "bpm"). nil hides it.
    public var unit: String?
    /// Segment count, forwarded to the bar.
    public var segments: Int

    public init(
        label: LocalizedStringKey,
        value: Double,
        range: ClosedRange<Double> = 0...100,
        tint: Color,
        valueText: String,
        unit: String? = nil,
        segments: Int = 24
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.tint = tint
        self.valueText = valueText
        self.unit = unit
        self.segments = segments
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valueText)
                    .font(StrandFont.number(30, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(unit)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            PipBar(value: value, range: range, segments: segments, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(unit.map { "\(valueText) \($0)" } ?? valueText))
    }
}

#if DEBUG
#Preview("PipBar") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Group {
                Text("Values").strandOverline()
                labelled("0%",   PipBar(value: 0,   tint: StrandPalette.chargeColor))
                labelled("25%",  PipBar(value: 25,  tint: StrandPalette.chargeColor))
                labelled("62%",  PipBar(value: 62,  tint: StrandPalette.effortColor))
                labelled("88%",  PipBar(value: 88,  tint: StrandPalette.restColor))
                labelled("100%", PipBar(value: 100, tint: StrandPalette.statusPositive))
            }

            Group {
                Text("Segment counts & heights").strandOverline().padding(.top, 8)
                labelled("12 seg", PipBar(value: 70, segments: 12, tint: StrandPalette.effortColor))
                labelled("36 seg", PipBar(value: 70, segments: 36, tint: StrandPalette.effortColor))
                labelled("tall",   PipBar(value: 45, tint: StrandPalette.statusWarning, height: 14))
            }

            Text("In a card").strandOverline().padding(.top, 8)
            StrandCard(tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 18) {
                    PipBarRow(label: "Charge", value: 74, tint: StrandPalette.chargeColor,
                              valueText: "74", unit: "%")
                    PipBarRow(label: "Effort", value: 9.0, range: 0...21, tint: StrandPalette.effortColor,
                              valueText: "9.0")
                    PipBarRow(label: "Rest", value: 87, tint: StrandPalette.restColor,
                              valueText: "87", unit: "%")
                }
            }

            Text("Reduce Motion renders static at the final frame.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 460, height: 720)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func labelled(_ name: String, _ bar: PipBar) -> some View {
    HStack(spacing: 14) {
        Text(name)
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(width: 52, alignment: .leading)
        bar
    }
}
#endif
