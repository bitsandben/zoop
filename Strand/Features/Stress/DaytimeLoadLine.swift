import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // y maps a 0–3 level into the chart (0 at bottom), for the baseline rule below. The x
            // placement moved into `scoredRuns`, which needs it per point anyway.
            // (a closure, not a `func` — a `@ViewBuilder` closure can't contain declarations)
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            // Contiguous runs of scored hours. Built in a method, not here: this is a
            // `@ViewBuilder` closure and cannot hold statements.
            let runs = scoredRuns(width: w, height: h)

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The ramp runs DOWN the chart, not across the day.
                //
                // It used to be `.leading` to `.trailing`, which painted the stress band colours along
                // the x-axis: a calm 9pm hour rendered amber and a tense 7am one blue, so the colour
                // said nothing about the score while looking exactly as though it did. Because y maps
                // the 0-3 level onto the chart, a vertical ramp makes vertical position the level, which
                // is what the Kotlin twin does and what the legend claims. Amber at the top, blue at the
                // bottom: `StressRamp.gradient` runs calm-first, so it is reversed here.
                let levelRamp = LinearGradient(
                    gradient: Gradient(colors: Array(StressRamp.stops.map(\.color).reversed())),
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(runs.enumerated()), id: \.offset) { _, seg in
                    if seg.count >= 2 {
                        // Closed PER RUN, so the wash cannot spread under an hour that was never scored
                        // and undo the gap the broken line just drew.
                        areaPath(seg, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        StressRamp.calm.opacity(0.22),
                                        StressRamp.calm.opacity(0.02),
                                    ]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(seg)
                            .stroke(levelRamp,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    } else if let only = seg.first {
                        // A run of one scored hour: a dot rather than a line. Coloured by the level it
                        // actually carries — it used to be hardcoded to the mid colour, so a lone HIGH
                        // hour drew as an ordinary one.
                        Circle()
                            .fill(StressRamp.color(level(at: only.1, height: h)))
                            .frame(width: 6, height: 6)
                            .position(x: only.0, y: only.1)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// CONTIGUOUS RUNS of scored hours, in chart coordinates.
    ///
    /// The old path `compactMap`-ed the unscored hours away and stroked a smooth curve through whatever
    /// was left, which draws a reading straight across an hour that has none — the one thing the caption
    /// promises it will not do. Splitting into runs lets each be stroked and filled separately, so a
    /// hole in the day stays a hole. The Kotlin twin has always broken the line here.
    private func scoredRuns(width w: CGFloat, height h: CGFloat) -> [[(CGFloat, CGFloat)]] {
        let n = max(hours.count, 1)
        var out: [[(CGFloat, CGFloat)]] = []
        var run: [(CGFloat, CGFloat)] = []
        for (i, p) in hours.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            let px = n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1)
            let py = h - h * CGFloat(min(max(level / 3.0, 0), 1))
            run.append((px, py))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// The 0-3 level a chart y-position represents: the inverse of the `y` mapping above, so a lone
    /// point can be coloured by what it actually reads rather than by a fixed guess.
    private func level(at yPos: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height - yPos) / height) * 3.0
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

