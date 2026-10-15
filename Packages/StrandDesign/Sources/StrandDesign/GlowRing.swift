import SwiftUI

// MARK: - GlowRing: crisp score ring
//
// A clean rounded-cap arc over a clearly visible full-circle track (reads as "X% of a circle"), a bold
// counting-up number, and at most a tight low-opacity glow (additive on dark, hidden on light). The arc
// springs in from 12 o'clock and re-animates on value change. Motion gated on Reduce Motion.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre; rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The solid arc colour (the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The centre-number font for a ring of the given diameter. Exposed so EMPTY / "No data" rings can match a filled ring's size and weight.
    public static func centerFont(diameter: CGFloat) -> Font {
        StrandFont.rounded(diameter * 0.36, weight: .bold)
    }

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var filled: CGFloat { appeared ? clamped : 0 }
    private var shown: Double { appeared ? value : 0 }
    private var drawSpring: Animation { .spring(response: 0.9, dampingFraction: 0.86) }

    public var body: some View {
        ZStack {
            // Full-circle track so the arc reads as a fraction.
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // No glow: flat, crisp solid arc.
            arc.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Text(format(shown))
                .font(Self.centerFont(diameter: diameter))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.horizontal, lineWidth + 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: shown)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : drawSpring, value: filled)
        .onAppear { appeared = true }
    }

    /// The trimmed arc, drawn from 12 o'clock clockwise.
    private var arc: some Shape {
        Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
    }
}
