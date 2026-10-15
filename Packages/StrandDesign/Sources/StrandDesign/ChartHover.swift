#if !os(watchOS)
// Hover toolkit (tooltips, crosshair, nearest-point) is for pointer charts; excluded on watchOS.
import SwiftUI

// MARK: - Chart Hover Toolkit
//
// A shared hover affordance: a small dark tooltip card naming the datum under the cursor, plus geometry
// helpers for crosshairs and nearest-point lookup. Design tokens only.

// MARK: - ChartTooltip

/// A small dark read-out card shown near the cursor: a bold value line and a secondary label/date line.
public struct ChartTooltip: View {

    /// The bold value line (e.g. "62 ms").
    public var value: String
    /// The secondary context line (e.g. a formatted date).
    public var label: String?
    /// Optional leading accent dot (e.g. the sampled gradient colour) so the tooltip explains the colour.
    public var accent: Color?

    public init(value: String, label: String? = nil, accent: Color? = nil) {
        self.value = value
        self.label = label
        self.accent = accent
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.8), radius: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(StrandFont.captionNumber)
                    .fontWeight(.semibold)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let label {
                    Text(label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(ZoopPanelSurface(cornerRadius: 8, elevated: true))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label != nil ? "\(value), \(label!)" : value)
    }
}

// MARK: - Tooltip positioning

/// Positions a tooltip near an anchor, estimating its size and flipping/clamping so it stays inside `container`.
public struct ChartTooltipPlacement {

    /// The tooltip centre for an anchor; prefers above-and-right, flipping near an edge.
    public static func position(
        anchor: CGPoint,
        tooltipSize: CGSize,
        in container: CGSize,
        gap: CGFloat = 12
    ) -> CGPoint {
        let halfW = tooltipSize.width / 2
        let halfH = tooltipSize.height / 2

        var y = anchor.y - gap - halfH
        if y - halfH < 0 {
            y = anchor.y + gap + halfH
        }
        y = min(max(y, halfH), max(halfH, container.height - halfH))

        var x = anchor.x
        x = min(max(x, halfW), max(halfW, container.width - halfW))

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Nearest-point lookup

/// Geometry helpers for mapping a hover location to the nearest datum.
public enum ChartHoverMath {

    /// Index of the evenly spaced sample closest to `x`; nil for an empty series.
    public static func nearestIndex(toX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let raw = Int((x / step).rounded())
        return min(max(raw, 0), count - 1)
    }

    /// Index of the point in `xs` closest to `x`.
    public static func nearestIndex(toX x: CGFloat, xs: [CGFloat]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, px) in xs.enumerated() {
            let d = abs(px - x)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}

// MARK: - Crosshair rule

/// A thin vertical crosshair line at a given x. `public` so app-target charts reuse it.
public struct CrosshairRule: View {
    public var x: CGFloat
    public var height: CGFloat
    public var color: Color

    /// The default reads clearly over a chart on a phone (the scrub rule follows a finger).
    public init(x: CGFloat, height: CGFloat, color: Color = StrandPalette.textSecondary.opacity(0.75)) {
        self.x = x
        self.height = height
        self.color = color
    }

    public var body: some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: height))
        }
        .stroke(
            color,
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Highlighted point dot

/// A small accented dot marking the highlighted sample on a line. `public` for app-target hover overlays.
public struct HighlightDot: View {
    public var color: Color
    public var diameter: CGFloat

    public init(color: Color, diameter: CGFloat = 9) {
        self.color = color
        self.diameter = diameter
    }

    public var body: some View {
        // Crisp solid dot with a clean surface ring, no bloom.
        ZStack {
            Circle()
                .fill(StrandPalette.surfaceBase)
                .frame(width: diameter + 3, height: diameter + 3)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - "Now" end-cap

/// The "now" marker pinned to a trend line's latest point: tinted outer ring, brighter mid-ring, white core. Flat, no bloom.
struct NowCapDot: View {
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.30)).frame(width: 18, height: 18)
            Circle().fill(color.opacity(0.65)).frame(width: 11, height: 11)
            Circle().fill(StrandPalette.tipCore).frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tooltip overlay container

/// Wraps a tooltip so its measured size feeds back into placement, fading in near `anchor`. `public` for app-target hover overlays.
public struct PositionedTooltip: View {
    public var anchor: CGPoint
    public var container: CGSize
    public var tooltip: ChartTooltip

    @State private var measured: CGSize = .zero

    public init(anchor: CGPoint, container: CGSize, tooltip: ChartTooltip) {
        self.anchor = anchor
        self.container = container
        self.tooltip = tooltip
    }

    public var body: some View {
        tooltip
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { measured = g.size }
                        .onChangeCompat(of: g.size) { measured = $0 }
                }
            )
            .position(
                ChartTooltipPlacement.position(
                    anchor: anchor,
                    tooltipSize: measured == .zero ? CGSize(width: 90, height: 40) : measured,
                    in: container
                )
            )
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("ChartTooltip") {
    VStack(spacing: 24) {
        ChartTooltip(value: "Recovery 88", label: "Tue 3 Jun", accent: StrandPalette.recoveryColor(88))
        ChartTooltip(value: "62 ms", label: "HRV · sample 14")
        ChartTooltip(value: "18.7", label: "STRAIN · all-out", accent: StrandPalette.strainColor(18.7))
    }
    .padding(40)
    .frame(width: 320, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
