#if os(iOS)
import SwiftUI
import StrandDesign

/// The compact fasting ring: an inset track and a rounded arc from 12 o'clock, cyan while fasting and
/// amber for the eating window. Used by Today's card.
struct FastingProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    var tint: Color = StrandPalette.metricCyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Strokes straddle the path, so inset by half the width to keep the ring inside its frame.
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: lineWidth).padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: progress)
        }
    }
}

/// The hero's two-phase ring: the fasting arc (goal) then the eating arc (window) around one circle,
/// each a faint track filled in its phase colour as it runs.
struct FastingCycleRing: View {
    let model: FastingRingModel
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A small gap between the arcs so the two phases read as separate.
    private var gap: Double { model.fastingShare < 1 ? 0.012 : 0 }

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: lineWidth).padding(lineWidth / 2)
            arc(from: 0, to: model.fastingShare - gap, color: StrandPalette.metricCyan.opacity(0.18), cap: .butt)
            if model.fastingFill > 0 {
                arc(from: 0, to: (model.fastingShare - gap) * model.fastingFill, color: StrandPalette.metricCyan)
            }
            if model.fastingShare < 1 {
                arc(from: model.fastingShare + gap, to: 1 - gap, color: StrandPalette.metricAmber.opacity(0.22), cap: .butt)
                if model.eatingFill > 0 {
                    arc(from: model.fastingShare + gap,
                        to: model.fastingShare + gap + (1 - model.fastingShare - 2 * gap) * model.eatingFill,
                        color: StrandPalette.metricAmber)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: model)
    }

    /// Tracks use butt caps so their ends don't spill into the other phase; fills keep the round cap.
    private func arc(from: Double, to: Double, color: Color, cap: CGLineCap = .round) -> some View {
        Circle()
            .trim(from: max(0, from), to: max(max(0, from), min(1, to)))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: cap))
            .rotationEffect(.degrees(-90))
            .padding(lineWidth / 2)
    }
}
#endif
