import SwiftUI

// MARK: - BrandMark: the Zoop logo mark
//
// A deep-navy circular tile with a faint top sheen and hairline rim, an open ~80% gold ring starting at
// 12 o'clock and sweeping clockwise, and a solid gold core dot. Flat by design (no bloom, shadow or
// glow). Everything is driven off a single `size`, so it stays crisp from a 28pt avatar to a 120pt hero.

public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    // The open ring sweeps ~80% of a turn from 12 o'clock clockwise, matching the hero recovery ring.
    private let openFraction: Double = 0.80
    private var startAngle: Angle { .degrees(-90) }

    // Proportions derive from `size` so the mark is resolution-independent.
    private var ringInset: CGFloat { size * 0.20 }          // tile edge → ring band
    private var ringWidth: CGFloat { size * 0.13 }          // THICK gold stroke (matches the icon)
    private var ringDiameter: CGFloat { size - ringInset * 2 }
    private var coreDiameter: CGFloat { size * 0.18 }       // centre core dot
    private var rimWidth: CGFloat { max(1, size * 0.008) }  // ~1px hairline rim

    public var body: some View {
        ZStack {
            navyTile
            goldRing
            coreDot
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zoop"))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Deep-navy tile

    // Disc and core: near-black tile in Classic, pale lavender (deep forest in dark) under Pastel & Nature.
    static let tileTop = Color(light: "#1A1E24", dark: "#1A1E24", pastel: ("#E6E1FA", "#2A3530"))
    static let tileBottom = Color(light: "#0E1116", dark: "#0E1116", pastel: ("#DCD6F7", "#1B2420"))
    static let tileSheen = Color(light: "#2A2F37", dark: "#2A2F37", pastel: ("#FFFFFF", "#38433D"))
    static let core = Color(light: "#FFFFFF", dark: "#FFFFFF", pastel: ("#5E52B0", "#EEF2EE"))

    /// The navy disc the gold mark sits on: a vertical navy ramp with a faint top sheen and hairline rim. Flat, no shadow.
    private var navyTile: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [BrandMark.tileTop, BrandMark.tileBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Faint cool top sheen.
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [BrandMark.tileSheen.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(0.6)
            )
            // Hairline rim.
            .overlay(
                Circle().strokeBorder(StrandPalette.hairline, lineWidth: rimWidth)
            )
    }

    // MARK: Open gold recovery ring

    /// The open ~80% gold arc, round-capped, with an AngularGradient so the metal shifts along the sweep.
    private var goldRing: some View {
        RecoveryArc(
            startAngle: startAngle,
            spanDegrees: 360 * openFraction,
            fraction: 1,
            lineWidth: ringWidth
        )
        .stroke(
            ZoopTheme.isPastel ? StrandPalette.restColor : StrandPalette.chargeColor,
            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
        )
        .frame(width: ringDiameter, height: ringDiameter)
    }

    // MARK: Solid gold core

    /// A solid gold dot at the exact centre.
    private var coreDot: some View {
        Circle()
            .fill(BrandMark.core)
            .frame(width: coreDiameter, height: coreDiameter)
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
