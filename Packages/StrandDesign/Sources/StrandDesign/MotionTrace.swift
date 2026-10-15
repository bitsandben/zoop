import SwiftUI

// MARK: - MotionTrace (Sleep restlessness trace, #407)
//
// A per-epoch MOVEMENT trace drawn under the Hypnogram on the SAME timeline: each value is one 30 s
// epoch's motion magnitude (higher = more restless), a short filled strip. With no persisted motion
// (`motionJSON` NULL) the caller shows an honest empty state instead; this view only renders a non-empty series.

public struct MotionTrace: View {

    /// Per-epoch motion magnitudes (≥ 0), oldest→newest, across the same span as the hypnogram. The trace
    /// self-normalises to its own peak: it shows the SHAPE of movement, not an absolute scale.
    public var epochs: [Double]
    /// Strip height, short so it stays subordinate to the hypnogram.
    public var height: CGFloat
    /// The trace tint; defaults to the sleep accent.
    public var tint: Color

    public init(epochs: [Double], height: CGFloat = 44, tint: Color = StrandPalette.textTertiary) {
        self.epochs = epochs
        self.height = height
        self.tint = tint
    }

    /// The peak magnitude that normalises fill height; non-positive maps everything to the baseline (no divide by zero).
    /// Compute ONCE and thread it down: as a per-read scan it cost ~1.8 million comparisons per layout of an
    /// 8-hour night, re-run on hover, animation and the 1 Hz HR tick (#2283).
    static func peak(of epochs: [Double]) -> Double { max(epochs.max() ?? 0, 0) }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // ONE scan, threaded into everything below (see `peak(of:)`).
            let peak = Self.peak(of: epochs)
            ZStack {
                // Faint baseline so the strip reads grounded on a calm night.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 1))
                    p.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)

                if epochs.count >= 2, peak > 0 {
                    let pts = Self.points(in: geo.size, epochs: epochs, peak: peak)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(tint.opacity(0.22))

                    Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: first)
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                } else if epochs.count == 1, peak > 0 {
                    // A single epoch can't form a line: draw one centred tick.
                    let y = h - CGFloat(epochs[0] / peak) * (h - 2)
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: h))
                        p.addLine(to: CGPoint(x: w / 2, y: y))
                    }
                    .stroke(tint.opacity(0.8), lineWidth: 1.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Movement during sleep"))
            .accessibilityValue(Text(Self.accessibilitySummary(epochs: epochs, peak: peak)))
        }
        .frame(height: height)
    }

    /// One screen point per epoch: x spread evenly across the width, y normalised to the night's peak.
    static func points(in size: CGSize, epochs: [Double], peak: Double) -> [CGPoint] {
        let n = epochs.count
        guard n >= 2, peak > 0 else { return [] }
        let h = size.height
        let usable = h - 2   // leave 1px top/bottom padding so the crest isn't clipped
        return epochs.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let frac = CGFloat(max(0, min(v / peak, 1)))
            return CGPoint(x: x, y: h - frac * usable)
        }
    }

    /// A coarse VoiceOver summary: the share of epochs above half-peak movement; "Calm" when none cross it.
    static func accessibilitySummary(epochs: [Double], peak: Double) -> String {
        guard peak > 0, !epochs.isEmpty else { return "no movement data" }
        let restless = epochs.filter { $0 >= peak * 0.5 }.count
        if restless == 0 { return "calm throughout" }
        let pct = Int((Double(restless) / Double(epochs.count) * 100).rounded())
        return "\(pct)% of the night had elevated movement"
    }
}

#if DEBUG
#Preview("MotionTrace") {
    let calm = (0..<60).map { _ in Double.random(in: 0...0.1) }
    let restless = (0..<60).map { i -> Double in
        i % 11 == 0 ? Double.random(in: 0.7...1.0) : Double.random(in: 0...0.2)
    }
    return VStack(alignment: .leading, spacing: 16) {
        Text("Calm night").strandOverline()
        MotionTrace(epochs: calm)
        Text("Restless night").strandOverline()
        MotionTrace(epochs: restless)
    }
    .padding(28)
    .frame(width: 720, height: 280)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
