import SwiftUI

// MARK: - MetricRangeBar (typical-range band + today marker)

/// Where the band and the marker sit on the bar, as 0…1 fractions. Pure so the placement is testable.
public struct MetricRangeLayout: Equatable, Sendable {
    public let band: ClosedRange<Double>
    public let marker: Double?

    public init?(_ readout: MetricReadout) {
        guard let range = readout.typicalRange else { return nil }
        let value = readout.displayValue
        let domain = Self.domain(range: range, value: value, fixedScore: Self.isFixedScore(readout))
        let span = domain.upperBound - domain.lowerBound
        func fraction(_ v: Double) -> Double { min(max((v - domain.lowerBound) / span, 0), 1) }
        band = fraction(range.lowerBound)...fraction(range.upperBound)
        marker = value.map(fraction)
    }

    /// 0–100 scores keep their absolute scale so the bar reads like the score itself.
    private static func isFixedScore(_ readout: MetricReadout) -> Bool {
        if case .score = readout.verdict { return true }
        return false
    }

    /// The band takes the middle third; the domain widens just enough to keep the marker on the bar with half a band of air.
    static func domain(range: ClosedRange<Double>, value: Double?, fixedScore: Bool) -> ClosedRange<Double> {
        if fixedScore { return 0...100 }
        let width = range.upperBound - range.lowerBound
        let pad = width > 0 ? width : max(abs(range.lowerBound) * 0.1, 1)
        var lo = range.lowerBound - pad
        var hi = range.upperBound + pad
        if let value {
            lo = min(lo, value - pad / 2)
            hi = max(hi, value + pad / 2)
        }
        return lo...hi
    }
}

public struct MetricRangeBar: View {
    private let readout: MetricReadout
    @ScaledMetric(relativeTo: .caption) private var trackHeight: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var markerSize: CGFloat = 14

    public init(_ readout: MetricReadout) {
        self.readout = readout
    }

    public var body: some View {
        if let layout = MetricRangeLayout(readout) {
            GeometryReader { geo in
                let w = geo.size.width
                let bandX = w * layout.band.lowerBound
                let bandW = max(w * (layout.band.upperBound - layout.band.lowerBound), trackHeight)
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                        .frame(height: trackHeight)
                    band(width: bandW)
                        .offset(x: bandX)
                    if let marker = layout.marker {
                        Circle()
                            .fill(MetricStyle.tint(readout))
                            .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                            .frame(width: markerSize, height: markerSize)
                            .offset(x: min(max(w * marker - markerSize / 2, 0), w - markerSize))
                    }
                }
                .frame(height: markerSize)
            }
            .frame(height: markerSize)
            .accessibilityHidden(true)
        }
    }

    /// Solid band for a settled personal range; dashed outline while it is population or provisional.
    @ViewBuilder
    private func band(width: CGFloat) -> some View {
        let shape = Capsule()
        let tint = MetricStyle.tint(readout)
        if readout.rangeIsTentative {
            shape.fill(tint.opacity(0.12))
                .overlay(shape.stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .frame(width: width, height: trackHeight)
        } else {
            shape.fill(tint.opacity(0.35))
                .frame(width: width, height: trackHeight)
        }
    }
}
